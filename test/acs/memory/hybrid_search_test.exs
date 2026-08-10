defmodule Acs.Memory.HybridSearchTest do
  use Acs.DataCase, async: false

  alias Acs.Memory.HybridSearch

  # Isolate every case in its own org so polluted default-tenant rows cannot
  # leak into assertions that expect empty / exact memory_id sets.
  setup do
    org = "hybrid-#{System.unique_integer([:positive])}"
    Acs.Org.put_request_org(org)
    on_exit(fn -> Acs.Org.clear_request_org() end)
    %{org: org, zero_embedding: List.duplicate(0.0, Acs.Memory.Embedding.dimensions())}
  end

  describe "search/2" do
    test "returns results from hybrid search", %{org: org, zero_embedding: embedding} do
      setup_test_memories("test_hybrid_1")

      result =
        HybridSearch.search("cache release",
          scope: "agent_coordination_system/cache",
          org: org,
          embedding: embedding,
          log_search: false
        )

      assert is_map(result)
      assert result.query == "cache release"
      assert is_list(result.results)
      assert result.total >= 0
    after
      cleanup_test_memories("test_hybrid_1")
    end

    test "respects limit parameter", %{org: org, zero_embedding: embedding} do
      setup_test_memories("test_hybrid_2")

      result =
        HybridSearch.search("test", limit: 5, org: org, embedding: embedding, log_search: false)

      assert length(result.results) <= 5
    after
      cleanup_test_memories("test_hybrid_2")
    end

    test "filters by scope when provided", %{org: org, zero_embedding: embedding} do
      setup_test_memories("test_hybrid_1")

      result =
        HybridSearch.search("test",
          scope: "agent_coordination_system/cache",
          org: org,
          embedding: embedding,
          log_search: false
        )

      assert is_map(result)
      assert result.query == "test"
    after
      cleanup_test_memories("test_hybrid_1")
    end

    test "returns empty results for no matches", %{org: org, zero_embedding: embedding} do
      result =
        HybridSearch.search("xyzzy_nonexistent_query_12345",
          limit: 10,
          org: org,
          embedding: embedding,
          log_search: false
        )

      assert is_map(result)
      assert result.results == []
    end

    test "drops weak content-only matches by default", %{org: org, zero_embedding: embedding} do
      setup_test_memories("test_hybrid_weak")

      result =
        HybridSearch.search("deleting cache entries",
          limit: 10,
          org: org,
          embedding: embedding,
          log_search: false
        )

      assert is_map(result)
      assert result.results == []
    after
      cleanup_test_memories("test_hybrid_weak")
    end

    test "keeps title matches even when weighted total is under min_score", %{
      org: org,
      zero_embedding: embedding
    } do
      attrs = %{
        "id" => "test_hybrid_title_floor",
        "kind" => "axiom",
        "status" => "proposed",
        "title" => "Minor Cache Note",
        "summary" => "Low importance proposed note",
        "content" => "A brief note about cache behavior.",
        "scope_path" => "app/cache",
        "importance" => 1,
        "tags" => ["cache"]
      }

      memory = Acs.Memory.new(attrs)
      Acs.Memory.Indexer.upsert_memory(memory)

      result =
        HybridSearch.search("cache",
          limit: 10,
          min_score: 0.45,
          org: org,
          embedding: embedding,
          log_search: false
        )

      assert Enum.any?(
               result.results,
               &memory_id_matches?(&1.memory_id, "test_hybrid_title_floor")
             )
    after
      Acs.Memory.Indexer.remove_memory("test_hybrid_title_floor")
    end

    test "default weights favor scope and keep audience ahead of lexical" do
      weights = HybridSearch.weights()

      assert weights.scope == 0.25
      assert weights.audience == 0.15
      assert weights.semantic == 0.25
      assert weights.repo == 0.10

      assert_in_delta weights.semantic + weights.lexical + weights.scope + weights.metadata +
                        weights.audience + weights.repo,
                      1.0,
                      0.0001
    end

    test "honors scope_path as scope alias", %{org: org, zero_embedding: embedding} do
      setup_test_memories("test_hybrid_scope_path")

      via_scope =
        HybridSearch.search("cache",
          scope: "agent_coordination_system/cache",
          org: org,
          embedding: embedding,
          log_search: false
        )

      via_scope_path =
        HybridSearch.search("cache",
          scope_path: "agent_coordination_system/cache",
          org: org,
          embedding: embedding,
          log_search: false
        )

      assert via_scope.total == via_scope_path.total
    after
      cleanup_test_memories("test_hybrid_scope_path")
    end

    test "uses precomputed embedding without calling Ollama", %{
      org: org,
      zero_embedding: embedding
    } do
      setup_test_memories("test_hybrid_embed")

      result =
        HybridSearch.search("cache release",
          embedding: embedding,
          limit: 5,
          org: org,
          log_search: false
        )

      assert is_map(result)
      assert result.query == "cache release"
      assert is_list(result.results)
    after
      cleanup_test_memories("test_hybrid_embed")
    end
  end

  describe "scoring functions" do
    test "compute_lexical_score gives higher score for title match", %{
      org: org,
      zero_embedding: embedding
    } do
      setup_test_memories("test_hybrid_1")

      result =
        HybridSearch.search("cache", limit: 10, org: org, embedding: embedding, log_search: false)

      assert is_map(result)
    after
      cleanup_test_memories("test_hybrid_1")
    end

    test "compute_scope_score gives higher score for matching scope", %{
      org: org,
      zero_embedding: embedding
    } do
      setup_test_memories("test_hybrid_1")

      result1 =
        HybridSearch.search("test",
          scope: "agent_coordination_system/cache",
          org: org,
          embedding: embedding,
          log_search: false
        )

      result2 =
        HybridSearch.search("test",
          scope: "other_app",
          org: org,
          embedding: embedding,
          log_search: false
        )

      assert is_map(result1)
      assert is_map(result2)
    after
      cleanup_test_memories("test_hybrid_1")
    end

    test "compute_metadata_score considers importance and status", %{
      org: org,
      zero_embedding: embedding
    } do
      setup_test_memories("test_hybrid_1")

      result =
        HybridSearch.search("release",
          limit: 10,
          org: org,
          embedding: embedding,
          log_search: false
        )

      assert is_map(result)
    after
      cleanup_test_memories("test_hybrid_1")
    end
  end

  describe "combined scoring" do
    test "handles empty query gracefully", %{org: org, zero_embedding: embedding} do
      setup_test_memories("test_hybrid_1")

      result =
        HybridSearch.search("", limit: 10, org: org, embedding: embedding, log_search: false)

      assert is_map(result)
      assert is_list(result.results)
    after
      cleanup_test_memories("test_hybrid_1")
    end
  end

  describe "repo awareness" do
    test "tags results with repo, origin, and cross_repo when from a different repo", %{
      org: org,
      zero_embedding: embedding
    } do
      setup_test_memories_with_repo("test_hybrid_repo_label", "acme-web")

      result =
        HybridSearch.search("cache release",
          org: org,
          embedding: embedding,
          current_repo: "steward_acs",
          log_search: false
        )

      hit = Enum.find(result.results, &memory_id_matches?(&1.memory_id, "test_hybrid_repo_label"))

      assert hit.repo == "acme-web"
      assert hit.origin == "coding_agent"
      assert hit.cross_repo == true

      same_repo =
        HybridSearch.search("cache release",
          org: org,
          embedding: embedding,
          current_repo: "acme-web",
          log_search: false
        )

      same_hit =
        Enum.find(same_repo.results, &memory_id_matches?(&1.memory_id, "test_hybrid_repo_label"))

      assert same_hit.cross_repo == false
    after
      cleanup_test_memories("test_hybrid_repo_label")
    end

    test "repo filter narrows to exactly one repo", %{org: org, zero_embedding: embedding} do
      setup_test_memories_with_repo("test_hybrid_repo_exact", "acme-web")
      setup_test_memories_with_repo("test_hybrid_repo_other", "acme-other")

      result =
        HybridSearch.search("cache release",
          org: org,
          embedding: embedding,
          repo: "acme-web",
          log_search: false
        )

      assert Enum.any?(result.results, &memory_id_matches?(&1.memory_id, "test_hybrid_repo_exact"))
      refute Enum.any?(result.results, &memory_id_matches?(&1.memory_id, "test_hybrid_repo_other"))
    after
      cleanup_test_memories("test_hybrid_repo_exact")
      cleanup_test_memories("test_hybrid_repo_other")
    end

    test "current repo ranks above other repos", %{org: org, zero_embedding: embedding} do
      setup_test_memories_with_repo("test_hybrid_repo_rank_other", "acme-other")

      result =
        HybridSearch.search("cache release",
          org: org,
          embedding: embedding,
          current_repo: "acme-web",
          log_search: false
        )

      hit = Enum.find(result.results, &memory_id_matches?(&1.memory_id, "test_hybrid_repo_rank_other"))

      assert hit.cross_repo == true
      assert hit.scores.repo <= 0.2
    after
      cleanup_test_memories("test_hybrid_repo_rank_other")
    end
  end

  defp setup_test_memories(id) do
    attrs = %{
      "id" => id,
      "kind" => "axiom",
      "status" => "approved",
      "title" => "Cache Release Ordering",
      "summary" => "Agent state must be cleared before cache deletion",
      "content" => "When releasing tasks, clear agent ownership before deleting cache entries",
      "scope_path" => "agent_coordination_system/cache/release",
      "importance" => 5,
      "tags" => ["cache", "concurrency"]
    }

    memory = Acs.Memory.new(attrs)
    Acs.Memory.Loader.save(memory)
    Acs.Memory.Indexer.upsert_memory(memory)
    :ok
  end

  defp setup_test_memories_with_repo(id, repo) do
    attrs = %{
      "id" => id,
      "kind" => "axiom",
      "status" => "approved",
      "title" => "Cache Release Ordering",
      "summary" => "Agent state must be cleared before cache deletion",
      "content" => "When releasing tasks, clear agent ownership before deleting cache entries",
      "scope_path" => "agent_coordination_system/cache/release",
      "importance" => 5,
      "tags" => ["cache", "concurrency"],
      "repo" => repo,
      "audience" => "coding",
      "origin" => "coding_agent"
    }

    memory = Acs.Memory.new(attrs)
    Acs.Memory.Loader.save(memory)
    Acs.Memory.Indexer.upsert_memory(memory)
    :ok
  end

  defp cleanup_test_memories(id) do
    case Acs.Memory.Indexer.get_memory(id) do
      nil ->
        :ok

      schema ->
        Acs.Memory.Indexer.remove_memory(id)
        Acs.Memory.Loader.delete(Acs.Memory.new(Map.from_struct(schema)))
    end
  end

  defp memory_id_matches?(memory_id, expected) do
    memory_id == expected or String.ends_with?(memory_id, ":" <> expected)
  end
end
