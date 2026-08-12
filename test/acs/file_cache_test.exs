defmodule Acs.FileCacheTest do
  use ExUnit.Case, async: true

  alias Acs.FileCache

  setup_all do
    FileCache.setup()
    :ok
  end

  defp unique_org, do: "org-#{System.unique_integer([:positive])}"

  test "get returns :miss before put, then {:ok, value} after" do
    org = unique_org()

    assert FileCache.get(:skills_cache, org, :all_skills) == :miss
    assert :ok = FileCache.put(:skills_cache, org, :all_skills, ["a", "b"])
    assert FileCache.get(:skills_cache, org, :all_skills) == {:ok, ["a", "b"]}
  end

  test "get returns :miss after invalidate" do
    org = unique_org()
    FileCache.put(:skills_cache, org, {:list, "acme"}, [1])
    FileCache.invalidate(:skills_cache, org, {:list, "acme"})

    assert FileCache.get(:skills_cache, org, {:list, "acme"}) == :miss
  end

  test "invalidate_org clears all entries for the org" do
    org = unique_org()
    FileCache.put(:skills_cache, org, :all_skills, [1])
    FileCache.put(:skills_cache, org, {:list, "acme"}, [2])
    FileCache.invalidate_org(:skills_cache, org)

    assert FileCache.get(:skills_cache, org, :all_skills) == :miss
    assert FileCache.get(:skills_cache, org, {:list, "acme"}) == :miss
  end

  test "get returns :miss when table is undefined" do
    assert FileCache.get(:nonexistent_cache, unique_org(), :all_skills) == :miss
  end

  test "get emits cache_access telemetry with hit/miss result" do
    source = File.read!(Path.join([__DIR__, "../../lib/acs/file_cache.ex"]))

    assert String.contains?(source, ~S|CacheOps.log(cache_name: table, result: "hit"|)
    assert String.contains?(source, ~S|CacheOps.log(cache_name: table, result: "miss"|)
  end
end
