defmodule Acs.Memory.StoreModeTest do
  use Acs.DataCase, async: false

  alias Acs.Memory.{Commit, Ledger, Revision, Store}
  alias Acs.Orgs.Organization

  setup do
    previous_multi = Application.get_env(:steward_acs, :multi_tenant)
    previous_vault = Application.get_env(:steward_acs, :obsidian_vault_path)
    previous_store = Application.get_env(:steward_acs, :memory_store)
    vault = Path.join(System.tmp_dir!(), "acs-memory-store-#{System.unique_integer([:positive])}")

    Application.put_env(:steward_acs, :obsidian_vault_path, vault)
    Application.put_env(:steward_acs, :memory_store, "yaml")

    on_exit(fn ->
      restore_env(:multi_tenant, previous_multi)
      restore_env(:obsidian_vault_path, previous_vault)
      restore_env(:memory_store, previous_store)
      File.rm_rf(vault)
    end)

    %{vault: vault}
  end

  test "single-tenant saves remain file-backed" do
    Application.put_env(:steward_acs, :multi_tenant, false)
    memory = memory_fixture("single-file", "default")

    assert {:ok, %{revision: nil}} = Store.save(memory)
    assert File.regular?(Acs.Memory.Loader.memory_to_path(memory))
    assert Ledger.history(memory.id, memory.org) == []
  end

  test "multi-tenant saves are DB-only and append immutable revisions", %{vault: vault} do
    Application.put_env(:steward_acs, :multi_tenant, true)
    org = create_org("ledger-a")
    memory = memory_fixture("db-only", org.slug)

    Acs.Org.with_current(org.slug, fn ->
      assert {:ok, %{revision: first, commit: first_commit}} =
               Store.save(memory,
                 actor: %{type: "developer_key", id: "agent-1"},
                 source: "mcp",
                 message: "Create audited memory"
               )

      assert first.revision_number == 1
      assert first.operation == "create"
      assert first_commit.actor_id == "agent-1"
      assert first_commit.sequence == 1
      assert {:ok, first_snapshot} = Ledger.snapshot(first)
      assert first_snapshot["status"] == "proposed"

      assert {:ok, %{revision: second}} =
               Store.transition(memory.id, "approved",
                 org: org.slug,
                 actor: %{type: "user", id: "42"},
                 source: "web",
                 expected_head_revision_id: first.id,
                 message: "Approve company memory"
               )

      assert second.revision_number == 2
      assert second.parent_revision_id == first.id
      assert second.parent_revision_hash == first.revision_hash

      assert [stored_first, stored_second] = Store.history(memory.id, org.slug)
      assert stored_first.id == first.id
      assert stored_second.id == second.id
      assert {:ok, unchanged_first} = Ledger.snapshot(stored_first)
      assert unchanged_first == first_snapshot
      assert {:ok, latest_snapshot} = Ledger.snapshot(stored_second)
      assert latest_snapshot["status"] == "approved"

      assert {:ok, changes} = Store.diff(stored_first, stored_second)
      assert changes["status"] == %{from: "proposed", to: "approved"}
      assert :ok = Store.verify(org.slug)

      assert {:error, {:conflict, %{actual_head: actual}}} =
               Store.revise(memory.id, %{title: "stale edit"},
                 org: org.slug,
                 actor: %{type: "user", id: "43"},
                 source: "web",
                 expected_head_revision_id: first.id
               )

      assert actual == second.id

      assert {:error, "Filesystem memory writes are disabled in multi-tenant mode"} =
               Acs.Memory.Loader.save(memory)
    end)

    refute File.exists?(vault)
    assert Repo.aggregate(Revision, :count) == 2
    assert Repo.aggregate(Commit, :count) == 2
  end

  test "MCP developer-key creation records a valid trusted actor" do
    Application.put_env(:steward_acs, :multi_tenant, true)
    org = create_org("ledger-mcp")

    Acs.Org.with_current(org.slug, fn ->
      assert {:ok, %{id: memory_id}} =
               Acs.MCP.Tools.MemoryHandlers.save_memory(%{
                 "kind" => "learning",
                 "title" => "MCP ledger actor #{System.unique_integer([:positive])}",
                 "content" => "A company memory created through the MCP mutation path.",
                 "scope_path" => "tests/mcp-ledger",
                 "importance" => 3,
                 "_auth_agent_id" => "developer-key-17",
                 "_auth_role" => "admin"
               })

      assert [revision] = Store.history(memory_id, org.slug)
      assert Repo.get!(Commit, revision.commit_id).actor_type == "developer_key"
      assert Repo.get!(Commit, revision.commit_id).actor_id == "developer-key-17"
    end)
  end

  test "database store rejects a payload tenant that differs from request context" do
    Application.put_env(:steward_acs, :multi_tenant, true)
    org = create_org("ledger-context")
    other_org = create_org("ledger-other")
    memory = memory_fixture("wrong-tenant", other_org.slug)

    Acs.Org.with_current(org.slug, fn ->
      assert {:error, :tenant_mismatch} =
               Store.save(memory,
                 actor: %{type: "system", id: "test"},
                 source: "system",
                 message: "Wrong tenant"
               )

      assert Repo.aggregate(Revision, :count) == 0
      assert Repo.aggregate(Commit, :count) == 0
    end)
  end

  test "database store accepts explicit org opt for background jobs without request context" do
    Application.put_env(:steward_acs, :multi_tenant, true)
    org = create_org("auditor-bg")
    memory = memory_fixture("auditor-write", org.slug)

    # Simulates Memory.Auditor: no request org, but org: passed in opts.
    assert {:ok, _} =
             Store.save(memory,
               org: org.slug,
               actor: %{type: "system", id: "memory_auditor"},
               source: "auditor",
               message: "Auditor revision"
             )

    assert Acs.Memory.Indexer.get_memory(memory.id, org.slug)
  end

  test "ledger validation failures return errors and roll back atomically" do
    Application.put_env(:steward_acs, :multi_tenant, true)
    org = create_org("ledger-errors")
    memory = memory_fixture("invalid-actor", org.slug)

    Acs.Org.with_current(org.slug, fn ->
      assert {:error, {:ledger_write_failed, _message}} =
               Store.save(memory,
                 actor: %{type: "forged", id: "bad"},
                 source: "mcp",
                 message: "Invalid actor"
               )

      assert Store.history(memory.id, org.slug) == []
      assert is_nil(Acs.Memory.Indexer.get_memory(memory.id, org.slug))
      assert Repo.aggregate(Revision, :count) == 0
      assert Repo.aggregate(Commit, :count) == 0
    end)
  end

  test "database guards reject revision and commit mutation" do
    Application.put_env(:steward_acs, :multi_tenant, true)
    org = create_org("ledger-immutable")
    memory = memory_fixture("immutable", org.slug)

    Acs.Org.with_current(org.slug, fn ->
      assert {:ok, %{revision: revision, commit: commit}} =
               Store.save(memory,
                 actor: %{type: "system", id: "test"},
                 source: "system",
                 message: "Create immutable row"
               )

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 Repo,
                 "UPDATE memory_revisions SET operation = 'revise' WHERE id = ?",
                 [revision.id]
               )

      assert {:error, _} =
               Ecto.Adapters.SQL.query(Repo, "DELETE FROM memory_commits WHERE id = ?", [
                 commit.id
               ])

      assert Repo.get!(Revision, revision.id).operation == "create"
      assert Repo.get!(Commit, commit.id).id == commit.id
    end)
  end

  test "restore appends a new revision instead of rewinding history" do
    Application.put_env(:steward_acs, :multi_tenant, true)
    org = create_org("ledger-restore")
    memory = memory_fixture("restore", org.slug)
    actor = %{type: "user", id: "7"}

    Acs.Org.with_current(org.slug, fn ->
      assert {:ok, %{revision: first}} =
               Store.save(memory, actor: actor, source: "web", message: "Create")

      assert {:ok, %{revision: second}} =
               Store.revise(memory.id, %{title: "Changed title"},
                 org: org.slug,
                 actor: actor,
                 source: "web",
                 message: "Edit"
               )

      assert {:ok, %{revision: third}} =
               Store.restore(memory.id, first.id,
                 org: org.slug,
                 actor: actor,
                 source: "web",
                 expected_head_revision_id: second.id,
                 message: "Restore original"
               )

      assert third.operation == "restore"
      assert third.revision_number == 3

      assert Enum.map(Store.history(memory.id, org.slug), & &1.id) == [
               first.id,
               second.id,
               third.id
             ]

      assert {:ok, restored} = Ledger.snapshot(third)
      assert restored["title"] == memory.title
    end)
  end

  test "multi-tenant worker selection excludes filesystem memory workers" do
    assert Acs.Application.memory_background_children(true, true) == [Acs.Memory.Auditor]

    assert Acs.Memory.FileWatcher in Acs.Application.memory_background_children(false, true)
    assert Acs.Memory.VaultSweeper in Acs.Application.memory_background_children(false, true)
    assert Acs.Application.memory_background_children(true, false) == []
  end

  test "production can disable the log analyzer worker" do
    previous = Application.get_env(:steward_acs, :log_analyzer_enabled)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:steward_acs, :log_analyzer_enabled),
        else: Application.put_env(:steward_acs, :log_analyzer_enabled, previous)
    end)

    Application.put_env(:steward_acs, :log_analyzer_enabled, false)
    assert Acs.Application.log_analyzer_children() == []

    Application.put_env(:steward_acs, :log_analyzer_enabled, true)
    assert Acs.Application.log_analyzer_children() == [Acs.LogAnalyzer]
  end

  test "approve/reject transition clears human-review flags from the projection" do
    Application.put_env(:steward_acs, :multi_tenant, true)
    org = create_org("ledger-review-clear")
    memory = memory_fixture("review-flags", org.slug)
    storage_id = Acs.Memory.Indexer.storage_id(org.slug, memory.id)

    review_flags =
      Jason.encode!(%{
        "needs_human_review" => true,
        "audit_error_count" => 2,
        "last_audit_error" => "LLM recommended human_review",
        "audit_verdict" => "human_review",
        "quality_score" => 3
      })

    Acs.Org.with_current(org.slug, fn ->
      assert {:ok, _} =
               Store.save(memory,
                 actor: %{type: "system", id: "test"},
                 source: "system",
                 message: "Create"
               )

      Repo.update_all(
        from(m in Acs.Memory.Schema, where: m.id == ^storage_id),
        set: [auditor_flags: review_flags]
      )

      assert {:ok, %{revision: approved_revision}} =
               Store.transition(memory.id, "approved",
                 org: org.slug,
                 actor: %{type: "user", id: "42"},
                 source: "web",
                 message: "Approve"
               )

      approved_row = Repo.get!(Acs.Memory.Schema, storage_id)
      approved_flags = Jason.decode!(approved_row.auditor_flags)
      refute Map.has_key?(approved_flags, "needs_human_review")
      refute Map.has_key?(approved_flags, "audit_error_count")
      refute Map.has_key?(approved_flags, "last_audit_error")
      assert approved_flags["audit_verdict"] == "human_review"
      assert approved_flags["quality_score"] == 3
      assert approved_revision.operation == "transition"
    end)
  end

  defp memory_fixture(suffix, org) do
    Acs.Memory.new(%{
      "id" => "memory-#{suffix}",
      "kind" => "learning",
      "status" => "proposed",
      "title" => "Memory #{suffix}",
      "content" => "Durable content for #{suffix}",
      "scope_path" => "tests/#{suffix}",
      "importance" => 4,
      "org" => org,
      "created_by" => %{"type" => "developer_key", "id" => "agent-1"}
    })
  end

  defp create_org(suffix) do
    value = "#{suffix}-#{System.unique_integer([:positive])}"

    %Organization{}
    |> Organization.changeset(%{
      name: value,
      slug: value,
      subdomain: value,
      plan: "free",
      provisioning_status: "ready"
    })
    |> Repo.insert!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:steward_acs, key)
  defp restore_env(key, value), do: Application.put_env(:steward_acs, key, value)
end
