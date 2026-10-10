defmodule Acs.IdleTrackerScheduleTickTest do
  use ExUnit.Case, async: true

  test "schedule_tick keeps a single pending tick per message" do
    for _ <- 1..5, do: Acs.IdleTracker.schedule_tick(:tick_test, 20)

    assert_receive :tick_test, 200
    refute_receive :tick_test, 100
  end

  test "schedule_tick re-arms after the tick fired" do
    Acs.IdleTracker.schedule_tick(:tick_test, 10)
    assert_receive :tick_test, 200
    Acs.IdleTracker.schedule_tick(:tick_test, 10)
    assert_receive :tick_test, 200
  end
end
