defmodule Acs.MetaHarness.RecentOps do
  @moduledoc """
  In-memory ring of recent tool ops for Meta-Harness Analyzer fallback.

  Prod ships `agent.tool` to Axiom with an ingest-only token (cannot query back).
  When `acs_tool_operations` is empty/broken, Analyzer still needs a local source.
  Every `OperationLogger.log_async/8` also records here (24h TTL).
  """

  @table :acs_meta_recent_ops
  # ponytail: O(n) prune on record; fine under agent-tool volume. Upgrade: timed sweep GenServer.
  @ttl_ms :timer.hours(24)

  @doc "Create the ETS table (idempotent)."
  def setup do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :duplicate_bag,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        @table
    end

    :ok
  end

  defmodule Table do
    @moduledoc """
    Dedicated owner process for the ETS table.

    An ETS table dies with the process that created it. `setup/0` is called
    lazily from whichever request/logger process runs first, so the table could
    be owned by a short-lived pid and vanish (erasing the in-memory Analyzer
    fallback) when that process exits. This supervised GenServer owns the table
    and recreates it if it ever crashes.
    """
    use GenServer

    @doc false
    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(_opts) do
      Acs.MetaHarness.RecentOps.setup()
      {:ok, %{}}
    end
  end

  @doc "Delete all recorded ops (tests)."
  def clear do
    setup()
    :ets.delete_all_objects(@table)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Record one tool operation (fire-and-forget from OperationLogger)."
  def record(entry) when is_map(entry) do
    setup()
    now = System.system_time(:millisecond)
    :ets.insert(@table, {now, entry})
    prune(now)
    :ok
  rescue
    _ -> :ok
  end

  def record(_), do: :ok

  @doc """
  Distinct org slugs present in the table. Lets the generator discover which
  orgs actually have recorded ops (e.g. a request-scoped auth org such as
  "anantha" that differs from the configured `ACS_ORG_NAME`).
  """
  def orgs do
    setup()

    :ets.tab2list(@table)
    |> Enum.map(fn {_, e} -> Map.get(e, :org, "default") end)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  @doc """
  Aggregate ops in `[start_ms, end_ms]` into Analyzer-shaped maps.

  Returns `%{tool_reliability: %{}, latency_analysis: %{}, error_clusters: [],
  intake_friction: [], agent_behavior: %{}}`.
  """
  def analyze(start_ms, end_ms, opts \\ []) when is_integer(start_ms) and is_integer(end_ms) do
    setup()
    min_sample = Keyword.get(opts, :min_sample_size, 1)
    min_cluster = Keyword.get(opts, :min_cluster_size, 2)

    entries =
      :ets.tab2list(@table)
      |> Enum.filter(fn {ts, _} -> ts >= start_ms and ts <= end_ms end)
      |> Enum.map(fn {_, e} -> e end)
      |> filter_by_org(Keyword.get(opts, :org))

    %{
      tool_reliability: tool_reliability(entries, min_sample),
      latency_analysis: latency_analysis(entries, min_sample),
      error_clusters: error_clusters(entries, min_cluster),
      intake_friction: intake_friction(entries, min_cluster),
      agent_behavior: agent_behavior(entries)
    }
  rescue
    _ ->
      %{
        tool_reliability: %{},
        latency_analysis: %{},
        error_clusters: [],
        intake_friction: [],
        agent_behavior: %{}
      }
  end

  defp prune(now) do
    cutoff = now - @ttl_ms
    :ets.select_delete(@table, [{{:"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp filter_by_org(entries, nil), do: entries

  defp filter_by_org(entries, org) when is_binary(org) do
    Enum.filter(entries, fn e -> Map.get(e, :org, "default") == org end)
  end

  defp tool_reliability(entries, min_sample) do
    entries
    |> Enum.reject(&(Map.get(&1, :status) == "discovery"))
    |> Enum.group_by(& &1.tool_name)
    |> Enum.reduce(%{}, fn {name, rows}, acc ->
      if length(rows) < min_sample do
        acc
      else
        success = Enum.count(rows, &(&1.status == "success"))
        failure = Enum.count(rows, &(&1.status == "failure"))
        error = Enum.count(rows, &(&1.status == "error"))
        total = length(rows)
        exec = success + failure + error
        lats = rows |> Enum.map(& &1.latency_ms) |> Enum.reject(&is_nil/1)

        Map.put(acc, name, %{
          total_calls: total,
          success_count: success,
          failure_count: failure,
          error_count: error,
          discovery_count: 0,
          success_rate: if(exec > 0, do: success / exec, else: 0.0),
          avg_latency: avg(lats),
          max_latency: Enum.max(lats ++ [0])
        })
      end
    end)
  end

  defp latency_analysis(entries, min_sample) do
    entries
    |> Enum.reject(&(Map.get(&1, :status) == "discovery"))
    |> Enum.group_by(& &1.tool_name)
    |> Enum.reduce(%{}, fn {name, rows}, acc ->
      lats =
        rows
        |> Enum.map(& &1.latency_ms)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()

      if length(lats) < min_sample do
        acc
      else
        Map.put(acc, name, %{
          avg_latency: avg(lats),
          p50_latency: percentile(lats, 0.5),
          p95_latency: percentile(lats, 0.95)
        })
      end
    end)
  end

  defp error_clusters(entries, min_cluster) do
    entries
    |> Enum.filter(fn e ->
      type = Map.get(e, :error_type)
      e.status in ["failure", "error"] and is_binary(type)
    end)
    |> Enum.group_by(&{&1.tool_name, &1.error_type})
    |> Enum.reduce([], fn {{tool, type}, rows}, acc ->
      if length(rows) < min_cluster do
        acc
      else
        sample = List.first(rows)

        [
          %{
            tool_name: tool,
            error_type: type,
            sample_message: sample.error_message && String.slice(sample.error_message, 0, 100),
            occurrence_count: length(rows),
            agents:
              rows
              |> Enum.map(& &1.agent_id)
              |> Enum.reject(&is_nil/1)
              |> Enum.uniq()
              |> Enum.join(",")
          }
          | acc
        ]
      end
    end)
    |> Enum.sort_by(& &1.occurrence_count, :desc)
    |> Enum.take(20)
  end

  defp intake_friction(entries, min_cluster) do
    entries
    |> Enum.filter(fn e ->
      type = Map.get(e, :error_type)
      is_binary(type) and String.starts_with?(type, "intake_")
    end)
    |> Enum.group_by(&{&1.tool_name, &1.error_type})
    |> Enum.reduce([], fn {{tool, type}, rows}, acc ->
      if length(rows) < min_cluster do
        acc
      else
        sample = List.first(rows)

        [
          %{
            tool_name: tool,
            error_type: type,
            sample_message: sample.error_message && String.slice(sample.error_message, 0, 100),
            occurrence_count: length(rows),
            prompt_hint: "Review org intake prompt overrides"
          }
          | acc
        ]
      end
    end)
    |> Enum.sort_by(& &1.occurrence_count, :desc)
    |> Enum.take(30)
  end

  defp agent_behavior(entries) do
    entries
    |> Enum.reject(&(is_nil(&1.agent_id) or &1.agent_id == ""))
    |> Enum.group_by(& &1.agent_id)
    |> Enum.into(%{}, fn {agent_id, rows} ->
      success = Enum.count(rows, &(&1.status == "success"))
      failure = Enum.count(rows, &(&1.status == "failure"))
      error = Enum.count(rows, &(&1.status == "error"))
      discovery = Enum.count(rows, &(&1.status == "discovery"))
      exec = success + failure + error
      lats = rows |> Enum.map(& &1.latency_ms) |> Enum.reject(&is_nil/1)

      {agent_id,
       %{
         total_operations: length(rows),
         success_count: success,
         failure_count: failure,
         discovery_count: discovery,
         unique_tools_used: rows |> Enum.map(& &1.tool_name) |> Enum.uniq() |> length(),
         success_rate: if(exec > 0, do: success / exec, else: 0.0),
         avg_latency: avg(lats),
         first_seen: nil,
         last_seen: nil
       }}
    end)
  end

  defp avg([]), do: 0.0
  defp avg(xs), do: Enum.sum(xs) / length(xs)

  defp percentile([], _), do: 0.0

  defp percentile(sorted, p) do
    n = length(sorted)
    index = (p * (n - 1)) |> Float.ceil() |> max(0) |> min(n - 1) |> round()
    Enum.at(sorted, index)
  end
end
