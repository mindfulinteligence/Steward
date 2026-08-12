defmodule Acs.MetaHarness.DocumentGenerator do
  @moduledoc """
  Generates improvement documents from Meta-Harness analysis.

  Produces markdown reports summarizing tool reliability, latency,
  and agent behavior patterns with actionable recommendations.
  """

  require Logger

  @doc """
  Generates a markdown report from analysis results.

  ## Options
    - `:timeframe` - Analysis window: `:last_24_hours`, `:last_7_days`, `:last_30_days`
    - `:format` - Output format: `:markdown` (default)
  """
  @spec generate(keyword()) :: String.t()
  def generate(opts \\ []) do
    timeframe = Keyword.get(opts, :timeframe, :last_24_hours)

    analysis =
      opts
      |> Keyword.take([:timeframe, :min_sample_size, :min_cluster_size, :ets_fallback])
      |> Keyword.put_new(:timeframe, timeframe)
      |> Acs.MetaHarness.Analyzer.analyze()

    build_report(analysis, timeframe)
  end

  @doc """
  Generates and writes report to a file.
  """
  @spec generate_and_write(keyword(), String.t()) :: :ok | {:error, term()}
  def generate_and_write(opts \\ [], output_path) do
    report = generate(opts)

    case File.write(output_path, report) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[DocumentGenerator] Failed to write: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Private: Report Building ────────────────────────────────────────────────

  defp build_report(analysis, _timeframe) do
    feedback = summarize_feedback()
    telemetry = fetch_telemetry_insights()

    """
    # ACS Meta-Harness Report
    #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")} UTC

    ## Summary
    - Tools Analyzed: #{map_size(analysis.tool_reliability)}
    - Execution Success Rate: #{format_rate(calculate_overall_success_rate(analysis.tool_reliability))}
    - Total Executions: #{total_execution_count(analysis)} (plus #{total_discovery_count(analysis)} discovery probes)
    - Slowest Tool: #{format_tool(analysis.latency_analysis)}
    - Most Failed Tool: #{format_tool(analysis.tool_reliability)}
    - Error Clusters: #{length(analysis.error_clusters)}
    - Active Agents: #{map_size(analysis.agent_behavior)}

    ## Tool Reliability
    #{format_tool_reliability(analysis.tool_reliability)}

    ## Latency Analysis
    #{format_latency(analysis.latency_analysis)}

    ## Error Clusters
    #{format_error_clusters(analysis.error_clusters)}

    ## Agent Behavior
    #{format_agent_behavior(analysis.agent_behavior)}

    ## Agent Feedback Insights
    #{format_feedback_insights(feedback)}

    ## Tool Telemetry Insights
    #{format_telemetry_insights(telemetry)}

    ## Recommendations
    #{generate_recommendations(analysis, feedback, telemetry)}
    """
  end

  # ── Private: Feedback Summarization ────────────────────────────────────────

  defp summarize_feedback do
    case Process.whereis(Acs.Repo) do
      nil ->
        %{}

      _ ->
        feedback = Acs.Repo.all(Acs.Acs.TaskCompletionFeedback) || []

        if Enum.empty?(feedback) do
          %{}
        else
          %{
            total: length(feedback),
            top_learned: get_top_values(feedback, :learned_for_agents, 3),
            top_issues: get_top_values(feedback, :most_time_consuming, 3),
            top_improvements: get_top_values(feedback, :improvements_needed, 3),
            guidance_summary: summarize_guidance_data(feedback)
          }
        end
    end
  rescue
    _ -> %{}
  end

  defp get_top_values(feedback, field, count) do
    feedback
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, v} -> -v end)
    |> Enum.take(count)
    |> Enum.map(fn {k, v} -> "#{k} (#{v})" end)
    |> Enum.join(", ")
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

  defp summarize_guidance_data(feedback) do
    total = length(feedback)
    useful = Enum.count(feedback, fn f -> f.guidance_useful == true end)
    not_useful = Enum.count(feedback, fn f -> f.guidance_useful == false end)

    helpful_ids =
      feedback
      |> Enum.flat_map(fn f -> decode_guidance_items(f.guidance_items_helpful) end)
      |> Enum.reject(&is_nil/1)

    confusing_ids =
      feedback
      |> Enum.flat_map(fn f -> decode_guidance_items(f.guidance_items_confusing) end)
      |> Enum.reject(&is_nil/1)

    missing_texts = feedback |> Enum.map(& &1.guidance_missing) |> Enum.reject(&is_nil/1)

    %{
      total: total,
      useful: useful,
      not_useful: not_useful,
      helpful_items:
        Enum.frequencies(helpful_ids) |> Enum.sort_by(fn {_, v} -> -v end) |> Enum.take(5),
      confusing_items:
        Enum.frequencies(confusing_ids) |> Enum.sort_by(fn {_, v} -> -v end) |> Enum.take(5),
      common_gaps: missing_texts
    }
  end

  defp format_feedback_insights(%{}) do
    "  _No feedback submissions yet_"
  end

  defp format_feedback_insights(feedback_data) do
    """
    - Feedback Submissions: #{feedback_data.total}
    - Top Learned for Agents: #{feedback_data.top_learned}
    - Top Issues: #{feedback_data.top_issues}
    - Top Improvements: #{feedback_data.top_improvements}
    #{format_guidance_summary(feedback_data[:guidance_summary])}
    """
  end

  defp format_guidance_summary(nil), do: ""

  defp format_guidance_summary(gs) do
    if gs[:total] > 0 do
      total = gs[:total]
      useful = gs[:useful] || 0
      rate = if total > 0, do: "#{round(useful / total * 100)}%", else: "N/A"

      """
      - Guidance Effectiveness: #{useful}/#{total} useful (#{rate})
      - Helpful items: #{Enum.map_join(gs[:helpful_items] || [], ", ", fn {id, c} -> "#{id}(#{c})" end)}
      - Confusing items: #{Enum.map_join(gs[:confusing_items] || [], ", ", fn {id, c} -> "#{id}(#{c})" end)}
      """
    else
      ""
    end
  end

  defp calculate_overall_success_rate(tool_reliability) do
    if map_size(tool_reliability) == 0 do
      0
    else
      total = Enum.reduce(tool_reliability, 0, fn {_, d}, a -> a + d.total_calls end)
      successes = Enum.reduce(tool_reliability, 0, fn {_, d}, a -> a + d.success_count end)
      if total > 0, do: successes / total, else: 0
    end
  end

  defp format_rate(rate) when is_number(rate), do: "#{Float.round(rate * 100.0, 1)}%"
  defp format_rate(_), do: "N/A"

  defp format_tool(nil), do: "N/A"
  defp format_tool({name, _}), do: name
  defp format_tool(map) when map_size(map) == 0, do: "N/A"

  defp format_tool(map) do
    {name, _} = Enum.max_by(map, fn {_, d} -> d.avg_latency || 0 end)
    name
  end

  defp format_tool_reliability(reliability) when map_size(reliability) == 0 do
    "  _No data available_"
  end

  defp format_tool_reliability(reliability) do
    reliability
    |> Enum.sort_by(fn {_, d} -> d.failure_count end, :desc)
    |> Enum.take(10)
    |> Enum.map(fn {name, data} ->
      failures = if data.failure_count > 0, do: ", #{data.failure_count} failures", else: ""

      "  - **#{name}**: #{data.total_calls} executions, #{format_rate(data.success_rate)} success#{failures}, #{data.discovery_count} discovery probes"
    end)
    |> Enum.join("\n")
  end

  defp format_latency(latency) when map_size(latency) == 0 do
    "  _No data available_"
  end

  defp format_latency(latency) do
    latency
    |> Enum.sort_by(fn {_, d} -> d.avg_latency || 0 end, :desc)
    |> Enum.take(10)
    |> Enum.map(fn {name, data} ->
      "  - **#{name}**: avg #{format_ms(data.avg_latency)}, p95 #{format_ms(Map.get(data, :p95_latency))}, p99 #{format_ms(Map.get(data, :p99_latency))}"
    end)
    |> Enum.join("\n")
  end

  defp format_error_clusters([]) do
    "  _No error clusters detected_"
  end

  defp format_error_clusters(clusters) do
    clusters
    |> Enum.take(10)
    |> Enum.map(fn c ->
      "  - **#{c.tool_name}** / **#{c.error_type}**: #{c.occurrence_count} occurrences"
    end)
    |> Enum.join("\n")
  end

  defp format_ms(nil), do: "0.0ms"
  defp format_ms(n) when is_number(n), do: "#{Float.round(n * 1.0, 1)}ms"
  defp format_ms(_), do: "0.0ms"

  defp format_agent_behavior(behavior) when map_size(behavior) == 0 do
    "  _No agent data available_"
  end

  defp format_agent_behavior(behavior) do
    behavior
    |> Enum.sort_by(fn {_, d} -> d.total_operations end, :desc)
    |> Enum.take(10)
    |> Enum.map(fn {agent_id, data} ->
      "  - **#{agent_id}**: #{data.success_count} execs, #{data.discovery_count} discoveries, #{format_rate(data.success_rate)} success, #{data.unique_tools_used} tools"
    end)
    |> Enum.join("\n")
  end

  # ── Telemetry Insights ─────────────────────────────────────────────────────

  defp fetch_telemetry_insights do
    case run_telemetry_query() do
      {:ok, results} when is_list(results) ->
        %{
          tool_chains: extract_tool_chains(results),
          retry_patterns: extract_retry_patterns(results),
          discovered_tools: extract_discovered_tools(results),
          error_bursts: extract_error_bursts(results)
        }

      _ ->
        %{tool_chains: [], retry_patterns: [], discovered_tools: [], error_bursts: []}
    end
  rescue
    _ -> %{tool_chains: [], retry_patterns: [], discovered_tools: [], error_bursts: []}
  end

  defp run_telemetry_query do
    query = """
      SELECT
        tool_name,
        status,
        execution_chain_id,
        sequence_order,
        attempt,
        tool_discovered,
        error_burst,
        error_type,
        created_at
      FROM acs_tool_operations
      WHERE created_at >= ?1
      ORDER BY execution_chain_id, sequence_order
    """

    cutoff = DateTime.add(DateTime.utc_now(), -1, :day)

    if Code.ensure_loaded?(Acs.Repo) and function_exported?(Acs.Repo, :transaction, 1) do
      try do
        case Ecto.Adapters.SQL.query(Acs.Repo, Acs.MetaHarness.SQL.adapt(query), [cutoff]) do
          {:ok, %{columns: columns, rows: rows}} ->
            {:ok,
             Enum.map(rows, fn row ->
               Enum.zip(columns, row) |> Enum.into(%{})
             end)}

          {:error, _} ->
            {:error, :query_failed}
        end
      rescue
        _ -> {:error, :repo_not_available}
      end
    else
      {:error, :repo_not_available}
    end
  end

  defp extract_tool_chains(results) do
    # Group by execution_chain_id and extract chains
    results
    |> Enum.group_by(& &1["execution_chain_id"])
    |> Enum.reject(fn {id, _} -> is_nil(id) or id == "" end)
    |> Enum.map(fn {_id, ops} ->
      chain =
        ops
        |> Enum.sort_by(& &1["sequence_order"])
        |> Enum.map(& &1["tool_name"])
        |> Enum.dedup()

      %{chain: Enum.join(chain, " → "), length: length(chain), ops: length(ops)}
    end)
    |> Enum.reject(&(&1.length < 2))
    |> Enum.sort_by(&(-&1.ops))
    |> Enum.take(5)
  end

  defp extract_retry_patterns(results) do
    # Find tools with high attempt numbers
    results
    |> Enum.filter(&(&1["attempt"] > 1))
    |> Enum.group_by(& &1["tool_name"])
    |> Enum.map(fn {tool, ops} -> {tool, length(ops)} end)
    |> Enum.sort_by(fn {_, count} -> -count end)
    |> Enum.take(5)
    |> Enum.map(fn {tool, count} -> "#{tool} (#{count} retries)" end)
  end

  defp extract_discovered_tools(results) do
    # Find tools that were marked as discovered
    results
    |> Enum.filter(fn row ->
      val = row["tool_discovered"]
      val == true or val == "true"
    end)
    |> Enum.map(& &1["tool_name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.dedup()
    |> Enum.take(10)
  end

  defp extract_error_bursts(results) do
    # Find error bursts
    results
    |> Enum.filter(fn row ->
      val = row["error_burst"]
      val == true or val == "true"
    end)
    |> Enum.group_by(& &1["tool_name"])
    |> Enum.map(fn {tool, ops} -> {tool, length(ops)} end)
    |> Enum.sort_by(fn {_, count} -> -count end)
    |> Enum.take(5)
    |> Enum.map(fn {tool, count} -> "#{tool} (#{count} burst errors)" end)
  end

  defp format_telemetry_insights(%{
         tool_chains: [],
         retry_patterns: [],
         discovered_tools: [],
         error_bursts: []
       }) do
    "  _No telemetry data available yet_"
  end

  defp format_telemetry_insights(telemetry) do
    parts = []

    parts =
      if telemetry.tool_chains != [] do
        chains_str =
          telemetry.tool_chains
          |> Enum.map(fn c -> "    - #{c.chain} (#{c.ops} calls)" end)
          |> Enum.join("\n")

        ["Tool Sequences (common chains):\n#{chains_str}"]
      else
        parts
      end

    parts =
      if telemetry.retry_patterns != [] do
        ["Retry Patterns: #{Enum.join(telemetry.retry_patterns, ", ")}" | parts]
      else
        parts
      end

    parts =
      if telemetry.discovered_tools != [] do
        [
          "Tool Discovery: #{Enum.join(telemetry.discovered_tools, ", ")} (tools agents wish existed)"
        ]
      else
        parts
      end

    parts =
      if telemetry.error_bursts != [] do
        ["Error Bursts: #{Enum.join(telemetry.error_bursts, ", ")}"]
      else
        parts
      end

    if parts == [], do: "  _No telemetry data available yet_", else: Enum.join(parts, "\n")
  end

  defp generate_recommendations(analysis, feedback, telemetry) do
    recs = []

    # High failure tools
    failing = Enum.filter(analysis.tool_reliability, fn {_, d} -> d.success_rate < 0.9 end)

    recs =
      if failing != [] do
        recs ++
          [
            "- Investigate tools with <90% success rate: #{Enum.map_join(failing, ", ", &elem(&1, 0))}"
          ]
      else
        recs
      end

    # Slow tools (p95 > 500ms)
    slow = Enum.filter(analysis.latency_analysis, fn {_, d} -> (d.p95_latency || 0) > 500 end)

    recs =
      if slow != [] do
        recs ++
          ["- Optimize slow tools (p95 > 500ms): #{Enum.map_join(slow, ", ", &elem(&1, 0))}"]
      else
        recs
      end

    # Error clusters
    recs =
      if analysis.error_clusters != [] do
        recs ++ ["- Review #{length(analysis.error_clusters)} error clusters for patterns"]
      else
        recs
      end

    # Intake friction → prompt tuning
    intake = Map.get(analysis, :intake_friction) || []

    recs =
      if intake != [] do
        top = Enum.take(intake, 3)

        hints =
          Enum.map_join(top, "; ", fn row ->
            "#{row.tool_name}/#{row.error_type}×#{row.occurrence_count}"
          end)

        recs ++
          [
            "- Intake friction high (#{hints}) — edit Settings → Prompts memory/intake or skills/intake to raise the allow bar"
          ]
      else
        recs
      end

    # Tool discovery - agents requesting unknown tools
    recs =
      if telemetry.discovered_tools != [] do
        recs ++
          [
            "- Consider implementing requested tools: #{Enum.join(telemetry.discovered_tools, ", ")}"
          ]
      else
        recs
      end

    # Retry patterns - tools with high retry counts
    recs =
      if telemetry.retry_patterns != [] do
        recs ++ ["- High retry rates detected on: #{Enum.join(telemetry.retry_patterns, ", ")}"]
      else
        recs
      end

    # Error bursts - clustered errors
    recs =
      if telemetry.error_bursts != [] do
        recs ++ ["- Address error burst patterns in: #{Enum.join(telemetry.error_bursts, ", ")}"]
      else
        recs
      end

    # Agent feedback recommendations
    recs =
      if feedback != %{} and feedback.total > 0 do
        if feedback.top_improvements != "" do
          recs ++ ["- From agent feedback: #{feedback.top_improvements}"]
        else
          recs
        end
      else
        recs
      end

    if recs == [], do: ["  _No specific recommendations (system healthy)_"], else: recs
  end

  defp total_discovery_count(analysis) do
    analysis.tool_reliability
    |> Enum.reduce(0, fn {_, d}, acc -> acc + (d.discovery_count || 0) end)
  end

  defp total_execution_count(analysis) do
    analysis.tool_reliability
    |> Enum.reduce(0, fn {_, d}, acc -> acc + d.total_calls end)
  end
end
