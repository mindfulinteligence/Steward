defmodule Acs.MetaHarness.AnalyzerPartialFallbackTest do
  use Acs.DataCase, async: false

  alias Acs.MetaHarness.Analyzer
  alias Acs.MetaHarness.RecentOps
  alias Acs.MetaHarness.SQL

  @db_tool "partial_fallback_db_tool"
  @ets_tool "partial_fallback_ets_tool"

  setup do
    RecentOps.setup()
    RecentOps.clear()
    delete_db_rows()
    :ok
  end

  test "supplements missing tools from RecentOps when DB is partial" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    :ok =
      RecentOps.record(%{
        tool_name: @ets_tool,
        status: "success",
        latency_ms: 50,
        org: "default",
        agent_id: "agent-ets"
      })

    ph = SQL.placeholders(5)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO acs_tool_operations (tool_name, status, latency_ms, org, created_at)
      VALUES (#{ph})
      """,
      [@db_tool, "success", 100, "default", now]
    )

    result = Analyzer.analyze(timeframe: :last_24_hours, org: "default", min_sample_size: 1)

    assert Map.has_key?(result.tool_reliability, @db_tool)
    assert Map.has_key?(result.tool_reliability, @ets_tool)
    assert result.metadata.source == "sqlite+ets_fallback"
    assert result.latency_analysis[@db_tool].avg_latency == 100
    assert result.latency_analysis[@ets_tool].avg_latency == 50

    delete_db_rows()
    RecentOps.clear()
  end

  defp delete_db_rows do
    for tool <- [@db_tool, @ets_tool] do
      Ecto.Adapters.SQL.query!(
        Repo,
        SQL.adapt("DELETE FROM acs_tool_operations WHERE tool_name = ?1"),
        [tool]
      )
    end
  end
end
