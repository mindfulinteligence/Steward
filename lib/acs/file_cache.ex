defmodule Acs.FileCache do
  @moduledoc """
  Short-TTL ETS cache for file-derived data (skills, specs).

  Skills and spec discovery scan + parse every file on each call, which is the
  dominant cost of guidance generation (vaults can hold thousands of YAML/MD
  files). This cache memoizes the parsed lists per directory for a few seconds
  so repeated lookups within one request (e.g. claim guidance) hit memory.

  Entries are keyed by `{directory, type}`, where `directory` is the resolved
  data directory (e.g. `Skills.Store.skill_dir()` or `Specs.Loader.specs_path()`),
  so multi-tenant vaults stay isolated and tests that swap vault dirs don't get
  stale reads. Writers invalidate their directory's entry so fresh writes are
  immediately visible; the TTL is a backstop for files edited directly on disk.

  All operations are safe when the table has not been created yet (e.g. during
  code reload or in tests where `setup/0` did not run): `get/3` returns `:miss`
  and writes are no-ops, so the cache degrades to no-caching rather than raising.
  """

  @ttl_seconds 10
  @tables [:skills_cache, :specs_cache]

  alias Acs.Observability.CacheOps

  def setup do
    for table <- @tables do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
      end
    end

    :ok
  end

  def get(table, org, type) do
    if :ets.whereis(table) == :undefined do
      CacheOps.log(cache_name: table, result: "miss", type: type, org: org)
      :miss
    else
      cutoff = cutoff()

      case :ets.lookup(table, {org, type}) do
        [{_key, value, ts}] when ts > cutoff ->
          CacheOps.log(cache_name: table, result: "hit", type: type, org: org)
          {:ok, value}

        _ ->
          CacheOps.log(cache_name: table, result: "miss", type: type, org: org)
          :miss
      end
    end
  end

  def put(table, org, type, value) do
    if :ets.whereis(table) != :undefined do
      :ets.insert(table, {{org, type}, value, current_time()})
    end

    :ok
  end

  def invalidate(table, org, type) do
    if :ets.whereis(table) != :undefined do
      :ets.delete(table, {org, type})
    end

    :ok
  end

  def invalidate_org(table, org) do
    if :ets.whereis(table) != :undefined do
      :ets.match_delete(table, {{org, :_}, :_, :_})
    end

    :ok
  end

  defp cutoff, do: current_time() - @ttl_seconds
  defp current_time, do: System.system_time(:second)
end
