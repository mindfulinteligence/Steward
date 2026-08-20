defmodule Acs.Memory.VectorIndexTest do
  use ExUnit.Case, async: false

  alias Acs.Memory.VectorIndex

  setup do
    # Checkout sandbox connection for this test process
    Ecto.Adapters.SQL.Sandbox.checkout(Acs.Repo)
    cleanup_test_embeddings()
    VectorIndex.create_embeddings_table()
    on_exit(fn -> cleanup_test_embeddings() end)
    :ok
  end

  describe "create_embeddings_table/0" do
    test "creates embeddings table without error" do
      # Should not raise
      assert VectorIndex.create_embeddings_table() == :ok

      # Calling again should also succeed (idempotent)
      assert VectorIndex.create_embeddings_table() == :ok
    end
  end

  describe "upsert_embedding/2" do
    test "stores embedding for a memory" do
      memory_id = "test_memory_#{System.unique_integer([:positive])}"
      embedding = [0.1, 0.2, 0.3, 0.4, 0.5]

      assert VectorIndex.upsert_embedding(memory_id, embedding) == :ok
    end

    test "updates existing embedding" do
      memory_id = "test_update_#{System.unique_integer([:positive])}"
      embedding1 = [0.1, 0.2, 0.3, 0.4, 0.5]
      embedding2 = [0.5, 0.4, 0.3, 0.2, 0.1]

      VectorIndex.upsert_embedding(memory_id, embedding1)
      VectorIndex.upsert_embedding(memory_id, embedding2)

      # Should succeed without error
      assert VectorIndex.upsert_embedding(memory_id, embedding2) == :ok
    end
  end

  describe "upsert_embeddings/1" do
    test "batch stores embeddings for multiple memories" do
      entries = [
        {"batch1_#{System.unique_integer([:positive])}", [1.0, 0.0, 0.0, 0.0, 0.0], "default",
         nil, nil, "hash1", "model"},
        {"batch2_#{System.unique_integer([:positive])}", [0.0, 1.0, 0.0, 0.0, 0.0], "default",
         nil, nil, "hash2", "model"},
        {"batch3_#{System.unique_integer([:positive])}", [0.0, 0.0, 1.0, 0.0, 0.0], "default",
         nil, nil, "hash3", "model"}
      ]

      assert VectorIndex.upsert_embeddings(entries) == :ok

      assert {:ok, %{rows: rows}} =
               Acs.Repo.query(
                 "SELECT memory_id, content_hash, embedding_model FROM memory_embeddings WHERE org = ?",
                 [
                   "default"
                 ]
               )

      assert length(rows) == 3

      assert Enum.all?(rows, fn [_memory_id, hash, model] ->
               hash =~ "hash" and model == "model"
             end)
    end

    test "batch upsert updates existing rows" do
      memory_id = "batch_update_#{System.unique_integer([:positive])}"

      VectorIndex.upsert_embedding(memory_id, [1.0, 0.0, 0.0, 0.0, 0.0])

      assert VectorIndex.upsert_embeddings([
               {memory_id, [0.0, 1.0, 0.0, 0.0, 0.0], "default", nil, nil, "hash", "model"}
             ]) == :ok

      assert {:ok, %{rows: [[stored_id]]}} =
               Acs.Repo.query(
                 "SELECT memory_id FROM memory_embeddings WHERE org = ?",
                 ["default"]
               )

      assert stored_id == memory_id
    end
  end

  describe "search_similar/2" do
    test "finds similar memories within the same org" do
      # Insert test memories with known embeddings
      memory1 = "sim1_#{System.unique_integer([:positive])}"
      memory2 = "sim2_#{System.unique_integer([:positive])}"
      memory3 = "sim3_#{System.unique_integer([:positive])}"

      # 5-element vectors for similarity testing
      vec1 = [1.0, 0.0, 0.0, 0.0, 0.0]
      vec2 = [0.0, 1.0, 0.0, 0.0, 0.0]
      vec3 = [0.0, 0.0, 1.0, 0.0, 0.0]

      VectorIndex.upsert_embedding(memory1, vec1)
      VectorIndex.upsert_embedding(memory2, vec2)
      VectorIndex.upsert_embedding(memory3, vec3)

      # Search with vec1 should find memory1 first
      results = VectorIndex.search_similar(vec1, limit: 3)

      assert is_list(results)
      assert length(results) == 3

      # First result should be memory1 (identical vector)
      assert hd(results).memory_id == memory1
    end

    test "scopes search to org in multi-tenant mode" do
      memory1 = "org1_#{System.unique_integer([:positive])}"
      memory2 = "org2_#{System.unique_integer([:positive])}"
      vec = [1.0, 0.0, 0.0, 0.0, 0.0]
      Application.put_env(:steward_acs, :multi_tenant, true)
      Application.put_env(:steward_acs, :org_name, "prod")

      on_exit(fn ->
        Application.delete_env(:steward_acs, :multi_tenant)
        Application.delete_env(:steward_acs, :org_name)
      end)

      VectorIndex.upsert_embedding(memory1, vec, "acme")
      VectorIndex.upsert_embedding(memory2, vec, "beta")

      acme_results = VectorIndex.search_similar(vec, org: "acme", limit: 10)
      beta_results = VectorIndex.search_similar(vec, org: "beta", limit: 10)

      assert Enum.map(acme_results, & &1.memory_id) == [memory1]
      assert Enum.map(beta_results, & &1.memory_id) == [memory2]

      assert {:ok, %{rows: [[stored_id]]}} =
               Acs.Repo.query(
                 "SELECT memory_id FROM memory_embeddings WHERE org = ?",
                 ["acme"]
               )

      assert stored_id == "acme:#{memory1}"
    end

    test "returns empty list when no embeddings exist" do
      # Clean table first
      cleanup_test_embeddings()

      results = VectorIndex.search_similar([1.0, 0.0], limit: 10)

      assert results == []
    end

    test "respects limit parameter" do
      # Insert multiple embeddings
      for i <- 1..5 do
        VectorIndex.upsert_embedding(
          "test_limit_#{i}_#{System.unique_integer([:positive])}",
          [i * 0.1, i * 0.1, 0.0, 0.0, 0.0]
        )
      end

      results = VectorIndex.search_similar([0.5, 0.5, 0.0, 0.0, 0.0], limit: 3)

      assert length(results) == 3
    end
  end

  describe "remove_embedding/1" do
    test "removes embedding for memory" do
      memory_id = "test_remove_#{System.unique_integer([:positive])}"
      embedding = [0.1, 0.2, 0.3, 0.4, 0.5]

      VectorIndex.upsert_embedding(memory_id, embedding)
      assert VectorIndex.remove_embedding(memory_id) == :ok

      # Should not find it anymore
      results = VectorIndex.search_similar(embedding, limit: 10)
      assert Enum.all?(results, fn r -> r.memory_id != memory_id end)
    end

    test "handles non-existent memory gracefully" do
      assert VectorIndex.remove_embedding("nonexistent_memory") == :ok
    end
  end

  describe "search_threshold/2" do
    test "finds memories above similarity threshold" do
      memory1 = "test_thresh_1_#{System.unique_integer([:positive])}"
      memory2 = "test_thresh_2_#{System.unique_integer([:positive])}"

      # Nearly identical vectors (5-element)
      vec1 = [1.0, 0.0, 0.0, 0.0, 0.0]
      _vec2 = [0.99, 0.01, 0.0, 0.0, 0.0]
      vec3 = [0.5, 0.5, 0.0, 0.0, 0.0]

      VectorIndex.upsert_embedding(memory1, vec1)
      VectorIndex.upsert_embedding(memory2, vec3)

      # Search with vec1 should only return memory1 above 0.95 threshold
      results = VectorIndex.search_threshold(vec1, 0.95)

      assert results != []
      assert Enum.any?(results, fn r -> r.memory_id == memory1 end)
    end
  end

  # Helper to clean up test embeddings
  defp cleanup_test_embeddings do
    Acs.Repo.query("DELETE FROM memory_embeddings")
    :ok
  end
end
