defmodule Acs.Observability.MetaAnalytics do
  @moduledoc """
  Ships Meta-Harness hourly analysis into Axiom `steward_meta_analytics`
  (same dataset as `agent.tool` / `agent.feedback`).

  Same dataset on purpose — agents filter by `message`:
  - `meta.summary` — one row per analysis cycle
  - `meta.tool` — per-tool reliability/latency
  - `meta.error_cluster` — grouped failures
  - `meta.intake` — save_memory/skill_save intake gates (prompt-tuning signal)
  - `meta.agent` — per-agent behavior rollup
  """

  alias Acs.Observability.AxiomLogExporter

  @doc "Enqueue flat analysis events from `Acs.MetaHarness.Analyzer.analyze/1` output."
  def ship(analysis) when is_map(analysis) do
    cycle_id = cycle_id()
    meta = Map.get(analysis, :metadata) || %{}
    timeframe = to_string(Map.get(meta, :timeframe) || :last_24_hours)
    org = Map.get(meta, :org)

    ship_summary(analysis, cycle_id, timeframe, org)
    ship_tools(analysis, cycle_id, timeframe, org)
    ship_errors(analysis, cycle_id, timeframe, org)
    ship_intake(analysis, cycle_id, timeframe, org)
    ship_agents(analysis, cycle_id, timeframe, org)
    :ok
  rescue
    _ -> :ok
  end

  def ship(_), do: :ok

  defp ship_summary(analysis, cycle_id, timeframe, org) do
    tools = Map.get(analysis, :tool_reliability) || %{}
    clusters = Map.get(analysis, :error_clusters) || []
    intake = Map.get(analysis, :intake_friction) || []
    agents = Map.get(analysis, :agent_behavior) || %{}

    {total, success, failure, error, discovery} =
      Enum.reduce(tools, {0, 0, 0, 0, 0}, fn {_name, t}, {tot, ok, fail, err, disc} ->
        {tot + (t.total_calls || 0), ok + (t.success_count || 0), fail + (t.failure_count || 0),
         err + (t.error_count || 0), disc + (t.discovery_count || 0)}
      end)

    exec = success + failure + error
    success_rate = if exec > 0, do: success / exec, else: nil
    intake_gates = Enum.reduce(intake, 0, fn row, acc -> acc + (row.occurrence_count || 0) end)

    enqueue(
      %{
        "message" => "meta.summary",
        "event" => "meta.summary",
        "cycle_id" => cycle_id,
        "timeframe" => timeframe,
        "total_ops" => total,
        "success_count" => success,
        "failure_count" => failure,
        "error_count" => error,
        "discovery_count" => discovery,
        "success_rate" => success_rate,
        "tool_count" => map_size(tools),
        "error_cluster_count" => length(clusters),
        "intake_gate_count" => intake_gates,
        "active_agents" => map_size(agents)
      },
      org
    )
  end

  defp ship_tools(analysis, cycle_id, timeframe, org) do
    latency = Map.get(analysis, :latency_analysis) || %{}

    for {name, t} <- Map.get(analysis, :tool_reliability) || %{} do
      lat = Map.get(latency, name) || %{}

      enqueue(
        %{
          "message" => "meta.tool",
          "event" => "meta.tool",
          "cycle_id" => cycle_id,
          "timeframe" => timeframe,
          "tool_name" => name,
          "total_calls" => t.total_calls,
          "success_count" => t.success_count,
          "failure_count" => t.failure_count,
          "discovery_count" => t.discovery_count,
          "success_rate" => t.success_rate,
          "avg_latency_ms" => t.avg_latency,
          "max_latency_ms" => t.max_latency,
          "p50_latency_ms" => Map.get(lat, :p50_latency),
          "p95_latency_ms" => Map.get(lat, :p95_latency)
        },
        org
      )
    end
  end

  defp ship_errors(analysis, cycle_id, timeframe, org) do
    for c <- Map.get(analysis, :error_clusters) || [] do
      enqueue(
        %{
          "message" => "meta.error_cluster",
          "event" => "meta.error_cluster",
          "cycle_id" => cycle_id,
          "timeframe" => timeframe,
          "tool_name" => c.tool_name,
          "error_type" => c.error_type,
          "occurrence_count" => c.occurrence_count,
          "sample_message" => c.sample_message,
          "agents" => truncate(c.agents, 200)
        },
        org
      )
    end
  end

  defp ship_intake(analysis, cycle_id, timeframe, org) do
    for row <- Map.get(analysis, :intake_friction) || [] do
      enqueue(
        %{
          "message" => "meta.intake",
          "event" => "meta.intake",
          "cycle_id" => cycle_id,
          "timeframe" => timeframe,
          "tool_name" => row.tool_name,
          "error_type" => row.error_type,
          "occurrence_count" => row.occurrence_count,
          "sample_message" => row.sample_message,
          "prompt_hint" => row.prompt_hint
        },
        org
      )
    end
  end

  defp ship_agents(analysis, cycle_id, timeframe, org) do
    for {agent_id, a} <- Map.get(analysis, :agent_behavior) || %{} do
      enqueue(
        %{
          "message" => "meta.agent",
          "event" => "meta.agent",
          "cycle_id" => cycle_id,
          "timeframe" => timeframe,
          "agent_id" => agent_id,
          "total_operations" => a.total_operations,
          "success_count" => a.success_count,
          "failure_count" => a.failure_count,
          "discovery_count" => a.discovery_count,
          "unique_tools" => a.unique_tools_used,
          "success_rate" => a.success_rate,
          "avg_latency_ms" => a.avg_latency
        },
        org
      )
    end
  end

  defp enqueue(fields, org) do
    event =
      Map.merge(
        %{
          "_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "severity" => "INFO",
          "level" => "info",
          "service" => "steward_acs",
          "module" => "Acs.Observability.MetaAnalytics",
          "org" => org
        },
        fields
      )
      |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    if Process.whereis(Acs.Observability.AgentOpsExporter) do
      AxiomLogExporter.enqueue(event, Acs.Observability.AgentOpsExporter)
    end

    if Process.whereis(AxiomLogExporter) do
      AxiomLogExporter.enqueue(event)
    end

    :ok
  end

  defp cycle_id do
    DateTime.utc_now() |> DateTime.to_unix() |> to_string()
  end

  defp truncate(nil, _), do: nil
  defp truncate(v, n) when is_binary(v), do: String.slice(v, 0, n)
  defp truncate(v, n), do: v |> to_string() |> String.slice(0, n)
end
