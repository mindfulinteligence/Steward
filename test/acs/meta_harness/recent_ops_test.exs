defmodule Acs.MetaHarness.RecentOpsTest do
  use ExUnit.Case, async: false

  alias Acs.MetaHarness.RecentOps

  setup do
    RecentOps.setup()
    RecentOps.clear()
    :ok
  end

  test "analyze aggregates recorded ops when postgres would be empty" do
    now = System.system_time(:millisecond)

    RecentOps.record(%{
      tool_name: "ask",
      status: "success",
      latency_ms: 100,
      error_type: nil,
      error_message: nil,
      agent_id: "email|x"
    })

    RecentOps.record(%{
      tool_name: "ask",
      status: "failure",
      latency_ms: 50,
      error_type: "timeout",
      error_message: "timed out",
      agent_id: "email|x"
    })

    result =
      RecentOps.analyze(now - 60_000, now + 60_000, min_sample_size: 1, min_cluster_size: 1)

    assert map_size(result.tool_reliability) == 1
    assert result.tool_reliability["ask"].total_calls == 2
    assert result.tool_reliability["ask"].failure_count == 1
    assert length(result.error_clusters) == 1
    assert map_size(result.agent_behavior) == 1
  end

  test "orgs/0 lists distinct org slugs recorded, defaulting missing orgs" do
    RecentOps.record(%{tool_name: "ask", status: "success", latency_ms: 10, org: "anantha"})
    RecentOps.record(%{tool_name: "ask", status: "success", latency_ms: 10, org: "anantha"})
    RecentOps.record(%{tool_name: "ask", status: "success", latency_ms: 10, org: "default"})
    RecentOps.record(%{tool_name: "ask", status: "success", latency_ms: 10})

    assert Enum.sort(RecentOps.orgs()) == ["anantha", "default"]
  end
end
