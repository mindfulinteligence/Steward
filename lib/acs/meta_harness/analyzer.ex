defmodule Acs.MetaHarness.Analyzer do
  @moduledoc """
  Meta-Harness Analyzer for ACS.

  Analyzes operation logs to identify:
  - Tool reliability (success/failure rates)
  - Latency patterns (P50, P95 per tool)
  - Error clusters (grouped by tool + error_type)
  - Agent behavior patterns (derived from operations)

  ## Usage

      analysis = Acs.MetaHarness.Analyzer.analyze(timeframe: :last_24_hours)
  """

  require Logger

  @default_timeframe_days 1

  @doc """
  Main entry point for analysis.

  ## Options
    - `:timeframe` - Analysis window: `:last_24_hours`, `:last_7_days`, `:last_30_days` (default: `:last_24_hours`)
    - `:min_sample_size` - Minimum samples needed for reliable stats (default: 1)
    - `:min_cluster_size` - Minimum occurrences for error cluster detection (default: 2)
    - `:org` - Tenant org slug (default: `Acs.Org.current/0`)
  """
  @spec analyze(keyword()) :: map()
  def analyze(opts \\ []) do
    timeframe = Keyword.get(opts, :timeframe, :last_24_hours)
    org = Keyword.get(opts, :org, Acs.Org.current())
    # Sparse prod traffic — 3 samples minimum for statistically meaningful stats
    # (a single call would make reliability/latency noise, not signal).
    min_sample = Keyword.get(opts, :min_sample_size, 3)
    min_cluster = Keyword.get(opts, :min_cluster_size, 2)

    {start_time, end_time} = calculate_time_range(timeframe)

    analysis = %{
      tool_reliability: analyze_tool_reliability(start_time, end_time, min_sample, org),
      latency_analysis: analyze_latency(start_time, end_time, min_sample, org),
      error_clusters: find_error_clusters(start_time, end_time, min_cluster, org),
      intake_friction: analyze_intake_friction(start_time, end_time, min_cluster, org),
      agent_behavior: analyze_agent_behavior(start_time, end_time, org),
      metadata: %{
        analyzed_at: DateTime.utc_now(),
        timeframe: timeframe,
        org: org,
        start_time: start_time,
        end_time: end_time,
        source: if(Acs.MetaHarness.SQL.postgres?(), do: "postgres", else: "sqlite")
      }
    }

    maybe_ets_fallback(analysis, start_time, end_time, min_sample, min_cluster, org, opts)
  end

  # When Postgres dual-write is empty/broken, roll up from in-memory RecentOps
  # (same events AgentOps already recorded). Ingest-only AXIOM_LOGS cannot query.
  defp maybe_ets_fallback(analysis, start_time, end_time, min_sample, min_cluster, org, opts) do
    if Keyword.get(opts, :ets_fallback, true) == false do
      analysis
    else
      start_ms = DateTime.to_unix(start_time, :millisecond)
      end_ms = DateTime.to_unix(end_time, :millisecond)

      ets =
        Acs.MetaHarness.RecentOps.analyze(start_ms, end_ms,
          min_sample_size: min_sample,
          min_cluster_size: min_cluster,
          org: org
        )

      db_tools = Map.keys(analysis.tool_reliability)
      ets_tools = Map.keys(ets.tool_reliability)
      missing_tools = ets_tools -- db_tools

      cond do
        db_tools == [] and ets_tools == [] ->
          analysis

        db_tools == [] ->
          Logger.info(
            "[Analyzer] Postgres empty — using RecentOps ETS fallback (#{length(ets_tools)} tools)"
          )

          merge_ets_fields(analysis, ets, "ets_fallback")

        missing_tools == [] ->
          analysis

        true ->
          Logger.info(
            "[Analyzer] Partial DB coverage — supplementing #{length(missing_tools)} tools from RecentOps"
          )

          analysis
          |> merge_ets_for_tools(ets, missing_tools)
          |> put_in([:metadata, :source], hybrid_source(analysis.metadata.source))
      end
    end
  end

  defp merge_ets_fields(analysis, ets, source) do
    analysis
    |> Map.merge(
      Map.take(ets, [
        :tool_reliability,
        :latency_analysis,
        :error_clusters,
        :intake_friction,
        :agent_behavior
      ])
    )
    |> put_in([:metadata, :source], source)
  end

  defp merge_ets_for_tools(analysis, ets, missing_tools) do
    missing = MapSet.new(missing_tools)
    tool_filter = fn row -> Map.fetch!(row, :tool_name) in missing end
    # Dedup clusters by (tool, error_type) so the same cluster present in both
    # DB and RecentOps is counted once, not inflated by the merge.
    cluster_key = fn row -> {row.tool_name, row.error_type} end

    %{
      analysis
      | tool_reliability:
          Map.merge(analysis.tool_reliability, Map.take(ets.tool_reliability, missing_tools)),
        latency_analysis:
          Map.merge(analysis.latency_analysis, Map.take(ets.latency_analysis, missing_tools)),
        error_clusters:
          Enum.uniq_by(
            analysis.error_clusters ++ Enum.filter(ets.error_clusters, tool_filter),
            cluster_key
          ),
        intake_friction:
          Enum.uniq_by(
            analysis.intake_friction ++ Enum.filter(ets.intake_friction, tool_filter),
            cluster_key
          ),
        agent_behavior: Map.merge(ets.agent_behavior, analysis.agent_behavior)
    }
  end

  defp hybrid_source(source) when source in ["postgres", "sqlite"], do: "#{source}+ets_fallback"
  defp hybrid_source(source) when is_binary(source), do: source <> "+ets_fallback"
  defp hybrid_source(_), do: "postgres+ets_fallback"

  @doc """
  Returns a simple summary for quick inspection.
  """
  @spec quick_summary(keyword()) :: map()
  def quick_summary(opts \\ []) do
    analysis = analyze(opts)

    %{
      total_tools: map_size(analysis.tool_reliability),
      overall_success_rate: calculate_overall_success_rate(analysis.tool_reliability),
      slowest_tool: find_slowest_tool(analysis.latency_analysis),
      most_failed_tool: find_most_failed_tool(analysis.tool_reliability),
      error_cluster_count: length(analysis.error_clusters),
      intake_gate_count: intake_gate_total(analysis.intake_friction),
      active_agents: map_size(analysis.agent_behavior)
    }
  end

  defp intake_gate_total(friction) when is_list(friction) do
    Enum.reduce(friction, 0, fn row, acc -> acc + (row.occurrence_count || 0) end)
  end

  defp intake_gate_total(_), do: 0

  # ── Tool Reliability Analysis ────────────────────────────────────────────────

  defp analyze_tool_reliability(start_time, end_time, min_sample, org) do
    discovery_query = """
      SELECT tool_name, COUNT(*) as discovery_count
      FROM acs_tool_operations
      WHERE created_at >= ?1
        AND created_at <= ?2
        AND org = ?3
        AND status = 'discovery'
      GROUP BY tool_name
    """

    exec_query = """
      SELECT
        tool_name,
        COUNT(*) as total_calls,
        SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) as success_count,
        SUM(CASE WHEN status = 'failure' THEN 1 ELSE 0 END) as failure_count,
        SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as error_count,
        AVG(latency_ms) as avg_latency,
        MAX(latency_ms) as max_latency
      FROM acs_tool_operations
      WHERE created_at >= ?1
        AND created_at <= ?2
        AND org = ?3
        AND status != 'discovery'
      GROUP BY tool_name
      HAVING COUNT(*) >= ?4
      ORDER BY failure_count DESC, total_calls DESC
    """

    dt_start = format_datetime(start_time)
    dt_end = format_datetime(end_time)

    case {run_query(exec_query, [dt_start, dt_end, org, min_sample]),
          run_query(discovery_query, [dt_start, dt_end, org])} do
      {{:ok, exec_results}, {:ok, discovery_results}} ->
        discovery_map =
          Enum.into(discovery_results, %{}, fn row ->
            {row["tool_name"], row["discovery_count"]}
          end)

        Enum.into(exec_results, %{}, fn row ->
          tool_name = row["tool_name"]
          total = row["total_calls"] || 0
          success = row["success_count"] || 0
          exec_total = success + (row["failure_count"] || 0) + (row["error_count"] || 0)
          discovery_count = Map.get(discovery_map, tool_name, 0)

          {tool_name,
           %{
             total_calls: total,
             success_count: success,
             failure_count: row["failure_count"] || 0,
             error_count: row["error_count"] || 0,
             discovery_count: discovery_count,
             success_rate: if(exec_total > 0, do: success / exec_total, else: 0.0),
             avg_latency: row["avg_latency"] || 0,
             max_latency: row["max_latency"] || 0
           }}
        end)

      _ ->
        %{}
    end
  end

  # ── Latency Analysis ─────────────────────────────────────────────────────────
  # SQLite doesn't support PERCENTILE_CONT, so we compute percentiles in Elixir

  defp analyze_latency(start_time, end_time, min_sample, org) do
    query = """
      SELECT
        tool_name,
        COUNT(*) as sample_size,
        AVG(latency_ms) as avg_latency,
        MIN(latency_ms) as min_latency,
        MAX(latency_ms) as max_latency
      FROM acs_tool_operations
      WHERE created_at >= ?1
        AND created_at <= ?2
        AND org = ?3
        AND latency_ms IS NOT NULL
      GROUP BY tool_name
      HAVING COUNT(*) >= ?4
      ORDER BY avg_latency DESC
    """

    params = [format_datetime(start_time), format_datetime(end_time), org, min_sample]

    # Get raw latency values per tool for percentile calculation
    percentile_query = """
      SELECT tool_name, latency_ms
      FROM acs_tool_operations
      WHERE created_at >= ?1
        AND created_at <= ?2
        AND org = ?3
        AND latency_ms IS NOT NULL
      ORDER BY tool_name, latency_ms
    """

    p_params = [format_datetime(start_time), format_datetime(end_time), org]

    case {run_query(query, params), run_query(percentile_query, p_params)} do
      {{:ok, stats_results}, {:ok, raw_results}} ->
        # Group raw latencies by tool_name
        latencies_by_tool = Enum.group_by(raw_results, & &1["tool_name"], & &1["latency_ms"])

        Enum.into(stats_results, %{}, fn row ->
          tool_name = row["tool_name"]

          latencies =
            Map.get(latencies_by_tool, tool_name, [])
            |> Enum.sort()

          {tool_name,
           %{
             sample_size: row["sample_size"] || 0,
             avg_latency: row["avg_latency"] || 0,
             min_latency: row["min_latency"] || 0,
             max_latency: row["max_latency"] || 0,
             p50_latency: percentile(latencies, 0.50),
             p95_latency: percentile(latencies, 0.95),
             p99_latency: percentile(latencies, 0.99)
           }}
        end)

      _ ->
        %{}
    end
  end

  # ── Error Cluster Analysis ────────────────────────────────────────────────────

  defp find_error_clusters(start_time, end_time, min_occurrences, org) do
    agents_agg =
      if postgres?(),
        do: "string_agg(DISTINCT agent_id, ',')",
        else: "GROUP_CONCAT(DISTINCT agent_id)"

    query = """
      SELECT
        tool_name,
        error_type,
        MAX(error_message) as error_message,
        COUNT(*) as occurrence_count,
        #{agents_agg} as agents
      FROM acs_tool_operations
      WHERE created_at >= ?1
        AND created_at <= ?2
        AND org = ?3
        AND status IN ('failure', 'error')
        AND error_type IS NOT NULL
      GROUP BY tool_name, error_type
      HAVING COUNT(*) >= ?4
      ORDER BY occurrence_count DESC
      LIMIT 20
    """

    case run_query(query, [
           format_datetime(start_time),
           format_datetime(end_time),
           org,
           min_occurrences
         ]) do
      {:ok, results} ->
        Enum.map(results, fn row ->
          %{
            tool_name: row["tool_name"],
            error_type: row["error_type"],
            sample_message: row["error_message"] && String.slice(row["error_message"], 0, 100),
            occurrence_count: row["occurrence_count"],
            agents: row["agents"] || ""
          }
        end)

      {:error, _} ->
        []
    end
  end

  # ── Intake friction (save_memory / skill_save gates) ─────────────────────────
  # Logged as success with error_type intake_* so they don't tank success_rate,
  # but still surface for prompt-tuning (high gate rate = prompt too aggressive).

  defp analyze_intake_friction(start_time, end_time, min_occurrences, org) do
    like = if postgres?(), do: "error_type LIKE 'intake_%'", else: "error_type LIKE 'intake_%'"

    query = """
      SELECT
        tool_name,
        error_type,
        MAX(error_message) as error_message,
        COUNT(*) as occurrence_count
      FROM acs_tool_operations
      WHERE created_at >= ?1
        AND created_at <= ?2
        AND org = ?3
        AND #{like}
      GROUP BY tool_name, error_type
      HAVING COUNT(*) >= ?4
      ORDER BY occurrence_count DESC
      LIMIT 30
    """

    case run_query(query, [
           format_datetime(start_time),
           format_datetime(end_time),
           org,
           min_occurrences
         ]) do
      {:ok, results} ->
        Enum.map(results, fn row ->
          %{
            tool_name: row["tool_name"],
            error_type: row["error_type"],
            sample_message: row["error_message"] && String.slice(row["error_message"], 0, 100),
            occurrence_count: row["occurrence_count"] || 0,
            prompt_hint: intake_prompt_hint(row["tool_name"], row["error_type"])
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp intake_prompt_hint("skill_save", "intake_needs_input"),
    do: "Tighten skills/intake.md high-bar rules or soft-allow more skills (Settings → Prompts)"

  defp intake_prompt_hint("save_memory", "intake_needs_input"),
    do: "Tighten memory/intake.md — prefer allow + soft suggestions (Settings → Prompts)"

  defp intake_prompt_hint("save_memory", "intake_needs_scope_choice"),
    do: "Agents often omit visibility for about-entity memories — clarify tool schema / guidance"

  defp intake_prompt_hint(_, "intake_bypass"),
    do: "Frequent intake_confirmed bypass — review whether gates are false positives"

  defp intake_prompt_hint(_, _), do: "Review org intake prompt overrides"

  # ── Agent Behavior Analysis ──────────────────────────────────────────────────
  # Derived from tool_operations table - no separate agent_behavior table needed

  defp analyze_agent_behavior(start_time, end_time, org) do
    query = """
      SELECT
        agent_id,
        COUNT(*) as total_operations,
        SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) as success_count,
        SUM(CASE WHEN status IN ('failure', 'error') THEN 1 ELSE 0 END) as failure_count,
        SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as error_count,
        SUM(CASE WHEN status = 'discovery' THEN 1 ELSE 0 END) as discovery_count,
        COUNT(DISTINCT tool_name) as unique_tools_used,
        AVG(latency_ms) as avg_latency,
        MIN(created_at) as first_seen,
        MAX(created_at) as last_seen
      FROM acs_tool_operations
      WHERE created_at >= ?1
        AND created_at <= ?2
        AND org = ?3
        AND agent_id IS NOT NULL
      GROUP BY agent_id
      ORDER BY total_operations DESC
    """

    case run_query(query, [format_datetime(start_time), format_datetime(end_time), org]) do
      {:ok, results} ->
        results
        |> Enum.into(%{}, fn row ->
          agent_id = row["agent_id"]
          success = row["success_count"] || 0
          failure = row["failure_count"] || 0
          exec_total = success + failure + (row["error_count"] || 0)

          {agent_id,
           %{
             total_operations: row["total_operations"] || 0,
             success_count: success,
             failure_count: failure,
             discovery_count: row["discovery_count"] || 0,
             unique_tools_used: row["unique_tools_used"] || 0,
             success_rate: if(exec_total > 0, do: success / exec_total, else: 0.0),
             avg_latency: row["avg_latency"] || 0,
             first_seen: row["first_seen"],
             last_seen: row["last_seen"]
           }}
        end)
        |> Enum.reject(fn {agent_id, _} -> is_nil(agent_id) or agent_id == "" end)
        |> Enum.into(%{})

      {:error, _} ->
        %{}
    end
  end

  # ── Percentile Calculation ───────────────────────────────────────────────────

  # Calculates percentile from sorted list using linear interpolation
  defp percentile([], _p), do: 0

  defp percentile(sorted_values, p) when is_list(sorted_values) do
    n = length(sorted_values)
    index = (p * (n - 1)) |> Float.ceil() |> max(0) |> min(n - 1) |> round()
    Enum.at(sorted_values, index)
  end

  # ── Helper Functions ─────────────────────────────────────────────────────────

  defp calculate_time_range(:last_24_hours) do
    now = DateTime.utc_now()
    start = DateTime.add(now, -24, :hour)
    {start, now}
  end

  defp calculate_time_range(:last_7_days) do
    now = DateTime.utc_now()
    start = DateTime.add(now, -7, :day)
    {start, now}
  end

  defp calculate_time_range(:last_30_days) do
    now = DateTime.utc_now()
    start = DateTime.add(now, -30, :day)
    {start, now}
  end

  defp calculate_time_range(_) do
    now = DateTime.utc_now()
    start = DateTime.add(now, -@default_timeframe_days, :day)
    {start, now}
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.truncate(dt, :second)
  defp format_datetime(dt), do: dt

  defp postgres?, do: Acs.MetaHarness.SQL.postgres?()

  defp run_query(query, params) do
    if Code.ensure_loaded?(Acs.Repo) and function_exported?(Acs.Repo, :transaction, 1) do
      try do
        case Ecto.Adapters.SQL.query(Acs.Repo, Acs.MetaHarness.SQL.adapt(query), params) do
          {:ok, %{columns: columns, rows: rows}} ->
            {:ok,
             Enum.map(rows, fn row ->
               Enum.zip(columns, row) |> Enum.into(%{})
             end)}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        e ->
          Logger.warning("[Analyzer] Query failed: #{inspect(e)}")
          {:error, e}
      end
    else
      {:error, :repo_not_available}
    end
  end

  defp calculate_overall_success_rate(tool_reliability) do
    if map_size(tool_reliability) == 0 do
      0.0
    else
      total_calls =
        Enum.reduce(tool_reliability, 0, fn {_, data}, acc -> acc + data.total_calls end)

      total_successes =
        Enum.reduce(tool_reliability, 0, fn {_, data}, acc -> acc + data.success_count end)

      if total_calls > 0 do
        total_successes / total_calls
      else
        0
      end
    end
  end

  defp find_slowest_tool(latency_analysis) do
    case latency_analysis do
      %{} when map_size(latency_analysis) == 0 ->
        nil

      _ ->
        Enum.max_by(latency_analysis, fn {_, data} -> data.avg_latency end)
        |> elem(0)
    end
  end

  defp find_most_failed_tool(tool_reliability) do
    case tool_reliability do
      %{} when map_size(tool_reliability) == 0 ->
        nil

      _ ->
        Enum.max_by(tool_reliability, fn {_, data} -> data.failure_count end)
        |> elem(0)
    end
  end
end
