defmodule Acs.Memory.EmbeddingBackfillTest do
  use ExUnit.Case, async: false

  alias Acs.Memory.EmbeddingBackfill

  test "note_failure is a no-op when the worker is not running" do
    if pid = Process.whereis(EmbeddingBackfill), do: GenServer.stop(pid)
    assert :ok = EmbeddingBackfill.note_failure()
  end

  test "note_failure marks pending once and arms a single retry" do
    {:ok, pid} = GenServer.start(EmbeddingBackfill, [], name: EmbeddingBackfill)
    Application.put_env(:steward_acs, :embedding_backfill_retry_ms, 60_000)
    on_exit(fn -> Application.delete_env(:steward_acs, :embedding_backfill_retry_ms) end)

    EmbeddingBackfill.note_failure()
    EmbeddingBackfill.note_failure()

    assert %{pending: true} = :sys.get_state(pid)
    GenServer.stop(pid)
  end
end
