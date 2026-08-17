defmodule Acs.IdleTrackerTest do
  use ExUnit.Case, async: false

  alias Acs.IdleTracker

  @table :acs_idle_tracker

  setup do
    Application.put_env(:steward_acs, :idle_after_ms, 50)
    Application.put_env(:steward_acs, :idle_sleep_interval_ms, 123_456)

    # Start each test from a known active state.
    IdleTracker.touch()
    Process.sleep(20)

    on_exit(fn ->
      Application.delete_env(:steward_acs, :idle_after_ms)
      Application.delete_env(:steward_acs, :idle_sleep_interval_ms)
      IdleTracker.touch()
    end)

    :ok
  end

  test "idle?/0 returns false (active) right after touch" do
    assert IdleTracker.idle?() == false
  end

  test "becomes idle once the idle threshold passes" do
    :ets.insert(@table, {:last_activity_at, System.system_time(:millisecond) - 1_000})
    assert IdleTracker.idle?() == true
  end

  test "touch/0 resets idle back to active" do
    :ets.insert(@table, {:last_activity_at, System.system_time(:millisecond) - 1_000})
    assert IdleTracker.idle?() == true

    IdleTracker.touch()
    Process.sleep(20)
    assert IdleTracker.idle?() == false
  end

  test "sleep_interval_ms/0 reads config" do
    assert IdleTracker.sleep_interval_ms() == 123_456
  end

  test "sleep_interval_ms/0 falls back to default when config unset" do
    Application.delete_env(:steward_acs, :idle_sleep_interval_ms)
    assert IdleTracker.sleep_interval_ms() == 600_000
  end
end
