defmodule Acs.MetaHarness.Scheduler do
  @moduledoc """
  Periodic scheduler for ACS Meta-Harness aggregation tasks.

  Runs on a configurable interval (default: 1 hour) to:
  - Run `Acs.MetaHarness.Analyzer` analysis
  - Generate report + plan via `Acs.MetaHarness.Generator.generate/0`

  The interval can be configured via the `META_HARNESS_INTERVAL_MS` environment variable.

  Manual triggers (`trigger_analysis/0`) are forwarded through the GenServer
  mailbox so they serialize with the scheduled tick — two overlapping
  `Generator.generate/0` calls would otherwise write duplicate report/plan
  files and ship duplicate Axiom rollups. The Generator also holds its own
  re-entrancy lock as a second line of defense.
  """

  use GenServer

  require Logger

  @default_interval :timer.hours(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, default_interval())

    Logger.info(
      "[Acs.MetaHarness.Scheduler] Starting with interval: #{div(interval, 60000)} minutes"
    )

    Acs.IdleTracker.subscribe()

    # Run once at boot so deploy/restart isn't blind for a full interval.
    Process.send_after(self(), :run_analysis, 0)
    schedule_next_run(interval)

    {:ok, %{interval: interval, last_run: nil}}
  end

  @impl true
  def handle_info(:activity, state) do
    Logger.debug("[Acs.MetaHarness.Scheduler] Activity detected, waking to fast cadence")
    schedule_next_run(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:run_analysis, state) do
    if Acs.IdleTracker.idle?() do
      Logger.debug("[Acs.MetaHarness.Scheduler] Idle, sleeping")
      schedule_next_run(Acs.IdleTracker.sleep_interval_ms())
      {:noreply, state}
    else
      {state, _result} = run_cycle(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:run_analysis, _from, state) do
    {state, result} = run_cycle(state)
    {:reply, result, state}
  end

  @impl true
  def handle_cast(:run_analysis, state) do
    handle_info(:run_analysis, state)
  end

  defp run_cycle(state) do
    _start_time = System.monotonic_time(:millisecond)

    Logger.info("[Acs.MetaHarness.Scheduler] Starting analysis cycle")

    result =
      try do
        {elapsed, result} = :timer.tc(fn -> run_analysis_cycle() end)

        Logger.info("[Acs.MetaHarness.Scheduler] Analysis completed in #{div(elapsed, 1000)}ms")

        result
      rescue
        e ->
          stacktrace = __STACKTRACE__
          Logger.error("[Acs.MetaHarness.Scheduler] Message handling crashed: #{inspect(e)}")
          Logger.error("[Acs.MetaHarness.Scheduler] Stacktrace: #{inspect(stacktrace)}")
          %{error: inspect(e), stacktrace: inspect(stacktrace)}
      end

    # Always reschedule next run even on error - GenServer must stay alive
    schedule_next_run(state.interval)

    {%{state | last_run: DateTime.utc_now()}, result}
  end

  defp schedule_next_run(interval) do
    Process.send_after(self(), :run_analysis, interval)
  end

  defp run_analysis_cycle do
    Logger.info("[Scheduler] Running Meta-Harness analysis...")

    try do
      # Wrap entire cycle in top-level rescue so Scheduler never crashes
      # The Generator.generate() function does all the work; we just need to
      # ensure it never crashes the GenServer
      result = Acs.MetaHarness.Generator.generate()
      Logger.info("[Scheduler] Generated report: #{inspect(result)}")
      result
    rescue
      e ->
        stacktrace = __STACKTRACE__
        Logger.error("[Scheduler] Analysis cycle crashed: #{inspect(e)}")
        Logger.error("[Scheduler] Stacktrace: #{inspect(stacktrace)}")
        %{error: inspect(e), stacktrace: inspect(stacktrace)}
    end
  end

  defp default_interval do
    case System.get_env("META_HARNESS_INTERVAL_MS") do
      nil ->
        @default_interval

      val when is_binary(val) ->
        case Integer.parse(val) do
          {ms, _} when ms > 0 -> ms
          _ -> @default_interval
        end

      _ ->
        @default_interval
    end
  end

  @doc """
  Manually trigger an analysis cycle.

  Forwards through the GenServer mailbox (call) so the run is serialized with
  the scheduled tick instead of running concurrently in the caller's process.
  Returns the run result; falls back to a synchronous run when the scheduler
  isn't running (e.g. during app boot / tests).
  """
  @spec trigger_analysis() :: map()
  def trigger_analysis do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :run_analysis, :infinity)
    else
      run_analysis_cycle()
    end
  end
end
