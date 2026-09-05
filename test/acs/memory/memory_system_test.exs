defmodule Acs.MemorySystemTest do
  @moduledoc """
  End-to-end integration test for the ACS Memory System.

  Tests the full pipeline:
  - YAML file creation → Loader → Indexer → Search → Conflict detection
  - Status lifecycle: proposed → approved → stale
  - Guidance packet generation
  - Parse error quarantine
  """

  use Acs.DataCase, async: false

  alias Acs.Memory
  alias Acs.Memory.Loader
  alias Acs.Memory.Indexer
  alias Acs.Memory.Search
  alias Acs.Memory.Conflict
  alias Acs.Memory.Guidance
  alias Acs.Memory.Schema
  alias Acs.Repo

  @tmp_dir Path.expand("../../tmp/memory_test", __DIR__)

  setup do
    # Create a clean test directory for fixture files
    File.mkdir_p!(@tmp_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
      # Clean up YAML files that may have been saved to the build dir
      cleanup_saved_yaml_files()
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Loader
  # ---------------------------------------------------------------------------

  describe "Loader" do
    test "loads a valid YAML memory file" do
      file_path = Path.join(@tmp_dir, "valid_memory.yaml")

      write_test_yaml(file_path, %{
        "id" => "test_loader_001",
        "kind" => "axiom",
        "status" => "proposed",
        "title" => "Loader Test Memory",
        "scope_path" => "test/loader",
        "content" => "Test content for loader verification.",
        "importance" => 3,
        "tags" => ["test"],
        "triggers" => [],
        "failure_modes" => [],
        "related_memories" => [],
        "verification" => %{"status" => "proposed"},
        "revalidation" => %{"interval_days" => 30}
      })

      assert {:ok, memory} = Loader.load_file(file_path)
      assert memory.id == "test_loader_001"
      assert memory.title == "Loader Test Memory"
      assert memory.kind == "axiom"
      assert memory.status == "proposed"
      assert memory.scope_path == "test/loader"
    end

    test "returns error for non-existent file" do
      assert {:error, _reason} = Loader.load_file("/nonexistent/path.yaml")
    end

    test "quarantines files with invalid YAML content" do
      bad_path = Path.join(@tmp_dir, "bad.yaml")
      File.write!(bad_path, "invalid: [yaml: : : : broken")

      assert {:error, _reason} = Loader.load_file(bad_path)
    end

    test "quarantines files with missing required fields" do
      file_path = Path.join(@tmp_dir, "missing_fields.yaml")

      write_test_yaml(file_path, %{
        "kind" => "axiom",
        "title" => "Missing ID"
        # Note: intentionally no "id" or "scope_path"
      })

      assert {:error, _reason} = Loader.load_file(file_path)
    end

    test "saves and reloads a memory struct" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "save_reload_test",
          "scope_path" => "test/save_reload"
        })

      assert :ok = Loader.save(memory)

      saved_path = Loader.memory_to_path(memory)
      assert File.exists?(saved_path)

      assert {:ok, loaded} = Loader.load_file(saved_path)
      assert loaded.id == "save_reload_test"
      assert loaded.title == memory.title
    end

    test "load_all returns memories and quarantined list even with example fixtures" do
      # This tests that load_all runs without error and returns the expected structure.
      # It will pick up any example YAML files already in the memory dir.
      result = Loader.load_all()

      assert match?({:ok, _memories, _quarantined}, result)
      {:ok, memories, quarantined} = result
      assert is_list(memories)
      assert is_list(quarantined)
    end
  end

  # ---------------------------------------------------------------------------
  # Indexer
  # ---------------------------------------------------------------------------

  describe "Indexer" do
    test "upserts a memory into the SQLite database" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "indexer_upsert_001",
          "scope_path" => "test/indexer"
        })

      assert {:ok, ^memory} = Indexer.upsert_memory(memory)

      schema = Repo.get!(Schema, "indexer_upsert_001")
      assert schema.title == memory.title
      assert schema.kind == memory.kind
      assert schema.status == "proposed"
    end

    test "upsert is idempotent" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "indexer_idempotent_001",
          "scope_path" => "test/indexer",
          "title" => "Original Title"
        })

      assert {:ok, _} = Indexer.upsert_memory(memory)

      # Update the title and upsert again
      updated =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "indexer_idempotent_001",
          "scope_path" => "test/indexer",
          "title" => "Updated Title"
        })

      assert {:ok, _} = Indexer.upsert_memory(updated)

      schema = Repo.get!(Schema, "indexer_idempotent_001")
      assert schema.title == "Updated Title"
    end

    test "sync_all processes memory files from the loader" do
      # Create and save a memory so it will be picked up by load_all
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "sync_all_test_001",
          "scope_path" => "test/sync_all"
        })

      assert :ok = Loader.save(memory)

      {:ok, count, quarantined} = Indexer.sync_all()
      assert is_integer(count)
      assert is_list(quarantined)

      # Verify the memory is now in the database
      assert Repo.get(Schema, "sync_all_test_001")
    end

    test "lists memories with status filter" do
      # Insert two memories with different statuses
      mem1 =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "list_status_proposed",
          "scope_path" => "test/indexer_list",
          "status" => "proposed"
        })

      mem2 =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "list_status_approved",
          "scope_path" => "test/indexer_list",
          "status" => "approved"
        })

      Indexer.upsert_memory(mem1)
      Indexer.upsert_memory(mem2)

      proposed = Indexer.list_memories(status: "proposed")
      assert Enum.any?(proposed, fn m -> m.id == "list_status_proposed" end)
      refute Enum.any?(proposed, fn m -> m.id == "list_status_approved" end)

      approved = Indexer.list_memories(status: "approved")
      assert Enum.any?(approved, fn m -> m.id == "list_status_approved" end)
    end

    test "lists memories with kind filter" do
      mem1 =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "list_kind_axiom",
          "scope_path" => "test/indexer_kind",
          "kind" => "axiom"
        })

      mem2 =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "list_kind_warning",
          "scope_path" => "test/indexer_kind",
          "kind" => "warning"
        })

      Indexer.upsert_memory(mem1)
      Indexer.upsert_memory(mem2)

      axioms = Indexer.list_memories(kind: "axiom")
      assert Enum.any?(axioms, fn m -> m.id == "list_kind_axiom" end)
      refute Enum.any?(axioms, fn m -> m.id == "list_kind_warning" end)
    end

    test "lists memories with scope_path filter" do
      mem1 =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "list_scope_a",
          "scope_path" => "app/feature_a"
        })

      mem2 =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "list_scope_b",
          "scope_path" => "app/feature_b"
        })

      Indexer.upsert_memory(mem1)
      Indexer.upsert_memory(mem2)

      results = Indexer.list_memories(scope_path: "app/feature_a")
      assert Enum.any?(results, fn m -> m.id == "list_scope_a" end)
      refute Enum.any?(results, fn m -> m.id == "list_scope_b" end)
    end

    test "lists memories with limit" do
      for i <- 1..5 do
        memory =
          Acs.MemoryTestHelpers.create_test_memory(%{
            "id" => "list_limit_#{i}",
            "scope_path" => "test/limit",
            "title" => "Memory #{i}"
          })

        Indexer.upsert_memory(memory)
      end

      results = Indexer.list_memories(limit: 3)
      assert length(results) == 3
    end

    test "updates memory status to approved" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "status_update_001",
          "scope_path" => "test/status"
        })

      Indexer.upsert_memory(memory)

      assert {:ok, schema} = Indexer.update_status("status_update_001", "approved")
      assert schema.status == "approved"

      # Verify via database
      updated = Repo.get!(Schema, "status_update_001")
      assert updated.status == "approved"
    end

    test "updates memory status to stale" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "status_stale_001",
          "scope_path" => "test/status"
        })

      Indexer.upsert_memory(memory)
      Indexer.update_status("status_stale_001", "approved")
      Indexer.update_status("status_stale_001", "stale")

      updated = Repo.get!(Schema, "status_stale_001")
      assert updated.status == "stale"
    end

    test "returns error when updating status of non-existent memory" do
      assert {:error, _reason} = Indexer.update_status("nonexistent_id", "approved")
    end

    test "returns error for invalid status value" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "invalid_status_001",
          "scope_path" => "test/status"
        })

      Indexer.upsert_memory(memory)

      # The Schema changeset validates inclusion of status, so this should fail
      result =
        %Schema{id: "invalid_status_001"}
        |> Schema.changeset(%{status: "nonexistent"})
        |> Repo.insert(on_conflict: :replace_all, conflict_target: :id)

      assert {:error, changeset} = result
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "removes a memory from the index" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "remove_test_001",
          "scope_path" => "test/remove"
        })

      Indexer.upsert_memory(memory)
      assert Repo.get(Schema, "remove_test_001")

      assert {:ok, _deleted} = Indexer.remove_memory("remove_test_001")
      assert Repo.get(Schema, "remove_test_001") == nil
    end

    test "remove_memory is idempotent" do
      assert Indexer.remove_memory("nonexistent_id") == :ok
    end

    test "gets a memory by id" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "get_test_001",
          "scope_path" => "test/get"
        })

      Indexer.upsert_memory(memory)

      schema = Indexer.get_memory("get_test_001")
      assert schema
      assert schema.id == "get_test_001"
    end

    test "get_memory returns nil for non-existent id" do
      assert Indexer.get_memory("nonexistent_id") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Search
  # ---------------------------------------------------------------------------

  describe "Search" do
    setup do
      # Create a memory with searchable content
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "search_temporal_001",
          "scope_path" => "test/search",
          "title" => "Cache Invalidation Timing",
          "content" =>
            "Always invalidate cache entries before releasing locks to prevent race conditions.",
          "summary" => "Cache invalidation ordering is critical.",
          "tags" => ["cache", "invalidation", "timing", "locking"]
        })

      Indexer.upsert_memory(memory)
      :ok
    end

    test "finds memories by keyword in title" do
      results = Search.search("Cache", status: "all")
      assert results != []
      assert Enum.any?(results, fn m -> m.id == "search_temporal_001" end)
    end

    test "finds memories by lowercase keyword" do
      results = Search.search("cache", status: "all")
      assert results != []
    end

    test "finds memories by keyword in content" do
      results = Search.search("invalidation", status: "all")
      assert results != []
      assert Enum.any?(results, fn m -> m.id == "search_temporal_001" end)
    end

    test "finds memories by keyword in summary" do
      results = Search.search("ordering", status: "all")
      assert results != []
    end

    test "matches multi-keyword queries whose words are spread across fields" do
      results = Search.search("release ordering invalidation", status: "all")
      assert Enum.any?(results, fn m -> m.id == "search_temporal_001" end)
    end

    test "returns empty list for non-matching search" do
      results = Search.search("xyznonexistentkeyword12345")
      assert results == []
    end

    test "search respects scope_path filter" do
      other =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "search_other_scope",
          "scope_path" => "other_app/features",
          "title" => "Cache Invalidation in Other App"
        })

      Indexer.upsert_memory(other)

      # Search with scope filter should only return memories in that scope
      results = Search.search("cache", scope_path: "test/search", status: "all")
      assert results != []
      assert Enum.all?(results, fn m -> String.starts_with?(m.scope_path, "test/search") end)
    end

    test "search respects kind filter" do
      warning =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "search_warning_kind",
          "scope_path" => "test/search",
          "kind" => "warning",
          "title" => "Cache Warning"
        })

      Indexer.upsert_memory(warning)

      results = Search.search("cache", kind: "axiom")
      assert Enum.all?(results, fn m -> m.kind == "axiom" end)
    end

    test "search respects status filter" do
      Search.search("cache")
      # Default status filter should work
      results = Search.search("cache", status: "proposed")
      assert Enum.any?(results, fn m -> m.id == "search_temporal_001" end)

      # No approved memories should exist
      results = Search.search("cache", status: "approved")
      refute Enum.any?(results, fn m -> m.id == "search_temporal_001" end)
    end

    test "search limits results" do
      for i <- 1..5 do
        mem =
          Acs.MemoryTestHelpers.create_test_memory(%{
            "id" => "search_limit_#{i}",
            "scope_path" => "test/search",
            "title" => "Cache Entry #{i}"
          })

        Indexer.upsert_memory(mem)
      end

      results = Search.search("cache", limit: 3)
      assert length(results) <= 3
    end
  end

  describe "find_relevant" do
    test "returns approved memories matching context keywords" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "relevant_approved_001",
          "scope_path" => "app/cache",
          "title" => "Cache Release Ordering",
          "content" => "Always release locks in reverse acquisition order."
        })

      Indexer.upsert_memory(memory)
      Indexer.update_status("relevant_approved_001", "approved")

      # find_relevant extracts keywords from the context string
      results = Search.find_relevant("cache release ordering", scope_path: "app/cache")
      assert results != []
      assert Enum.any?(results, fn m -> m.id == "relevant_approved_001" end)
    end

    test "does not return non-approved memories" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "relevant_proposed_only",
          "scope_path" => "app/cache",
          "title" => "Proposed Cache Rule",
          "content" => "This memory is still in proposed status."
        })

      Indexer.upsert_memory(memory)
      # Intentionally NOT approving it

      results = Search.find_relevant("cache", scope_path: "app/cache")
      refute Enum.any?(results, fn m -> m.id == "relevant_proposed_only" end)
    end

    test "returns empty list when no approved memories match" do
      results = Search.find_relevant("nonexistent_topic", scope_path: "app/unknown")
      assert results == []
    end

    test "ranks results by importance descending" do
      mem_high =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "relevant_importance_high",
          "scope_path" => "app/cache",
          "importance" => 5,
          "title" => "Critical Cache Rule"
        })

      mem_low =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "relevant_importance_low",
          "scope_path" => "app/cache",
          "importance" => 1,
          "title" => "Minor Cache Note"
        })

      Indexer.upsert_memory(mem_high)
      Indexer.upsert_memory(mem_low)
      Indexer.update_status("relevant_importance_high", "approved")
      Indexer.update_status("relevant_importance_low", "approved")

      results = Search.find_relevant("cache", scope_path: "app/cache")
      assert length(results) >= 2

      # First result should have higher or equal importance to the second
      importances = Enum.map(results, & &1.importance)
      assert importances == Enum.sort(importances, :desc)
    end
  end

  # ---------------------------------------------------------------------------
  # Conflict Detection
  # ---------------------------------------------------------------------------

  describe "Conflict Detection" do
    test "returns no conflicts when no memories exist at scope" do
      flags = Conflict.check("new_memory", "app/new_scope", ["tag1", "tag2", "tag3", "tag4"])
      assert flags == []
    end

    test "detects no conflicts for different scopes even with overlapping tags" do
      # Insert an approved memory at a specific scope
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "conflict_scope_a",
          "scope_path" => "app/cache",
          "title" => "Cache Rule",
          "tags" => ["cache", "release", "ordering", "locking"]
        })

      Indexer.upsert_memory(memory)
      Indexer.update_status("conflict_scope_a", "approved")

      # Check for conflicts at a different scope with overlapping tags
      flags =
        Conflict.check("new_memory", "app/network", ["cache", "release", "ordering", "locking"])

      assert flags == []
    end

    test "detects conflicts when tags overlap at same scope" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "conflict_existing",
          "scope_path" => "app/cache",
          "title" => "Existing Cache Rule",
          "tags" => ["cache", "release", "ordering", "locking", "performance"]
        })

      Indexer.upsert_memory(memory)
      Indexer.update_status("conflict_existing", "approved")

      # Proposed memory with 4 overlapping tags at same scope
      flags =
        Conflict.check("new_memory", "app/cache", [
          "cache",
          "release",
          "ordering",
          "locking",
          "new_tag"
        ])

      assert flags != []

      flag = hd(flags)
      assert flag.type == "overlap"
      assert flag.existing_memory_id == "conflict_existing"
      assert flag.confidence == :high
    end

    test "detects medium confidence conflicts for 3 overlapping tags" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "conflict_medium",
          "scope_path" => "app/cache",
          "title" => "Medium Cache Rule",
          "tags" => ["cache", "release", "ordering"]
        })

      Indexer.upsert_memory(memory)
      Indexer.update_status("conflict_medium", "approved")

      flags =
        Conflict.check("new_memory", "app/cache", ["cache", "release", "ordering", "new_tag"])

      assert flags != []

      flag = hd(flags)
      assert flag.confidence == :medium
    end

    test "allows non-overlapping tags at same scope" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "conflict_no_overlap",
          "scope_path" => "app/cache",
          "title" => "Cache Rule",
          "tags" => ["cache", "locking"]
        })

      Indexer.upsert_memory(memory)
      Indexer.update_status("conflict_no_overlap", "approved")

      # Only 2 tags overlap, threshold is 3
      flags =
        Conflict.check("new_memory", "app/cache", ["cache", "network", "deployment", "monitoring"])

      assert flags == []
    end

    test "check_before_save returns empty list for no conflicts" do
      result =
        Conflict.check_before_save(%{
          "id" => "new_memory",
          "scope_path" => "app/empty_scope",
          "tags" => ["tag1", "tag2", "tag3", "tag4"]
        })

      assert {:ok, []} = result
    end

    test "check_before_save detects conflicts via map interface" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "conflict_before_save",
          "scope_path" => "app/cache",
          "title" => "Existing Rule",
          "tags" => ["cache", "release", "ordering", "locking"]
        })

      Indexer.upsert_memory(memory)
      Indexer.update_status("conflict_before_save", "approved")

      result =
        Conflict.check_before_save(%{
          "id" => "proposed_new",
          "scope_path" => "app/cache",
          "tags" => ["cache", "release", "ordering", "locking", "new_tag"]
        })

      assert {:ok, [_ | _]} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Guidance
  # ---------------------------------------------------------------------------

  describe "Guidance" do
    test "generates empty guidance when no approved memories exist at scope" do
      packet = Guidance.generate("app/new_scope")

      assert packet.scope == "app/new_scope"
      assert packet.critical_axioms == []
      assert packet.warnings == []
      assert packet.relevant_patterns == []
      assert packet.compressed_knowledge == ""
    end

    test "generates guidance from approved axioms" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "guidance_axiom_001",
          "kind" => "axiom",
          "scope_path" => "app/cache",
          "title" => "Cache Release Order",
          "summary" => "Always release locks in reverse acquisition order",
          "content" =>
            "When releasing cache locks, always release in reverse order of acquisition to prevent deadlocks.",
          "tags" => ["cache", "locking", "ordering"],
          "importance" => 5
        })

      Indexer.upsert_memory(memory)
      Indexer.update_status("guidance_axiom_001", "approved")

      packet = Guidance.generate("app/cache")

      assert packet.critical_axioms != []
      axiom = hd(packet.critical_axioms)
      assert axiom.id == "guidance_axiom_001"
      assert axiom.title == "Cache Release Order"
      assert axiom.importance == 5
    end

    test "generates warnings from approved warning memories" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "guidance_warning_001",
          "kind" => "warning",
          "scope_path" => "app/cache",
          "title" => "Avoid Double Locking",
          "summary" => "Double locking can cause deadlocks.",
          "importance" => 4
        })

      Indexer.upsert_memory(memory)
      Indexer.update_status("guidance_warning_001", "approved")

      packet = Guidance.generate("app/cache")

      assert packet.warnings != []
      warning = hd(packet.warnings)
      assert warning.id == "guidance_warning_001"
    end

    test "generates patterns from approved pattern and learning memories" do
      pattern =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "guidance_pattern_001",
          "kind" => "pattern",
          "scope_path" => "app/cache",
          "title" => "Release Pattern",
          "summary" => "Use try/finally for lock release."
        })

      learning =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "guidance_learning_001",
          "kind" => "learning",
          "scope_path" => "app/cache",
          "title" => "Learning: Lock Ordering",
          "summary" => "Learned that lock ordering matters for performance."
        })

      Indexer.upsert_memory(pattern)
      Indexer.upsert_memory(learning)
      Indexer.update_status("guidance_pattern_001", "approved")
      Indexer.update_status("guidance_learning_001", "approved")

      packet = Guidance.generate("app/cache")

      assert length(packet.relevant_patterns) >= 2
    end

    test "compressed knowledge includes title and summary" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "guidance_knowledge_001",
          "kind" => "axiom",
          "scope_path" => "app/cache",
          "title" => "Cache Rule",
          "summary" => "Always invalidate before release.",
          "importance" => 5
        })

      Indexer.upsert_memory(memory)
      Indexer.update_status("guidance_knowledge_001", "approved")

      packet = Guidance.generate("app/cache")

      assert packet.compressed_knowledge =~ "Cache Rule"
      assert packet.compressed_knowledge =~ "Always invalidate"
    end

    test "does not include non-approved memories in guidance" do
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "guidance_not_approved",
          "kind" => "axiom",
          "scope_path" => "app/cache",
          "title" => "Not Approved Rule",
          "summary" => "This should not appear."
        })

      Indexer.upsert_memory(memory)
      # Intentionally NOT approving it

      packet = Guidance.generate("app/cache")
      refute Enum.any?(packet.critical_axioms, fn a -> a.id == "guidance_not_approved" end)
    end
  end

  # ---------------------------------------------------------------------------
  # Memory struct validation
  # ---------------------------------------------------------------------------

  describe "Memory validation" do
    test "accepts valid memory map" do
      valid = %{
        "id" => "valid_test",
        "kind" => "axiom",
        "status" => "proposed",
        "title" => "Valid Memory",
        "scope_path" => "test",
        "importance" => 3
      }

      assert Memory.validate(valid) == :ok
    end

    test "rejects missing id" do
      assert {:error, reasons} =
               Memory.validate(%{
                 "kind" => "axiom",
                 "title" => "No ID",
                 "scope_path" => "test",
                 "importance" => 3
               })

      assert Enum.any?(reasons, fn r -> String.contains?(r, "id") end)
    end

    test "rejects missing title" do
      assert {:error, reasons} =
               Memory.validate(%{
                 "id" => "no_title",
                 "kind" => "axiom",
                 "scope_path" => "test",
                 "importance" => 3
               })

      assert Enum.any?(reasons, fn r -> String.contains?(r, "title") end)
    end

    test "rejects missing scope_path" do
      assert {:error, _} =
               Memory.validate(%{
                 "id" => "no_scope",
                 "kind" => "axiom",
                 "title" => "No Scope",
                 "importance" => 3
               })
    end

    test "rejects invalid kind" do
      assert {:error, reasons} =
               Memory.validate(%{
                 "id" => "bad_kind",
                 "kind" => "invalid",
                 "title" => "Bad Kind",
                 "scope_path" => "test",
                 "importance" => 3
               })

      assert Enum.any?(reasons, fn r -> String.contains?(r, "kind") end)
    end

    test "rejects invalid importance" do
      assert {:error, _} =
               Memory.validate(%{
                 "id" => "bad_imp",
                 "kind" => "axiom",
                 "title" => "Bad Importance",
                 "scope_path" => "test",
                 "importance" => 10
               })
    end

    test "rejects non-map input" do
      assert {:error, _} = Memory.validate("not_a_map")
    end

    test "accepts all valid kind types" do
      for kind <- ~w(observation learning warning pattern bug decision invariant axiom) do
        valid = %{
          "id" => "kind_#{kind}",
          "kind" => kind,
          "title" => "Kind test #{kind}",
          "scope_path" => "test",
          "importance" => 3
        }

        assert Memory.validate(valid) == :ok, "Expected kind '#{kind}' to be valid"
      end
    end

    test "accepts all valid status types" do
      for status <- ~w(proposed approved stale deprecated archived parse_error) do
        valid = %{
          "id" => "status_#{status}",
          "kind" => "axiom",
          "status" => status,
          "title" => "Status test #{status}",
          "scope_path" => "test",
          "importance" => 3
        }

        assert Memory.validate(valid) == :ok, "Expected status '#{status}' to be valid"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-End Lifecycle
  # ---------------------------------------------------------------------------

  describe "End-to-End Lifecycle" do
    test "full memory lifecycle: sync → search → approve → guidance → stale" do
      # 1. Create a memory
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "e2e_lifecycle_001",
          "kind" => "learning",
          "scope_path" => "app/testing",
          "title" => "Important Testing Learning",
          "summary" => "This is an important learning about testing.",
          "importance" => 4,
          "tags" => ["testing", "e2e", "verification"]
        })

      # 2. Index it directly (simulates the sync step)
      assert {:ok, _} = Indexer.upsert_memory(memory)

      # 3. Verify it's searchable
      results = Search.search("Important Testing", status: "all")
      assert Enum.any?(results, fn m -> m.id == "e2e_lifecycle_001" end)

      # 4. Approve it
      assert {:ok, _} = Indexer.update_status("e2e_lifecycle_001", "approved")
      approved_list = Indexer.list_memories(status: "approved")
      assert Enum.any?(approved_list, fn m -> m.id == "e2e_lifecycle_001" end)

      # 5. Generate guidance from it
      # The memory has kind "learning", so it appears in relevant_patterns, not critical_axioms
      packet = Guidance.generate("app/testing")
      assert packet.relevant_patterns != []
      assert Enum.any?(packet.relevant_patterns, fn p -> p.id == "e2e_lifecycle_001" end)

      # 6. Mark as stale
      assert {:ok, _} = Indexer.update_status("e2e_lifecycle_001", "stale")
      approved_after = Indexer.list_memories(status: "approved")
      refute Enum.any?(approved_after, fn m -> m.id == "e2e_lifecycle_001" end)

      stale_list = Indexer.list_memories(status: "stale")
      assert Enum.any?(stale_list, fn m -> m.id == "e2e_lifecycle_001" end)

      # 7. Search still finds it (stale memories remain searchable for reference)
      results = Search.search("Important Testing")
      assert Enum.any?(results, fn m -> m.id == "e2e_lifecycle_001" end)
    end

    test "full pipeline: save to YAML → load → index → search" do
      # 1. Create and save memory as YAML file
      memory =
        Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "e2e_pipeline_001",
          "kind" => "axiom",
          "scope_path" => "app/pipeline_test",
          "title" => "Pipeline Test Memory",
          "content" => "This memory tests the full save-load-index-search pipeline."
        })

      assert :ok = Loader.save(memory)

      # 2. Load it back from the YAML file
      saved_path = Loader.memory_to_path(memory)
      assert {:ok, loaded} = Loader.load_file(saved_path)
      assert loaded.id == "e2e_pipeline_001"

      # 3. Index it
      assert {:ok, _} = Indexer.upsert_memory(loaded)

      # 4. Search for it
      results = Search.search("Pipeline Test", status: "all")
      assert Enum.any?(results, fn m -> m.id == "e2e_pipeline_001" end)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp write_test_yaml(file_path, data) when is_map(data) do
    lines = encode_yaml_map(data, 0)
    File.write!(file_path, Enum.join(lines, "\n") <> "\n")
  end

  defp encode_yaml_map(map, indent) do
    Enum.flat_map(map, fn {key, value} ->
      prefix = String.duplicate("  ", indent)

      cond do
        is_nil(value) ->
          ["#{prefix}#{key}:"]

        is_map(value) ->
          if value == %{} do
            ["#{prefix}#{key}: {}"]
          else
            ["#{prefix}#{key}:"] ++ encode_yaml_map(value, indent + 1)
          end

        is_list(value) ->
          if value == [] do
            ["#{prefix}#{key}: []"]
          else
            ["#{prefix}#{key}:"] ++
              Enum.map(value, fn item ->
                "  #{prefix}- #{yaml_scalar(item)}"
              end)
          end

        true ->
          ["#{prefix}#{key}: #{yaml_scalar(value)}"]
      end
    end)
  end

  defp yaml_scalar(value) when is_binary(value) do
    cond do
      # Multiline content: use literal block scalar
      String.contains?(value, "\n") ->
        "|\n" <>
          (value
           |> String.split("\n")
           |> Enum.map(fn line -> "  #{line}" end)
           |> Enum.join("\n"))

      # YAML booleans and nulls that could be misinterpreted
      value in ~w(true false yes no on off null ~) ->
        ~s("#{value}")

      # Values with colons or pipes need quoting
      String.contains?(value, ":") or String.contains?(value, "|") ->
        ~s("#{value}")

      # Values starting with YAML special characters
      String.starts_with?(value, ["'", "\"", "#", "-", "?", "!", "&", "*", "%", "@", " ", ">"]) ->
        ~s("#{value}")

      # Purely numeric values (could be misinterpreted as numbers)
      String.match?(value, ~r/^\d+(\.\d+)?$/) ->
        ~s("#{value}")

      # Values with leading or trailing whitespace
      value != String.trim(value) ->
        ~s("#{value}")

      true ->
        value
    end
  end

  defp yaml_scalar(value), do: to_string(value)

  # Clean up YAML files that may have been saved to the build directory.
  # Database cleanup is handled automatically by the SQL sandbox.
  defp cleanup_saved_yaml_files do
    paths_to_clean = [
      Loader.memory_to_path(%Memory{
        id: "save_reload_test",
        scope_path: "test/save_reload"
      }),
      Loader.memory_to_path(%Memory{
        id: "sync_all_test_001",
        scope_path: "test/sync_all"
      }),
      Loader.memory_to_path(%Memory{
        id: "e2e_pipeline_001",
        scope_path: "app/pipeline_test"
      })
    ]

    Enum.each(paths_to_clean, fn path ->
      if File.exists?(path) do
        File.rm!(path)
        cleanup_parent_dirs(Path.dirname(path), Loader.memory_dir())
      end
    end)
  end

  defp cleanup_parent_dirs(dir, stop_dir) when dir == stop_dir or dir == "" or dir == "." do
    :ok
  end

  defp cleanup_parent_dirs(dir, stop_dir) do
    case File.rmdir(dir) do
      :ok -> cleanup_parent_dirs(Path.dirname(dir), stop_dir)
      {:error, _} -> :ok
    end
  end
end
