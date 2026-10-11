defmodule Acs.IdleWorkersNoDbTest do
  @moduledoc """
  Neon autosuspends when the database sits idle. These workers must not run
  queries when `Acs.IdleTracker` reports idle, or they wake the compute.
  """
  use ExUnit.Case, async: false

  setup do
    # Real connection so a stray query actually runs (and emits telemetry)
    # instead of failing on ownership and being rescued inside the worker.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Acs.Repo)
    prev = Application.get_env(:steward_acs, :idle_after_ms)
    # now - last_activity > -1 is always true → permanently idle
    Application.put_env(:steward_acs, :idle_after_ms, -1)

    handler = "idle-no-query-#{System.unique_integer()}"
    me = self()

    :telemetry.attach(
      handler,
      [:steward_acs, :repo, :query],
      fn _, _, meta, _ ->
        send(me, {:repo_query, meta[:source]})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)

      if prev,
        do: Application.put_env(:steward_acs, :idle_after_ms, prev),
        else: Application.delete_env(:steward_acs, :idle_after_ms)
    end)

    assert Acs.IdleTracker.idle?()
    :ok
  end

  test "control: the telemetry hook sees a real query" do
    Acs.Repo.query!("select 1")
    assert_received {:repo_query, _}
  end

  test "Reaper skips its sweep while idle" do
    assert {:noreply, %{}} = Acs.Files.Reaper.handle_info(:sweep, %{sweep_in_progress: false})
    refute_received {:repo_query, _}
  end

  test "VaultSweeper skips its sweep while idle" do
    prev = Application.get_env(:steward_acs, :start_background_workers)
    Application.put_env(:steward_acs, :start_background_workers, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:steward_acs, :start_background_workers),
        else: Application.put_env(:steward_acs, :start_background_workers, prev)
    end)

    assert {:noreply, _} = Acs.Memory.VaultSweeper.handle_info(:sweep, %{})
    refute_received {:repo_query, _}
  end

  test "LogAnalyzer skips analysis while idle" do
    state = %{last_analysis: nil}
    assert {:noreply, ^state} = Acs.LogAnalyzer.handle_info(:run_analysis, state)
    refute_received {:repo_query, _}
  end

  test "Cache defers stale-agent DB deletes while idle" do
    stale = %{org: "t", agent_id: "ghost", updated_at: ~U[2020-01-01 00:00:00Z]}
    :ets.insert(:acs_agent_status, {{"t", "ghost"}, stale})

    on_exit(fn -> :ets.delete(:acs_agent_status, {"t", "ghost"}) end)

    assert {:noreply, %{pending_db_deletes: [{"t", "ghost"}]}} =
             Acs.Acs.Cache.handle_info(:sweep_stale_agents, %{})

    refute_received {:repo_query, _}
  end
end
