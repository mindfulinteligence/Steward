defmodule Acs.Files.Reaper do
  @moduledoc """
  Background GenServer that deletes expired uploaded files.

  A file is expired once `expires_at` (upload time + 24h) has passed.
  Each sweep deletes the stored bytes from disk and then the database row.
  Expired-but-unreaped files remain invisible to the `manage_files` tool,
  which checks `expires_at` directly.
  """

  use GenServer
  import Ecto.Query
  require Logger

  alias Acs.Repo

  @default_sweep_interval :timer.hours(1)

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Sweep interval in milliseconds, overridable via
  `config :steward_acs, :files_reaper_interval, ms`.
  """
  def sweep_interval do
    Application.get_env(:steward_acs, :files_reaper_interval, @default_sweep_interval)
  end

  @impl true
  def init(_opts) do
    interval = sweep_interval()
    Logger.info("[Acs.Files.Reaper] Starting with interval: #{interval}ms")
    schedule_sweep(interval)
    {:ok, %{sweep_in_progress: false}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      reap_expired()
    after
      schedule_sweep(sweep_interval())
    end

    {:noreply, state}
  end

  @doc """
  Deletes every expired file (bytes from disk, then the row).
  Returns `{:ok, count}`. Also callable directly, e.g. from tests.
  """
  def reap_expired do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    expired =
      Repo.all(
        from f in Acs.Acs.File,
          where: f.expires_at <= ^now
      )

    count =
      Enum.count(expired, fn file ->
        _ = File.rm(file.storage_path)

        case Repo.delete(file) do
          {:ok, _} -> true
          {:error, _} -> false
        end
      end)

    if count > 0 do
      Logger.info("[Acs.Files.Reaper] Reaped #{count} expired file(s)")
    end

    {:ok, count}
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end
end
