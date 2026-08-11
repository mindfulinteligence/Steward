defmodule Acs.MetaHarness.Generator do
  @moduledoc """
  Generates Meta-Harness analysis + improvement plan.
  Called every hour via Superconnector trigger.
  """

  require Logger

  @doc "Generate full analysis + plan, write to files"
  def generate do
    if try_acquire_lock() do
      Logger.info("[Generator] Starting analysis...")

      try do
        do_generate()
      after
        release_lock()
      end
    else
      Logger.warning("[Generator] Skipping generate — a previous run is still in progress")
      %{report: "skipped", plan: "skipped", shipped: false, skipped: true}
    end
  end

  # Guard against concurrent generate() calls (scheduler tick, synchronous
  # trigger_analysis/0, and the mix task can overlap). Only one run writes
  # files and ships Axiom rollups; overlapping runs are skipped.
  @lock_table :acs_meta_harness_generator_lock

  defp ensure_lock_table do
    case :ets.whereis(@lock_table) do
      :undefined ->
        try do
          :ets.new(@lock_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp try_acquire_lock do
    ensure_lock_table()
    clear_stale_lock()
    :ets.insert_new(@lock_table, {:running, self()})
  end

  # Previous holder may have crashed before `after release_lock` ran.
  defp clear_stale_lock do
    case :ets.lookup(@lock_table, :running) do
      [{:running, pid}] when is_pid(pid) ->
        unless Process.alive?(pid), do: :ets.delete(@lock_table, :running)

      _ ->
        :ok
    end
  end

  defp release_lock do
    :ets.delete(@lock_table, :running)
  end

  defp do_generate do
    try do
      analyses = analyze_all_orgs()

      # Prod: ship rollups to steward_meta_analytics (same dataset as agent.tool).
      for {_org, analysis} <- analyses do
        Acs.Observability.MetaAnalytics.ship(analysis)
      end

      analysis = pick_primary(analyses)
      data = gather_all_data(analysis)
      baseline = read_baseline()
      report = build_report(data, baseline)
      plan = build_plan(data)

      {report_path, plan_path} = maybe_write_files(report, plan)

      Logger.info("[Generator] Generated report: #{report_path}, plan: #{plan_path}")

      %{
        report: report_path,
        plan: plan_path,
        shipped: true,
        source: analysis.metadata[:source],
        operations: data.operations.total
      }
    rescue
      e ->
        stacktrace = __STACKTRACE__
        Logger.error("[Generator] Generate failed: #{inspect(e)}")
        Logger.error("[Generator] Stacktrace: #{inspect(stacktrace)}")
        %{report: "error", plan: "error", error: inspect(e)}
    end
  end

  # The scheduler GenServer has no request context, so Acs.Org.current() resolves
  # to the configured ACS_ORG_NAME while OperationLogger records ops under the
  # request-scoped auth org. Analyze per-org (configured + any org with data in
  # the ETS fallback) so no org's ops are silently dropped from the rollup.
  defp analyze_all_orgs do
    orgs = analysis_orgs()

    for org <- orgs do
      {org, Acs.MetaHarness.Analyzer.analyze(timeframe: :last_24_hours, org: org)}
    end
  end

  defp analysis_orgs do
    Enum.uniq([Acs.Org.current() | Acs.Org.all() ++ Acs.MetaHarness.RecentOps.orgs()])
  end

  # Filesystem report/plan reflect the org with the most tool data; fall back to
  # the configured org when nothing has data yet.
  defp pick_primary(analyses) do
    analyses
    |> Enum.max_by(fn {_org, analysis} ->
      analysis.tool_reliability |> Map.keys() |> length()
    end)
    |> elem(1)
  rescue
    _ -> Acs.MetaHarness.Analyzer.analyze(timeframe: :last_24_hours, org: Acs.Org.current())
  end

  # ── Data Gathering ───────────────────────────────────────────────────────────

  defp gather_all_data(analysis) do
    analysis =
      analysis ||
        Acs.MetaHarness.Analyzer.analyze(timeframe: :last_24_hours, org: Acs.Org.current())

    # Transform Analyzer tool_reliability into tools list format
    tools =
      Enum.map(analysis.tool_reliability, fn {name, data} ->
        %{
          "tool_name" => name,
          "total_calls" => data.total_calls,
          "successes" => data.success_count,
          "failures" => data.failure_count + data.error_count,
          "avg_latency" => data.avg_latency,
          "max_latency" => data.max_latency
        }
      end)

    total = Enum.reduce(tools, 0, fn t, a -> a + (t["total_calls"] || 0) end)
    successes = Enum.reduce(tools, 0, fn t, a -> a + (t["successes"] || 0) end)

    operations = %{
      tools: tools,
      total: total,
      success_rate: if(total > 0, do: successes / total, else: 0)
    }

    # Transform Analyzer error_clusters into errors format
    errors =
      Enum.map(analysis.error_clusters, fn c ->
        %{
          "tool_name" => c.tool_name,
          "error_type" => c.error_type,
          "count" => c.occurrence_count
        }
      end)

    # Transform Analyzer agent_behavior into agent_stats format
    agents =
      Enum.map(analysis.agent_behavior, fn {agent_id, data} ->
        %{
          "agent_id" => agent_id,
          "operations" => data.total_operations,
          "successes" => data.success_count,
          "unique_tools" => data.unique_tools_used
        }
      end)

    agent_stats = %{
      agents: agents,
      count: length(agents),
      total_operations: Enum.reduce(agents, 0, fn a, acc -> acc + (a["operations"] || 0) end)
    }

    %{
      operations: operations,
      feedback: query_feedback(),
      errors: errors,
      intake: analysis.intake_friction || [],
      agent_stats: agent_stats,
      source: analysis.metadata[:source] || "unknown"
    }
  end

  defp query_feedback do
    case query_sql(
           "SELECT * FROM task_completion_feedback ORDER BY inserted_at DESC LIMIT 100",
           []
         ) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp query_sql(sql, params) do
    try do
      case Ecto.Adapters.SQL.query(Acs.Repo, Acs.MetaHarness.SQL.adapt(sql), params, log: false) do
        {:ok, result} ->
          {:ok,
           Enum.map(result.rows, fn row ->
             Enum.zip(result.columns, row) |> Enum.into(%{})
           end)}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e ->
        Logger.warning("[Generator] Query failed: #{inspect(e)}")
        {:error, inspect(e)}
    end
  end

  # ── Baseline Support ──────────────────────────────────────────────────────────

  defp read_baseline do
    case File.read("metaanalysis/baseline.json") do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, baseline} -> baseline
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp query_errors_since(baseline_timestamp) do
    sql = """
    SELECT tool_name, error_type, COUNT(*) as count
    FROM acs_tool_operations
    WHERE status IN ('failure', 'error')
      AND created_at > ?1
    GROUP BY tool_name, error_type
    ORDER BY count DESC
    LIMIT 20
    """

    case query_sql(sql, [baseline_timestamp]) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  # ── Report Building ─────────────────────────────────────────────────────────

  defp build_report(data, baseline) do
    baseline_section =
      if baseline do
        since_data = query_errors_since(baseline["set_at"])
        format_baseline_section(baseline, since_data)
      else
        ""
      end

    """
    # ACS Meta-Harness Analysis
    #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")} UTC

    ## System Health
    - Total Operations (24h): #{data.operations.total}
    - Overall Success Rate: #{format_rate(data.operations.success_rate)}
    - Unique Tools Used: #{length(data.operations.tools)}
    - Active Agents: #{data.agent_stats.count}
    - Agent Feedback Submissions: #{length(data.feedback)}
    - Data Source: #{data.source}

    #{format_zero_alert(data)}
    ## Tool Performance (sorted by failures)
    #{format_tool_table(data.operations.tools)}

    ## Error Clusters
    #{format_errors(data.errors)}

    ## Intake Friction (prompt-tuning)
    #{format_intake(data.intake)}
    #{baseline_section}
    ## Agent Feedback Highlights
    #{format_feedback(data.feedback)}
    """
  end

  # An all-zero report is indistinguishable from a healthy quiet system unless
  # we call it out. Zero ops usually means the DB source is empty AND the ETS
  # fallback found nothing — surface that so data-source flips are visible.
  defp format_zero_alert(%{operations: %{total: 0}} = data) do
    "> ⚠️ **NO OPERATIONS RECORDED** — the analyzer found zero tool operations. " <>
      "This usually means the local/Postgres `acs_tool_operations` table is empty " <>
      "or unreachable and the in-memory RecentOps fallback held no data. " <>
      "(Data source: #{data.source})\n\n"
  end

  defp format_zero_alert(_), do: ""

  defp format_intake([]), do: "  _No intake gates — default-allow is holding_"

  defp format_intake(rows) do
    header =
      "_High gate rates mean Claude is slowed; edit org prompts at Settings → Prompts " <>
        "(memory/intake, skills/intake). Frequent intake_bypass = false positives._\n\n"

    body =
      Enum.map(rows, fn row ->
        hint = row[:prompt_hint] || row["prompt_hint"] || ""

        "| #{row[:tool_name] || row["tool_name"]} | #{row[:error_type] || row["error_type"]} | #{row[:occurrence_count] || row["occurrence_count"]} | #{hint} |"
      end)
      |> Enum.join("\n")

    header <> "| tool | gate | count | hint |\n|---|---|---|---|\n" <> body
  end

  defp format_rate(rate) when is_number(rate), do: "#{Float.round(rate * 100.0, 1)}%"
  defp format_rate(_), do: "N/A"

  defp format_tool_table([]), do: "  _No data_"

  defp format_tool_table(tools) do
    tools
    |> Enum.sort_by(fn t -> -(t["failures"] || 0) end)
    |> Enum.map(fn t ->
      rate =
        if t["total_calls"] && t["total_calls"] > 0 do
          (t["successes"] || 0) / t["total_calls"]
        else
          0.0
        end

      "| #{t["tool_name"]} | #{t["total_calls"]} | #{format_rate(rate)} | #{format_ms(t["avg_latency"])} |"
    end)
    |> Enum.join("\n")
  end

  defp format_ms(nil), do: "0.0ms"
  defp format_ms(n) when is_number(n), do: "#{Float.round(n * 1.0, 1)}ms"
  defp format_ms(_), do: "0.0ms"

  defp format_errors([]), do: "  _No errors_"

  defp format_errors(errors) do
    Enum.map(errors, fn e ->
      "  - #{e["tool_name"]}: #{e["error_type"]} (#{e["count"]}x)"
    end)
    |> Enum.join("\n")
  end

  defp format_feedback([]), do: "  _No feedback yet_"
  defp format_feedback(""), do: "  _No feedback yet_"
  defp format_feedback("[]"), do: "  _No feedback yet_"

  defp format_feedback(feedback) do
    top_learned = get_top_values(feedback, "most_surprising", 3)
    top_issues = get_top_values(feedback, "most_time_consuming", 3)

    # Filter out "no improvements needed" entries
    improvements =
      Enum.reject(feedback |> Enum.map(& &1["improvements_needed"]), fn s ->
        is_nil(s) or s == "" or String.match?(s, ~r/^no improvements? needed/i)
      end)

    top_improvements = get_top_values(improvements, nil, 3)

    guidance_section = format_guidance_effectiveness(feedback)

    """
    ### Top Learned for Future Agents
    #{top_learned}

    ### Top Issues Encountered
    #{top_issues}

    ### Top Improvements Requested
    #{top_improvements}
    #{guidance_section}
    """
  end

  defp format_guidance_effectiveness(feedback) when is_binary(feedback), do: ""

  defp format_guidance_effectiveness(feedback) do
    total = length(feedback)
    useful = Enum.count(feedback, fn f -> f["guidance_useful"] == true end)
    not_useful = Enum.count(feedback, fn f -> f["guidance_useful"] == false end)

    helpful_ids =
      feedback
      |> Enum.flat_map(&decode_guidance_items(&1["guidance_items_helpful"]))
      |> Enum.reject(&is_nil/1)

    confusing_ids =
      feedback
      |> Enum.flat_map(&decode_guidance_items(&1["guidance_items_confusing"]))
      |> Enum.reject(&is_nil/1)

    missing_items = feedback |> Enum.map(& &1["guidance_missing"]) |> Enum.reject(&is_nil/1)

    if total == 0 do
      ""
    else
      helpful_top =
        Enum.frequencies(helpful_ids)
        |> Enum.sort_by(fn {_, v} -> -v end)
        |> Enum.take(3)
        |> Enum.map(fn {k, v} -> "#{k}(#{v})" end)
        |> Enum.join(", ")

      confusing_top =
        Enum.frequencies(confusing_ids)
        |> Enum.sort_by(fn {_, v} -> -v end)
        |> Enum.take(3)
        |> Enum.map(fn {k, v} -> "#{k}(#{v})" end)
        |> Enum.join(", ")

      missing_top =
        Enum.frequencies(missing_items)
        |> Enum.sort_by(fn {_, v} -> -v end)
        |> Enum.take(2)
        |> Enum.map(fn {k, v} -> "#{k}(#{v})" end)
        |> Enum.join(", ")

      """

      ### Guidance Effectiveness
      - Total: #{total} | Useful: #{useful} | Not Useful: #{not_useful}
      - Helpful items: #{if helpful_top == "", do: "none", else: helpful_top}
      - Confusing items: #{if confusing_top == "", do: "none", else: confusing_top}
      - Common gaps: #{if missing_top == "", do: "none reported", else: missing_top}
      """
    end
  end

  # guidance_items_helpful / guidance_items_confusing are stored as JSON-array
  # strings (encode_array_field in error_handlers.ex). Decode to a list for
  # flat_mapping; anything unparseable degrades to [].
  defp decode_guidance_items(nil), do: []
  defp decode_guidance_items(items) when is_list(items), do: items

  defp decode_guidance_items(items) when is_binary(items) do
    case Jason.decode(items) do
      {:ok, decoded} when is_list(decoded) -> decoded
      _ -> []
    end
  end

  defp decode_guidance_items(_), do: []

  defp get_top_values(feedback, field, count) do
    values =
      case field do
        nil -> feedback
        _ -> Enum.map(feedback, & &1[field])
      end

    values
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reject(&String.starts_with?(&1, "Key learning from task"))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, v} -> -v end)
    |> Enum.take(count)
    |> Enum.map(fn {k, v} -> "  - #{k} (#{v})" end)
    |> Enum.join("\n")
    |> case do
      "" -> "  _None_"
      s -> s
    end
  end

  # ── Baseline Section Formatting ─────────────────────────────────────────────

  defp format_baseline_section(baseline, since_data) do
    snapshot = baseline["error_snapshot"]

    baseline_errors =
      if(is_list(snapshot), do: snapshot, else: [])
      |> Enum.map(fn e ->
        tool = e["tool_name"] || "?"
        error_type = e["error_type"] || "?"
        "  - #{tool}: #{error_type} (#{e["count"]}x)"
      end)
      |> Enum.join("\n")

    since_errors =
      if since_data && since_data != [] do
        Enum.map(since_data, fn e ->
          "  - #{e["tool_name"]}: #{e["error_type"]} (#{e["count"]}x)"
        end)
        |> Enum.join("\n")
      else
        "  - None (no new errors since baseline)"
      end

    """
    ## Baseline Comparison
    Baseline set at: #{baseline["set_at"]}
    Reason: #{baseline["reason"]}

    ### Errors at baseline:
    #{if baseline_errors == "", do: "  _None_", else: baseline_errors}

    ### New errors since baseline:
    #{since_errors}
    """
  end

  # ── Plan Building ─────────────────────────────────────────────────────────────

  defp build_plan(data) do
    """
    # ACS Meta-Harness Improvement Plan
    #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")} UTC

    ## Analyze & Recommend

    Based on the system data below, provide:
    1. **Top 3 Issues** - The most critical problems affecting agents
    2. **Root Causes** - Why these issues are happening
    3. **Actionable Improvements** - Specific, concrete steps to fix each issue
    4. **Priority Ranking** - What to tackle first (HIGH/MED/LOW)
    5. **Expected Impact** - How much improvement each fix would deliver

    ## Data Summary

    ### System Health
    - Total Operations (24h): #{data.operations.total}
    - Overall Success Rate: #{format_rate(data.operations.success_rate)}
    - Active Agents: #{data.agent_stats.count}

    ### Tool Performance (bottom 3 by success rate)
    #{format_bottom_tools(data.operations.tools)}

    ### Error Patterns
    #{format_errors(data.errors)}

    ### Intake Friction (save_memory / skill_save)
    #{format_intake(data.intake)}
    - Action: if gate count is high, raise the bar in `memory/intake` / `skills/intake` prompts (prefer allow). If `intake_bypass` dominates, gates are false positives.

    ### Agent Feedback
    - Learned: #{Enum.take(data.feedback, 3) |> Enum.map(& &1["most_surprising"]) |> Enum.reject(&is_nil/1) |> Enum.join(", ")}
    - Issues: #{Enum.take(data.feedback, 3) |> Enum.map(& &1["most_time_consuming"]) |> Enum.reject(&is_nil/1) |> Enum.join(", ")}
    - Requests: #{Enum.take(data.feedback, 3) |> Enum.map(& &1["improvements_needed"]) |> Enum.reject(&is_nil/1) |> Enum.join(", ")}

    ### Guidance Effectiveness (from new tracking)
    - Useful: #{Enum.count(data.feedback, fn f -> f["guidance_useful"] == true end)}/#{length(data.feedback)}
    - Helpful items: #{data.feedback |> Enum.flat_map(&decode_guidance_items(&1["guidance_items_helpful"])) |> Enum.frequencies() |> Enum.sort_by(fn {_, v} -> -v end) |> Enum.take(3) |> Enum.map(fn {k, _v} -> "#{k}" end) |> Enum.join(", ")}
    - Confusing items: #{data.feedback |> Enum.flat_map(&decode_guidance_items(&1["guidance_items_confusing"])) |> Enum.frequencies() |> Enum.sort_by(fn {_, v} -> -v end) |> Enum.take(3) |> Enum.map(fn {k, _v} -> "#{k}" end) |> Enum.join(", ")}

    ## Output Format

    Provide your analysis in markdown with these sections:
    - **Critical Issues** (top 3)
    - **Root Cause Analysis**
    - **Improvement Recommendations** (numbered, specific — include prompt edits when intake friction is high)
    - **Priority Matrix** (HIGH/MED/LOW with rationale)
    - **Next Steps** (what to do first)
    """
  end

  defp format_bottom_tools([]), do: "  _No data_"

  defp format_bottom_tools(tools) do
    tools
    |> Enum.sort_by(fn t ->
      rate =
        if t["total_calls"] && t["total_calls"] > 0,
          do: (t["successes"] || 0) / t["total_calls"],
          else: 1.0

      rate
    end)
    |> Enum.take(3)
    |> Enum.map(fn t ->
      rate =
        if t["total_calls"] && t["total_calls"] > 0,
          do: Float.round((t["successes"] || 0) / t["total_calls"] * 1.0, 2),
          else: 0.0

      "  - #{t["tool_name"]}: #{format_rate(rate)} success, #{t["failures"] || 0} failures, #{format_ms(t["avg_latency"])} avg"
    end)
    |> Enum.join("\n")
  end

  # ── File Writing ──────────────────────────────────────────────────────────────

  # Local/dev: write markdown under metaanalysis/. Prod containers may be read-only —
  # Axiom ship is the source of truth; file write is best-effort.
  defp maybe_write_files(report, plan) do
    case File.mkdir_p("metaanalysis") do
      :ok ->
        {write_report(report), write_plan(plan)}

      {:error, reason} ->
        Logger.warning("[Generator] Skipping local metaanalysis files: #{inspect(reason)}")
        {"axiom-only", "axiom-only"}
    end
  rescue
    e ->
      Logger.warning("[Generator] Skipping local metaanalysis files: #{inspect(e)}")
      {"axiom-only", "axiom-only"}
  end

  defp write_report(content) do
    path = "metaanalysis/report_#{timestamp()}.md"
    File.write!(path, content)
    path
  end

  defp write_plan(content) do
    path = "metaanalysis/plan_#{timestamp()}.md"
    File.write!(path, content)
    path
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")
  end
end
