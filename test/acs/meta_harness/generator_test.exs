defmodule Acs.MetaHarness.GeneratorTest do
  @moduledoc """
  Tests for the ACS Meta-Harness Generator module.
  Tests through public API since formatting helpers are private.
  """
  use ExUnit.Case, async: false

  alias Acs.MetaHarness.Generator
  alias Acs.MetaHarness.RecentOps

  setup do
    RecentOps.setup()
    RecentOps.clear()
    on_exit(fn -> RecentOps.clear() end)
    :ok
  end

  describe "generate/0" do
    test "returns a map" do
      result = Generator.generate()

      assert is_map(result)
    end

    test "result has report, plan, and optionally error key" do
      result = Generator.generate()

      assert Map.has_key?(result, :report)
      assert Map.has_key?(result, :plan)
    end

    test "handles DB unavailability gracefully" do
      result = Generator.generate()

      # Either succeeds with file paths, or returns error map
      if result.report == "error" do
        assert Map.has_key?(result, :error)
        assert is_binary(result.error)
      else
        assert is_binary(result.report)
        assert is_binary(result.plan)
      end
    end

    test "clears stale lock left by a dead process" do
      table = :acs_meta_harness_generator_lock

      case :ets.whereis(table) do
        :undefined ->
          :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

        _ ->
          :ok
      end

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 5000
      :ets.insert(table, {:running, dead})

      result = Generator.generate()
      refute Map.get(result, :skipped) == true
    end

    test "analyzes ops recorded under a non-configured org (RecentOps discovery)" do
      RecentOps.record(%{
        tool_name: "ask",
        status: "success",
        latency_ms: 10,
        error_type: nil,
        error_message: nil,
        agent_id: "email|x",
        org: "anantha"
      })

      # Scheduler has no request context, so Acs.Org.current() is the configured
      # org; the generator must discover and analyze the org that has the data.
      result = Generator.generate()

      if result.report == "error" do
        flunk("generate/0 errored: #{inspect(result.error)}")
      else
        assert result.operations >= 1
      end
    end
  end
end
