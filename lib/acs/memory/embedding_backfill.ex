defmodule Acs.Memory.EmbeddingBackfill do
  @moduledoc """
  Retries embedding generation after a failed embed (Ollama restarting,
  container DNS not resolving yet, …).

  The boot-time backfill in `Acs.Application` only waits ~10s for Ollama and
  never runs again, so anything saved while Ollama was unreachable stayed
  un-embedded (keyword-only search) until the next restart. `Embedding`
  reports failures here via `note_failure/0`; this worker then re-runs the
  memory, skill and spec `ensure_embeddings/0` passes — which only embed what
  is missing — once Ollama answers and the app is not idle (so it never wakes
  the Neon compute on its own).
  """

  use GenServer
  require Logger

  @retry_ms :timer.minutes(5)

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Records that an embed call failed; schedules a backfill. No-op if not running."
  def note_failure do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :note_failure)
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{pending: false}}

  @impl true
  def handle_cast(:note_failure, %{pending: true} = state), do: {:noreply, state}

  def handle_cast(:note_failure, state) do
    Acs.IdleTracker.schedule_tick(:backfill, retry_ms())
    {:noreply, %{state | pending: true}}
  end

  @impl true
  def handle_info(:backfill, state) do
    cond do
      Acs.IdleTracker.idle?() ->
        Acs.IdleTracker.schedule_tick(:backfill, Acs.IdleTracker.sleep_interval_ms())
        {:noreply, state}

      not Acs.Memory.Embedding.available?() ->
        Acs.IdleTracker.schedule_tick(:backfill, retry_ms())
        {:noreply, state}

      run_passes() == :ok ->
        Logger.info("[Acs.Memory.EmbeddingBackfill] Backfill complete")
        {:noreply, %{state | pending: false}}

      true ->
        Acs.IdleTracker.schedule_tick(:backfill, retry_ms())
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp run_passes do
    results =
      for fun <- [
            &Acs.Memory.Embedding.ensure_embeddings/0,
            &Acs.Skills.VectorSearch.ensure_embeddings/0,
            &Acs.Specs.VectorSearch.ensure_embeddings/0
          ] do
        safe(fun)
      end

    if Enum.all?(results, &(&1 == :ok)), do: :ok, else: :retry
  end

  defp safe(fun) do
    case fun.() do
      {:ok, %{failed: 0}} -> :ok
      _ -> :retry
    end
  rescue
    e ->
      Logger.warning("[Acs.Memory.EmbeddingBackfill] Pass failed: #{Exception.message(e)}")
      :retry
  end

  defp retry_ms, do: Application.get_env(:steward_acs, :embedding_backfill_retry_ms, @retry_ms)
end
