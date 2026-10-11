defmodule Acs.OrgsCache do
  @moduledoc false

  @table :orgs_cache
  @ttl_seconds 10
  # Tenant-host lookups run on every request, including scanner/bot traffic.
  # Cache hits and misses so those requests don't wake an autosuspended Neon
  # compute. Misses are short so a freshly created org resolves quickly;
  # `invalidate/0` also clears these on this node.
  @subdomain_hit_ttl 120
  @subdomain_miss_ttl 30
  @max_subdomain_entries 2_000

  def setup do
    :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    :ok
  end

  def get do
    cutoff = cutoff()

    case :ets.lookup(@table, :orgs) do
      [{:orgs, orgs, ts}] when ts > cutoff -> orgs
      _ -> nil
    end
  end

  def put(orgs) do
    :ets.insert(@table, {:orgs, orgs, current_time()})
  end

  def invalidate do
    :ets.delete(@table, :orgs)
    :ets.match_delete(@table, {{:subdomain, :_}, :_, :_})
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Returns the cached org (or cached miss) for `subdomain`, calling `fun` on a
  cold entry. `fun` raising (e.g. DB unreachable) is never cached.
  """
  def fetch_subdomain(subdomain, fun) do
    if Application.get_env(:steward_acs, :org_subdomain_cache, true) do
      cached_subdomain(subdomain, fun)
    else
      fun.()
    end
  end

  defp cached_subdomain(subdomain, fun) do
    now = current_time()

    case :ets.lookup(@table, {:subdomain, subdomain}) do
      [{_, org, expires_at}] when expires_at > now ->
        org

      _ ->
        org = fun.()
        put_subdomain(subdomain, org, now)
        org
    end
  rescue
    ArgumentError -> fun.()
  end

  defp put_subdomain(subdomain, org, now) do
    if :ets.info(@table, :size) > @max_subdomain_entries do
      :ets.match_delete(@table, {{:subdomain, :_}, :_, :_})
    end

    ttl = if org, do: @subdomain_hit_ttl, else: @subdomain_miss_ttl
    :ets.insert(@table, {{:subdomain, subdomain}, org, now + ttl})
  end

  defp cutoff, do: current_time() - @ttl_seconds
  defp current_time, do: System.system_time(:second)
end
