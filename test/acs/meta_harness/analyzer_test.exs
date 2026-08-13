defmodule Acs.MetaHarness.AnalyzerTest do
  @moduledoc """
  Tests for the ACS Meta-Harness Analyzer module.
  Tests through public API since helpers are private functions.
  """
  use ExUnit.Case, async: false

  alias Acs.MetaHarness.Analyzer
  alias Acs.MetaHarness.RecentOps

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Acs.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Acs.Repo, {:shared, self()})
    RecentOps.setup()
    RecentOps.clear()
    on_exit(fn -> RecentOps.clear() end)
    :ok
  end

  describe "analyze/1" do
    test "returns map with correct top-level keys" do
      result = Analyzer.analyze(timeframe: :last_24_hours)

      assert is_map(result)
      assert Map.has_key?(result, :tool_reliability)
      assert Map.has_key?(result, :latency_analysis)
      assert Map.has_key?(result, :error_clusters)
      assert Map.has_key?(result, :intake_friction)
      assert Map.has_key?(result, :agent_behavior)
      assert Map.has_key?(result, :metadata)
    end

    test "metadata contains correct keys and types" do
      result = Analyzer.analyze(timeframe: :last_7_days)

      assert result.metadata.timeframe == :last_7_days
      assert is_struct(result.metadata.analyzed_at, DateTime)
      assert is_struct(result.metadata.start_time, DateTime)
      assert is_struct(result.metadata.end_time, DateTime)
    end

    test "metadata start_time is approximately 24h before end_time for last_24_hours" do
      result = Analyzer.analyze(timeframe: :last_24_hours)

      diff = DateTime.diff(result.metadata.end_time, result.metadata.start_time, :second)
      assert diff >= 86_390 and diff <= 86_400
    end

    test "metadata start_time is approximately 7d before end_time for last_7_days" do
      result = Analyzer.analyze(timeframe: :last_7_days)

      diff = DateTime.diff(result.metadata.end_time, result.metadata.start_time, :second)
      assert diff >= 604_700 and diff <= 604_800
    end

    test "metadata start_time is approximately 30d before end_time for last_30_days" do
      result = Analyzer.analyze(timeframe: :last_30_days)

      diff = DateTime.diff(result.metadata.end_time, result.metadata.start_time, :second)
      assert diff >= 2_591_900 and diff <= 2_592_000
    end

    test "returns empty collections when no repo available" do
      # Skip ETS fallback so concurrent suite ops cannot pollute this assertion.
      result = Analyzer.analyze(timeframe: :last_30_days, ets_fallback: false)

      assert result.tool_reliability == %{}
      assert result.latency_analysis == %{}
      assert result.error_clusters == []
      assert result.intake_friction == []
      assert result.agent_behavior == %{}
    end

    test "accepts optional parameters without crashing" do
      result =
        Analyzer.analyze(timeframe: :last_24_hours, min_sample_size: 10, min_cluster_size: 5)

      assert is_map(result)
      assert result.metadata.timeframe == :last_24_hours
    end

    test "default timeframe is :last_24_hours" do
      result = Analyzer.analyze()

      assert result.metadata.timeframe == :last_24_hours
    end
  end

  describe "quick_summary/1" do
    test "returns map with expected keys" do
      summary = Analyzer.quick_summary(timeframe: :last_24_hours)

      assert is_map(summary)
      assert Map.has_key?(summary, :total_tools)
      assert Map.has_key?(summary, :overall_success_rate)
      assert Map.has_key?(summary, :slowest_tool)
      assert Map.has_key?(summary, :most_failed_tool)
      assert Map.has_key?(summary, :error_cluster_count)
      assert Map.has_key?(summary, :active_agents)
    end

    test "returns zeros when no data available" do
      summary = Analyzer.quick_summary(timeframe: :last_24_hours, ets_fallback: false)

      assert summary.total_tools == 0
      assert summary.overall_success_rate == 0.0
      assert summary.error_cluster_count == 0
      assert summary.active_agents == 0
      assert summary.slowest_tool == nil
      assert summary.most_failed_tool == nil
    end
  end
end
