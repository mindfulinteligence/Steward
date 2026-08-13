defmodule Acs.MCP.Tools.UpdateMemoryTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.MemoryHandlers

  defp save(args) do
    assert {:ok, %{id: id}} = MemoryHandlers.save_memory(args)
    id
  end

  defp creator_args(extra) do
    Map.merge(
      %{
        "kind" => "learning",
        "content" => "Original content",
        "scope_path" => "acme/exec",
        "visibility" => "org",
        "intake_confirmed" => true,
        "_auth_agent_id" => "alice@acme.com",
        "_auth_role" => "collaborator",
        "_auth_authority_level" => "standard",
        "_auth_authority_sort_order" => 3
      },
      extra
    )
  end

  describe "update_memory/1" do
    test "replaces content when located by memory_id and keeps provenance" do
      org = Acs.Org.current()
      title = "Update by id unique #{System.unique_integer([:positive])}"
      id = save(creator_args(%{"title" => title}))

      assert {:ok, result} =
               MemoryHandlers.update_memory(%{
                 "memory_id" => id,
                 "content" => "Revised content",
                 "_auth_role" => "admin"
               })

      assert result.id == id
      assert result.status == "proposed"
      assert result.changed_fields == ["content"]
      assert result.message == "Memory updated"

      updated = Acs.Memory.Indexer.get_memory(id, org)
      assert updated.content == "Revised content"
      assert updated.title == title
    end

    test "renames title when memory_id is provided" do
      org = Acs.Org.current()
      id = save(creator_args(%{"title" => "Rename me #{System.unique_integer([:positive])}"}))
      new_title = "Renamed #{System.unique_integer([:positive])}"

      assert {:ok, %{changed_fields: ["title"]}} =
               MemoryHandlers.update_memory(%{
                 "memory_id" => id,
                 "title" => new_title,
                 "_auth_role" => "admin"
               })

      assert Acs.Memory.Indexer.get_memory(id, org).title == new_title
    end

    test "resolves by title with scope_path" do
      org = Acs.Org.current()
      title = "By title+scope unique #{System.unique_integer([:positive])}"
      id = save(creator_args(%{"title" => title}))

      assert {:ok, result} =
               MemoryHandlers.update_memory(%{
                 "title" => title,
                 "scope_path" => "acme/exec",
                 "content" => "Scoped revise",
                 "_auth_role" => "admin"
               })

      assert result.id == id
      assert result.changed_fields == ["content"]
      assert Acs.Memory.Indexer.get_memory(id, org).content == "Scoped revise"
    end

    test "resolves by title alone when unique" do
      org = Acs.Org.current()
      title = "Sole match #{System.unique_integer([:positive])}"
      id = save(creator_args(%{"title" => title}))

      assert {:ok, result} =
               MemoryHandlers.update_memory(%{
                 "title" => title,
                 "content" => "Titled revise",
                 "_auth_role" => "admin"
               })

      assert result.id == id
      assert Acs.Memory.Indexer.get_memory(id, org).content == "Titled revise"
    end

    test "errors when multiple memories match the title" do
      title = "Duplicate title #{System.unique_integer([:positive])}"

      save(
        creator_args(%{
          "title" => title,
          "content" => "One distinct semantic payload",
          "scope_path" => "acme/sales"
        })
      )

      org = Acs.Org.current()

      second =
        Acs.Memory.new(%{
          "id" => "duplicate-#{System.unique_integer([:positive])}",
          "kind" => "learning",
          "status" => "proposed",
          "title" => title,
          "content" => "A wholly different semantic payload",
          "scope_path" => "acme/exec",
          "org" => org,
          "created_by" => %{"type" => "developer_key", "id" => "test"}
        })

      assert {:ok, _} =
               Acs.Memory.Store.save(second,
                 actor: %{type: "developer_key", id: "test"},
                 source: "system",
                 message: "Seed duplicate"
               )

      assert {:error, msg} =
               MemoryHandlers.update_memory(%{
                 "title" => title,
                 "content" => "Ambiguous revise",
                 "_auth_role" => "admin"
               })

      assert msg =~ "Multiple memories match title"
      assert msg =~ "Provide memory_id"
    end

    test "errors when title does not match any memory" do
      title = "Missing #{System.unique_integer([:positive])}"

      assert {:error, msg} =
               MemoryHandlers.update_memory(%{
                 "title" => title,
                 "content" => "Nowhere to go",
                 "_auth_role" => "admin"
               })

      assert msg =~ "Memory not found with title '#{title}'"
    end

    test "errors on unknown memory_id without creating anything" do
      before = Acs.Memory.Indexer.list_memories(org: Acs.Org.current()) |> length()

      assert {:error, msg} =
               MemoryHandlers.update_memory(%{
                 "memory_id" => "learning-does-not-exist-xyz",
                 "content" => "Should not create",
                 "_auth_role" => "admin"
               })

      assert msg =~ "Memory not found: learning-does-not-exist-xyz"
      after_count = Acs.Memory.Indexer.list_memories(org: Acs.Org.current()) |> length()
      assert after_count == before
    end

    test "requires memory_id or title" do
      assert {:error, msg} =
               MemoryHandlers.update_memory(%{
                 "content" => "No locator",
                 "_auth_role" => "admin"
               })

      assert msg =~ "Provide memory_id, or title"
    end

    test "errors when nothing to update" do
      id = save(creator_args(%{"title" => "Noop #{System.unique_integer([:positive])}"}))

      assert {:error, msg} =
               MemoryHandlers.update_memory(%{
                 "memory_id" => id,
                 "_auth_role" => "admin"
               })

      assert msg =~ "Nothing to update"
    end

    test "denies caller without clearance to edit" do
      org = Acs.Org.current()
      Acs.AuthorityLevels.ensure_defaults!(org)
      id = save(creator_args(%{"title" => "Protected #{System.unique_integer([:positive])}"}))

      assert {:error, msg} =
               MemoryHandlers.update_memory(%{
                 "memory_id" => id,
                 "content" => "Should be blocked",
                 "_auth_agent_id" => "bob@acme.com",
                 "_auth_role" => "collaborator",
                 "_auth_authority_level" => "standard",
                 "_auth_authority_sort_order" => 3
               })

      assert msg =~ "Access denied"
    end

    test "coerces tags to a list" do
      org = Acs.Org.current()
      id = save(creator_args(%{"title" => "Tags #{System.unique_integer([:positive])}"}))

      assert {:ok, _} =
               MemoryHandlers.update_memory(%{
                 "memory_id" => id,
                 "tags" => ["alpha", "beta"],
                 "_auth_role" => "admin"
               })

      updated = Acs.Memory.Indexer.get_memory(id, org)
      assert Jason.decode!(updated.tags_json) == ["alpha", "beta"]
    end
  end
end
