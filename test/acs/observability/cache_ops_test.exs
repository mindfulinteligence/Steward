defmodule Acs.Observability.CacheOpsTest do
  use ExUnit.Case, async: true

  alias Acs.Observability.AxiomLogBackend
  alias Acs.Observability.CacheOps

  describe "event/1" do
    test "builds action + stringified cache fields" do
      meta =
        CacheOps.event(
          cache_name: :skills_cache,
          result: "miss",
          type: {:list, "acme"},
          org: "acme",
          count: 3
        )

      assert meta[:action] == "cache_access"
      assert meta[:cache_name] == "skills_cache"
      assert meta[:cache_result] == "miss"
      assert meta[:cache_type] == "list:acme"
      assert meta[:org] == "acme"
      assert meta[:count] == 3
    end

    test "drops nil and empty metadata values" do
      meta = CacheOps.event(cache_name: :jwks, result: "hit")
      refute Keyword.has_key?(meta, :cache_type)
      refute Keyword.has_key?(meta, :org)
      refute Keyword.has_key?(meta, :count)
      refute Keyword.has_key?(meta, :latency_ms)
    end

    test "stringifies atom cache_type" do
      meta = CacheOps.event(cache_name: :skills_cache, result: "hit", type: :all_skills)
      assert meta[:cache_type] == "all_skills"
    end
  end

  test "cache metadata fields export through AxiomLogBackend" do
    event =
      AxiomLogBackend.to_event(
        :info,
        "cache miss",
        nil,
        CacheOps.event(
          cache_name: :skills_cache,
          result: "miss",
          type: {:list, "acme"},
          org: "acme"
        ) ++
          [next_provider: "nim", providers: ["mimo", "nim"]]
      )

    assert event["action"] == "cache_access"
    assert event["cache_name"] == "skills_cache"
    assert event["cache_result"] == "miss"
    assert event["cache_type"] == "list:acme"
    assert event["next_provider"] == "nim"
    assert event["providers"] == ["mimo", "nim"]
  end
end
