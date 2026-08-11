defmodule Acs.Observability.VmMetricsTest do
  use ExUnit.Case, async: false

  alias Acs.Observability.VmMetrics

  test "sample emits memory and scheduler fields" do
    {first, prev} = VmMetrics.sample(nil)
    assert first["message"] == "vm.metrics"
    assert first["event"] == "vm.metrics"
    assert is_integer(first["memory_total_bytes"]) and first["memory_total_bytes"] > 0
    assert is_integer(first["process_count"]) and first["process_count"] > 0
    assert first["scheduler_utilization"] == 0.0
    assert is_map(prev)
    assert Map.has_key?(prev, :schedulers)

    # Host fields are best-effort Linux; assert shape when present.
    if Map.has_key?(first, "host_memory_total_bytes") do
      assert first["host_memory_total_bytes"] > 0
    end

    Process.sleep(10)
    {second, _} = VmMetrics.sample(prev)
    assert second["scheduler_utilization"] >= 0.0
    assert second["scheduler_utilization"] <= 1.0

    if Map.has_key?(second, "cgroup_cpu_utilization") do
      assert second["cgroup_cpu_utilization"] >= 0.0
      assert second["cgroup_cpu_utilization"] <= 1.0
    end
  end

  test "sample accepts legacy scheduler-list prev" do
    {_, schedulers} = VmMetrics.sample(nil)
    {event, _} = VmMetrics.sample(schedulers.schedulers)
    assert event["message"] == "vm.metrics"
  end

  describe "jump detection" do
    test "delta jump when scheduler utilization spikes past threshold" do
      prev = %{"scheduler_utilization" => 0.1}
      event = %{"_time" => "2026-08-07T00:00:00Z", "scheduler_utilization" => 0.9}

      [jump] =
        VmMetrics.jump_events(prev, event, [
          %{metric: "scheduler_utilization", type: :delta, threshold: 0.5}
        ])

      assert jump["message"] == "vm.jump"
      assert jump["metric"] == "scheduler_utilization"
      assert jump["jump_type"] == :delta
      assert jump["threshold"] == 0.5
      assert jump["value"] == 0.9
      assert jump["prev_value"] == 0.1
      assert jump["delta"] == 0.8
      assert jump["_time"] == event["_time"]
    end

    test "delta jump when cgroup cpu utilization crosses threshold" do
      prev = %{"cgroup_cpu_utilization" => 0.2}
      event = %{"cgroup_cpu_utilization" => 1.0}

      assert [%{"metric" => "cgroup_cpu_utilization"}] =
               VmMetrics.jump_events(prev, event, [
                 %{metric: "cgroup_cpu_utilization", type: :delta, threshold: 0.8}
               ])
    end

    test "pct jump when memory grows more than threshold" do
      prev = %{"memory_total_bytes" => 100}
      event = %{"memory_total_bytes" => 150}

      [jump] =
        VmMetrics.jump_events(prev, event, [
          %{metric: "memory_total_bytes", type: :pct, threshold: 20.0}
        ])

      assert jump["jump_type"] == :pct
      assert jump["pct_change"] == 50.0
      assert jump["delta"] == 50
    end

    test "no jump below threshold" do
      prev = %{"scheduler_utilization" => 0.1}
      event = %{"scheduler_utilization" => 0.3}

      assert [] =
               VmMetrics.jump_events(prev, event, [
                 %{metric: "scheduler_utilization", type: :delta, threshold: 0.5}
               ])
    end

    test "no jump on first sample (no previous event)" do
      event = %{"scheduler_utilization" => 0.9}

      assert [] =
               VmMetrics.jump_events(nil, event, [
                 %{metric: "scheduler_utilization", type: :delta, threshold: 0.5}
               ])
    end

    test "poller enqueues jump events alongside metrics" do
      test_pid = self()
      enqueue = fn event -> send(test_pid, {:out, event}) end

      {:ok, _pid} =
        start_supervised(
          {VmMetrics,
           name: :"vm_metrics_jump_test_#{System.unique_integer([:positive])}",
           interval_ms: 20,
           exporter: enqueue,
           jump_config: [%{metric: "process_count", type: :pct, threshold: 0.01}]}
        )

      assert_receive {:out, event}, 500
      assert event["message"] == "vm.metrics"
    end
  end

  test "poller enqueues metrics via exporter callback" do
    test_pid = self()
    enqueue = fn event -> send(test_pid, {:vm_metric, event}) end

    {:ok, pid} =
      start_supervised(
        {VmMetrics,
         name: :"vm_metrics_test_#{System.unique_integer([:positive])}",
         interval_ms: 20,
         exporter: enqueue}
      )

    assert_receive {:vm_metric, event}, 500
    assert event["message"] == "vm.metrics"
    assert is_integer(event["memory_total_bytes"])
    assert Process.alive?(pid)
  end

  test "poller survives the first tick (prev has no :event key yet)" do
    test_pid = self()
    enqueue = fn event -> send(test_pid, {:vm_metric, event}) end

    {:ok, pid} =
      start_supervised(
        {VmMetrics,
         name: :"vm_metrics_survive_test_#{System.unique_integer([:positive])}",
         interval_ms: 20,
         exporter: enqueue}
      )

    # The first tick after boot must not crash: init/1 builds prev
    # without an :event key, so handle_info must read it defensively.
    assert_receive {:vm_metric, _event}, 500
    assert_receive {:vm_metric, _event}, 500
    assert Process.alive?(pid)
  end
end
