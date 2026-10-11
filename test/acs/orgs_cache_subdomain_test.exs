defmodule Acs.OrgsCacheSubdomainTest do
  use ExUnit.Case, async: false

  alias Acs.OrgsCache

  setup do
    Application.put_env(:steward_acs, :org_subdomain_cache, true)
    OrgsCache.invalidate()

    on_exit(fn ->
      OrgsCache.invalidate()
      Application.put_env(:steward_acs, :org_subdomain_cache, false)
    end)

    :ok
  end

  test "caches hits and misses so repeat lookups skip the loader" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    loader = fn org -> fn -> Agent.update(calls, &(&1 + 1)) && org end end

    assert OrgsCache.fetch_subdomain("cached-hit", loader.(%{slug: "x"})) == %{slug: "x"}
    assert OrgsCache.fetch_subdomain("cached-hit", loader.(%{slug: "x"})) == %{slug: "x"}
    assert OrgsCache.fetch_subdomain("cached-miss", loader.(nil)) == nil
    assert OrgsCache.fetch_subdomain("cached-miss", loader.(nil)) == nil

    assert Agent.get(calls, & &1) == 2
  end

  test "invalidate clears cached subdomains" do
    OrgsCache.fetch_subdomain("fresh-org", fn -> nil end)
    OrgsCache.invalidate()

    assert OrgsCache.fetch_subdomain("fresh-org", fn -> %{slug: "fresh-org"} end).slug ==
             "fresh-org"
  end

  test "a raising loader is not cached" do
    assert_raise RuntimeError, fn ->
      OrgsCache.fetch_subdomain("boom", fn -> raise "db down" end)
    end

    assert OrgsCache.fetch_subdomain("boom", fn -> %{slug: "boom"} end).slug == "boom"
  end

  test "get_by_subdomain skips the database for invalid labels" do
    handler = "orgs-cache-no-query-#{System.unique_integer()}"
    me = self()

    :telemetry.attach(
      handler,
      [:steward_acs, :repo, :query],
      fn _, _, meta, _ ->
        send(me, {:query, meta[:source]})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert Acs.Orgs.get_by_subdomain("not a label!!") == nil
    assert Acs.Orgs.get_by_subdomain(String.duplicate("a", 80)) == nil
    refute_received {:query, _}
  end
end
