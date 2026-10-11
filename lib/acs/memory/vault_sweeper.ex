defmodule Acs.Memory.VaultSweeper do
  @moduledoc """
  Periodically scans all org vault directories and syncs memory files to the index.

  Belt-and-suspenders alongside FileWatcher — catches missed NFS/Syncthing events.
  Runs every 30 seconds when multi-tenant mode is enabled.
  """
  use GenServer
  require Logger

  @interval_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger an immediate vault sweep."
  def sweep_now do
    GenServer.cast(__MODULE__, :sweep)
  end

  @impl true
  def init(_opts) do
    if sweep_enabled?() do
      Logger.info("[Memory.VaultSweeper] Starting vault sweeper (interval=#{@interval_ms}ms)")
      schedule_sweep()
    else
      Logger.info("[Memory.VaultSweeper] Disabled (single-tenant mode)")
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Listing orgs is a DB query; nothing to sync while nobody is active.
    if Acs.IdleTracker.idle?() do
      schedule_sweep(Acs.IdleTracker.sleep_interval_ms())
    else
      do_sweep()
      schedule_sweep()
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:sweep, state) do
    do_sweep()
    {:noreply, state}
  end

  defp sweep_enabled? do
    Acs.Org.multi_tenant?() and
      Application.get_env(:steward_acs, :start_background_workers, true)
  end

  defp schedule_sweep(interval \\ @interval_ms) do
    if sweep_enabled?(), do: Process.send_after(self(), :sweep, interval)
  end

  defp do_sweep do
    orgs = Acs.Orgs.list_all()

    Enum.each(orgs, fn org ->
      {:ok, count, quarantined} = Acs.Memory.Indexer.sync_org(org.slug)

      if count > 0 or quarantined != [] do
        Logger.debug(
          "[Memory.VaultSweeper] org=#{org.slug} synced=#{count} quarantined=#{length(quarantined)}"
        )
      end
    end)
  rescue
    e ->
      Logger.error("[Memory.VaultSweeper] sweep failed: #{inspect(e)}")
  end
end
