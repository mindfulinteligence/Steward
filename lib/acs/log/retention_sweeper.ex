defmodule Acs.Log.RetentionSweeper do
  @moduledoc """
  Periodically cleans up old log entries from the database.

  Runs every hour by default. Regular (non-error) logs deleted after 24 hours.
  Error logs deleted after 30 days.

  ## Configuration

  Configure via application env:

      config :steward_acs, :log_retention_hours, 24
      config :steward_acs, :error_log_retention_days, 30
  """

  use GenServer
  require Logger

  @default_interval :timer.hours(1)

  @doc """
  Starts the RetentionSweeper GenServer.

  ## Options

    * `:interval` - Tick interval in milliseconds (default: `:timer.hours(1)`)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    Acs.IdleTracker.subscribe()
    schedule(interval)
    {:ok, %{interval: interval, sweeping: false}}
  end

  @impl true
  def handle_info(:tick, %{sweeping: true} = state) do
    Logger.debug("[RetentionSweeper] Previous sweep still running, skipping")
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:activity, state) do
    Logger.debug("[RetentionSweeper] Activity detected, waking to fast cadence")
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    if Acs.IdleTracker.idle?() do
      Logger.debug("[RetentionSweeper] Idle, sleeping")
      schedule(Acs.IdleTracker.sleep_interval_ms())
      {:noreply, state}
    else
      Logger.debug("[RetentionSweeper] Running log retention cleanup")

      state = %{state | sweeping: true}

      older_than = hours_ago(config(:log_retention_hours, 24))
      error_older_than = days_ago(config(:error_log_retention_days, 30))

      {normal_deleted, error_deleted} =
        Acs.Log.LogRepo.delete_old(
          older_than: older_than,
          error_older_than: error_older_than
        )

      if normal_deleted > 0 or error_deleted > 0 do
        Logger.info(
          "[RetentionSweeper] Cleaned #{normal_deleted} normal + #{error_deleted} error log entries"
        )
      end

      schedule(state.interval)
      {:noreply, %{state | sweeping: false}}
    end
  end

  defp schedule(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp config(key, default) do
    Application.get_env(:steward_acs, key, default)
  end

  defp hours_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 3600, :second)
  defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 86_400, :second)
end
