defmodule Acs.MCP.Tools.AppExtension.Default do
  @moduledoc """
  Default implementation of `Acs.MCP.Tools.AppExtension`.

  Feeds the `memory_health_check` and `connection_diagnostic` MCP tools from
  this repo's real data sources:

    * memory status counts from `Acs.Memory.Indexer.count_by_status/1`
    * memories pending human review from
      `Acs.Memory.Indexer.count_memories_needing_review/1`
    * error traces (DLQ analog) from `Acs.MCP.ErrorTrace.list_traces/1`
    * memory-pipeline worker liveness via `Process.whereis/1`
    * LLM provider config from `:steward_acs` app env
  """

  @behaviour Acs.MCP.Tools.AppExtension

  @memory_workers [Acs.Memory.FileWatcher, Acs.Memory.Auditor, Acs.Memory.VaultSweeper]

  @impl true
  def fetch_memory_stats(org_id) do
    counts = safe_count_by_status(org_id)
    total = Enum.reduce(counts, 0, fn {_status, n}, acc -> acc + n end)

    %{
      "pipeline_worker_status" => worker_status(org_id, counts),
      "message_status_counts" => message_status_counts(counts),
      "dlq_summary" => dlq_summary(org_id),
      "stuck_classified_messages" => %{count: 0, sample: []},
      "pending_items_summary" => %{
        total: Map.get(counts, "proposed", 0),
        overdue_count: safe_needing_review(org_id)
      },
      "memory_totals_by_org" => %{
        records: Map.get(counts, "approved", 0),
        claims: Map.get(counts, "proposed", 0),
        observations: total
      },
      "recent_cycles" => [],
      "pipeline_states" => pipeline_states()
    }
  end

  @impl true
  def fetch_dlq_entries do
    org_id = Acs.Org.current()

    Acs.MCP.ErrorTrace.list_traces(org: org_id, limit: 20)
    |> Enum.map(fn trace ->
      %{
        "id" => trace.id,
        "message_id" => trace.id,
        "original_message" => trace.sample_message || "",
        "error" => trace.message_pattern,
        "failed_at" => DateTime.to_iso8601(trace.last_seen_at),
        "retry_count" => trace.count
      }
    end)
  end

  @impl true
  def fetch_llm_config do
    %{
      minimax_key: api_key(:minimax),
      nim_key: api_key(:nim),
      tokenrouter_key: api_key(:tokenrouter),
      openai_key: api_key(:openai)
    }
  end

  # ── Private ──

  defp safe_count_by_status(org_id) do
    Acs.Memory.Indexer.count_by_status(org_id)
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp safe_needing_review(org_id) do
    Acs.Memory.Indexer.count_memories_needing_review(org_id)
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  defp message_status_counts(counts) do
    %{
      "pending" => Map.get(counts, "proposed", 0),
      "classified" => 0,
      "extracted" => Map.get(counts, "approved", 0),
      "unclassified" => 0,
      "failed" => Map.get(counts, "parse_error", 0),
      "skipped" => Map.get(counts, "rejected", 0)
    }
  end

  defp worker_status(_org_id, counts) do
    alive = Enum.filter(@memory_workers, &Process.whereis(&1))

    %{
      stale?: alive == [],
      queue_stats: %{total: Map.get(counts, "proposed", 0)},
      alive_workers: Enum.map(alive, &inspect/1)
    }
  end

  defp dlq_summary(org_id) do
    traces = Acs.MCP.ErrorTrace.list_traces(org: org_id, limit: 100)
    hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    recent_hour =
      Enum.count(traces, fn t ->
        DateTime.compare(t.last_seen_at, hour_ago) == :gt
      end)

    %{total: length(traces), recent_hour: recent_hour}
  rescue
    _ -> %{total: 0, recent_hour: 0}
  catch
    _, _ -> %{total: 0, recent_hour: 0}
  end

  defp pipeline_states do
    Enum.map(@memory_workers, fn worker ->
      %{worker: inspect(worker), running: Process.whereis(worker) != nil}
    end)
  end

  defp api_key(provider) do
    case Application.get_env(:steward_acs, :"#{provider}_api_key") do
      "" -> nil
      nil -> nil
      key -> key
    end
  end
end
