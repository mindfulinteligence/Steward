defmodule Acs.IdleTracker do
  @moduledoc """
  Tracks the last user-activity timestamp so background DB-touching workers
  can sleep during idle periods (letting the Neon compute autosuspend) and
  wake instantly when a user becomes active again.

  Only user-facing activity counts: MCP tool calls, LiveView mounts. Health
  checks and background-process logging must NOT call `touch/0` or the DB
  would never get a quiet window.

  Workers consult `idle?/0` on each tick; when idle they skip their DB work
  and reschedule on `sleep_interval_ms/0` instead of their normal cadence.
  They subscribe to `subscribe/0` so an idle→active transition broadcasts
  `:activity` and reschedules them at their fast cadence immediately.

  Config:

      config :steward_acs, :idle_after_ms, 900_000          # IDLE_AFTER_MS
      config :steward_acs, :idle_sleep_interval_ms, 600_000 # IDLE_SLEEP_MS
  """

  use GenServer
  require Logger

  @table_name :acs_idle_tracker
  @topic "acs:idle_tracker"

  @default_idle_after_ms 900_000
  @default_sleep_interval_ms 600_000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Records user activity. Safe to call from any process; no-ops if the tracker
  is not running (e.g. before the app finishes booting, or in tests).
  """
  def touch do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :touch)
    end

    :ok
  end

  @doc """
  Returns `true` when no user activity for longer than the idle threshold.
  Safe to call when the tracker is not running — returns `false` (active).
  """
  def idle? do
    if :ets.whereis(@table_name) == :undefined do
      false
    else
      now = System.system_time(:millisecond)

      case :ets.lookup(@table_name, :last_activity_at) do
        [{:last_activity_at, last}] -> now - last > idle_after_ms()
        [] -> false
      end
    end
  end

  @doc """
  The interval workers should use while idle (default 10 minutes).
  """
  def sleep_interval_ms do
    Application.get_env(:steward_acs, :idle_sleep_interval_ms, @default_sleep_interval_ms)
  end

  @doc """
  Subscribes the caller to idle→active transition broadcasts (`:activity`).
  """
  def subscribe do
    Phoenix.PubSub.subscribe(AcsWeb.PubSub, @topic)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Default last activity to boot time so the first scheduled run happens
    # and deploy-time analysis still executes.
    :ets.insert(@table_name, {:last_activity_at, System.system_time(:millisecond)})
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:touch, state) do
    now = System.system_time(:millisecond)
    was_idle = idle?()

    :ets.insert(@table_name, {:last_activity_at, now})

    if was_idle do
      Logger.debug("[Acs.IdleTracker] Activity resumed, waking workers")
      Phoenix.PubSub.broadcast(AcsWeb.PubSub, @topic, :activity)
    end

    {:noreply, state}
  end

  defp idle_after_ms do
    Application.get_env(:steward_acs, :idle_after_ms, @default_idle_after_ms)
  end
end
