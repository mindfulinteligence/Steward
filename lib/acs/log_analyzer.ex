defmodule Acs.LogAnalyzer do
  @moduledoc """
  Periodic log analyzer that extracts errors from the LogStore, groups similar
  errors by component and message pattern, and generates actionable insights.

  Runs every 60 seconds and stores analysis results in state.
  """

  use GenServer
  require Logger
  alias Acs.MCP.ErrorTrace

  # ── Client API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── Callbacks ──

  @impl true
  def init(_opts) do
    Logger.info("[LogAnalyzer] Starting periodic error analysis (interval: 60s)")

    Acs.IdleTracker.subscribe()
    schedule_analysis()

    {:ok,
     %{
       last_analysis: nil,
       error_groups: [],
       total_errors: 0,
       top_components: [],
       recent_alerts: [],
       summary: "No analysis yet"
     }}
  end

  @impl true
  def handle_info(:run_analysis, state) do
    # Analysis can create tasks (DB writes); defer while idle so a suspended
    # compute isn't woken. :activity re-arms the normal cadence.
    if Acs.IdleTracker.idle?() do
      Acs.IdleTracker.schedule_tick(:run_analysis, Acs.IdleTracker.sleep_interval_ms())
      {:noreply, state}
    else
      new_state = perform_analysis(state)
      schedule_analysis()
      {:noreply, new_state}
    end
  end

  def handle_info(:activity, state) do
    schedule_analysis()
    {:noreply, state}
  end

  # ── Analysis ──

  defp schedule_analysis do
    Acs.IdleTracker.schedule_tick(:run_analysis, 60_000)
  end

  defp perform_analysis(state) do
    try do
      recent_errors = fetch_recent_errors()

      # Guard clause: if no errors, return state as-is
      if recent_errors == [] do
        %{
          state
          | last_analysis: DateTime.utc_now(),
            error_groups: [],
            total_errors: 0,
            top_components: [],
            recent_alerts: [],
            summary: %{
              analyzed_at: DateTime.utc_now(),
              total_errors: 0,
              error_components: [],
              top_error_patterns: [],
              alerts: []
            }
        }
      else
        # Group errors by component
        by_component =
          recent_errors
          |> Enum.group_by(fn e -> Map.get(e, :cmp, "unknown") end)
          |> Enum.map(fn {comp, logs} ->
            %{component: comp, count: length(logs), samples: Enum.take(logs, 3)}
          end)
          |> Enum.sort_by(fn g -> g.count end, :desc)

        # Group errors by message pattern (first 100 chars of message as rough pattern)
        by_pattern =
          recent_errors
          |> Enum.group_by(fn e ->
            msg = Map.get(e, :msg, "")
            String.slice(msg, 0, 100)
          end)
          |> Enum.map(fn {pattern, logs} ->
            %{
              pattern: pattern,
              count: length(logs),
              component: Map.get(hd(logs), :cmp, "unknown"),
              service: Map.get(hd(logs), :svc, "unknown"),
              first_seen: Enum.min_by(logs, &parse_ts(Map.get(&1, :ts))),
              last_seen: Enum.max_by(logs, &parse_ts(Map.get(&1, :ts)))
            }
          end)
          |> Enum.sort_by(fn g -> g.count end, :desc)
          |> Enum.take(20)

        # ── Error Trace Integration ──
        # Track ignored components that should not auto-create tasks
        ignored_components = ["Acs::Acs::Cache", "Acs::MCP::LogStore"]

        Enum.each(by_pattern, fn g ->
          metadata = %{}

          case ErrorTrace.store_or_update_trace(
                 g.service,
                 g.component,
                 g.pattern,
                 g.pattern,
                 metadata
               ) do
            {:ok, action, trace} when is_map(trace) ->
              if action in [:created, :updated] do
                Logger.info(
                  "[LogAnalyzer] ErrorTrace #{action} #{g.service}/#{g.component} count=#{trace.count}",
                  action: "error_trace",
                  status: Atom.to_string(action),
                  org: Map.get(trace, :org),
                  service: g.service,
                  component: g.component,
                  count: trace.count
                )
              end

              # Only create task if:
              # 1. Pattern count >= 8 (severe)
              # 2. Trace status is :new (not already tasked)
              # 3. Component is not in the ignored list
              if trace.count >= 8 and trace.status == :new and
                   g.component not in ignored_components do
                create_task_for_trace(g, trace)
              end

            {:error, :no_table} ->
              Logger.warning(
                "[LogAnalyzer] ErrorTrace table not available - error traces will not be stored for #{g.service}/#{g.component}"
              )

            {:error, :nil_message_pattern} ->
              Logger.debug(
                "[LogAnalyzer] Nil message pattern for #{g.service}/#{g.component} - pattern was nil"
              )

            other ->
              Logger.warning(
                "[LogAnalyzer] Unexpected return from ErrorTrace.store_or_update_trace for #{g.service}/#{g.component}: #{inspect(other)}"
              )
          end
        end)

        # Generate simple alert for heavily repeated errors
        alerts =
          by_pattern
          |> Enum.filter(fn g -> g.count >= 5 end)
          |> Enum.map(fn g ->
            "⚠️ [#{g.service}/#{g.component}] '#{String.slice(g.pattern, 0, 80)}...' repeated #{g.count} times"
          end)

        # Build summary
        summary = %{
          analyzed_at: DateTime.utc_now(),
          total_errors: length(recent_errors),
          error_components: Enum.map(by_component, &%{name: &1.component, count: &1.count}),
          top_error_patterns: Enum.take(by_pattern, 10),
          alerts: alerts
        }

        %{
          state
          | last_analysis: DateTime.utc_now(),
            error_groups: by_pattern,
            total_errors: length(recent_errors),
            top_components: by_component,
            recent_alerts: alerts,
            summary: summary
        }
      end
    rescue
      e ->
        Logger.error("[LogAnalyzer] Crash during analysis: #{inspect(e)}",
          error: Exception.format_stacktrace(__STACKTRACE__)
        )

        state
    end
  end

  defp fetch_recent_errors do
    # Get errors from the last 5 minutes using LogStore
    # Returns formatted entries with keys: :id, :ts, :lvl, :svc, :cmp, :msg
    result = Acs.MCP.LogStore.get_logs([level: :error, limit: 500], "list")

    Map.get(result, :logs, [])
  end

  # Parse ISO8601 timestamp string back to DateTime for comparison
  defp parse_ts(nil), do: DateTime.from_unix!(0)
  defp parse_ts(%DateTime{} = dt), do: dt
  defp parse_ts(ts) when is_integer(ts), do: DateTime.from_unix!(ts)

  defp parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.from_unix!(0)
    end
  end

  defp parse_ts(_), do: DateTime.from_unix!(0)

  defp format_datetime(nil), do: "never"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_datetime(%{} = map) do
    ts = Map.get(map, :ts) || Map.get(map, :timestamp)

    case parse_ts(ts) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      _ -> "never"
    end
  end

  defp format_datetime(_), do: "unknown"

  defp create_task_for_trace(g, trace) do
    task_title =
      "Auto: #{g.service}/#{g.component} error repeated #{g.count}x"

    task_description =
      "Error pattern: #{String.slice(g.pattern, 0, 200)}\n\n" <>
        "From LogAnalyzer analysis at #{DateTime.utc_now() |> DateTime.to_iso8601()}\n" <>
        "Total occurrences: #{g.count}\n" <>
        "First seen: #{format_datetime(g.first_seen)}\n" <>
        "Last seen: #{format_datetime(g.last_seen)}"

    case Acs.create_task(
           %{
             "title" => task_title,
             "description" => task_description,
             "file_paths" => []
           },
           "log_analyzer"
         ) do
      {:ok, task} ->
        Logger.info(
          "[LogAnalyzer] Created auto-task #{task.id} for #{g.service}/#{g.component} (#{g.count}x)",
          action: "error_trace_task",
          status: "created",
          task_id: task.id,
          service: g.service,
          component: g.component,
          count: g.count
        )

        ErrorTrace.mark_tasked(trace.id, task.id)

      {:warn, task, _similar} ->
        Logger.info(
          "[LogAnalyzer] Created auto-task #{task.id} (with similar warnings) for #{g.service}/#{g.component}",
          action: "error_trace_task",
          status: "created",
          task_id: task.id,
          service: g.service,
          component: g.component,
          count: g.count
        )

        ErrorTrace.mark_tasked(trace.id, task.id)

      {:error, reason} ->
        Logger.warning(
          "[LogAnalyzer] Failed to create auto-task for #{g.service}/#{g.component}: #{inspect(reason)}",
          action: "error_trace_task",
          status: "error",
          service: g.service,
          component: g.component,
          error_type: String.slice(inspect(reason), 0, 200)
        )

        ErrorTrace.mark_failed(trace.id, inspect(reason))
    end
  end
end
