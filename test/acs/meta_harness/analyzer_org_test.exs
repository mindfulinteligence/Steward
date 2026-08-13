defmodule Acs.MetaHarness.AnalyzerOrgTest do
  use Acs.DataCase, async: false

  alias Acs.MetaHarness.Analyzer
  alias Acs.MetaHarness.SQL

  @tool "meta_harness_analyzer_org_test"

  setup do
    delete_test_rows()
    :ok
  end

  test "analyze(org:) only includes rows for that tenant" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    ph = SQL.placeholders(5)

    for {org, latency} <- [{"org-a", 10}, {"org-b", 20}] do
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO acs_tool_operations (tool_name, status, latency_ms, org, created_at)
        VALUES (#{ph})
        """,
        [@tool, "success", latency, org, now]
      )
    end

    a =
      Analyzer.analyze(
        timeframe: :last_24_hours,
        org: "org-a",
        ets_fallback: false,
        min_sample_size: 1
      )

    b =
      Analyzer.analyze(
        timeframe: :last_24_hours,
        org: "org-b",
        ets_fallback: false,
        min_sample_size: 1
      )

    assert Map.has_key?(a.tool_reliability, @tool)
    assert Map.has_key?(b.tool_reliability, @tool)
    assert a.metadata.org == "org-a"
    assert b.metadata.org == "org-b"
    assert a.latency_analysis[@tool].avg_latency == 10
    assert b.latency_analysis[@tool].avg_latency == 20

    delete_test_rows()
  end

  defp delete_test_rows do
    Ecto.Adapters.SQL.query!(
      Repo,
      SQL.adapt("DELETE FROM acs_tool_operations WHERE tool_name = ?1"),
      [@tool]
    )
  end
end
