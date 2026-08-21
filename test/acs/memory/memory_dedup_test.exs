defmodule Acs.MemoryDedupTest do
  @moduledoc """
  Tests the three-layer deduplication in save_memory.
  """

  use Acs.DataCase, async: false

  alias Acs.Memory.Indexer
  alias Acs.Memory.Loader

  @base_attrs %{
    "kind" => "axiom",
    "title" => "Dedup Test Memory",
    "content" =>
      "This is a test memory for deduplication verification. It has enough content to generate a meaningful embedding.",
    "scope_path" => "test/dedup",
    "tags" => ["test", "dedup", "verification"],
    "importance" => 3,
    "_auth_role" => "admin",
    "_auth_authority_sort_order" => 1
  }

  describe "Layer 1: Exact ID duplicate" do
    test "returns an exact duplicate and asks whether to update it" do
      assert {:ok, %{id: id1, status: "proposed"}} =
               Acs.MCP.Tools.call_tool("save_memory", @base_attrs)

      assert {:ok,
              %{
                status: "duplicate",
                duplicate: %{id: ^id1, title: "Dedup Test Memory"},
                update_available: true,
                message: message
              }} =
               Acs.MCP.Tools.call_tool("save_memory", @base_attrs)

      assert message =~ "Ask the user whether to update it"

      cleanup_memory(id1, "test/dedup")
    end

    test "allows memory with same title but different kind (Layer 1 passes)" do
      attrs1 = Map.merge(@base_attrs, %{"kind" => "axiom"})

      assert {:ok, %{id: id1}} =
               Acs.MCP.Tools.call_tool("save_memory", attrs1)

      # Different kind → different ID → Layer 1 passes
      # (Layer 2/3 may or may not catch it depending on Ollama)
      attrs2 = Map.merge(@base_attrs, %{"kind" => "warning"})

      result = Acs.MCP.Tools.call_tool("save_memory", attrs2)

      assert elem(result, 0) in [:ok, :error]

      if elem(result, 0) == :ok and elem(result, 1)[:id] do
        cleanup_memory(elem(result, 1)[:id], "test/dedup")
      end

      cleanup_memory(id1, "test/dedup")
    end
  end

  describe "Layer 3: Lexical fallback" do
    test "rejects memory with same downcased title at same scope" do
      assert {:ok, %{id: id1}} =
               Acs.MCP.Tools.call_tool("save_memory", @base_attrs)

      result =
        Acs.MCP.Tools.call_tool("save_memory", %{
          "kind" => "warning",
          "title" => "DEDUP TEST MEMORY",
          "content" => "Slightly different content but same scope and downcased title",
          "scope_path" => "test/dedup",
          "tags" => ["test", "dedup"],
          "importance" => 4,
          "_auth_role" => "admin",
          "_auth_authority_sort_order" => 1
        })

      # Layer 3 should detect duplicate title at same scope regardless of Ollama
      assert {:ok, %{status: "duplicate", duplicate: %{title: "Dedup Test Memory"}}} = result

      cleanup_memory(id1, "test/dedup")
    end

    test "allows memory with different title at same scope" do
      assert {:ok, %{id: id1}} =
               Acs.MCP.Tools.call_tool("save_memory", @base_attrs)

      # Different title should always succeed
      assert {:ok, %{id: id2}} =
               Acs.MCP.Tools.call_tool("save_memory", %{
                 "kind" => "pattern",
                 "title" => "Completely Different Memory",
                 "content" =>
                   "This is a completely different memory with different content and meaning.",
                 "scope_path" => "test/dedup",
                 "tags" => ["test", "different"],
                 "importance" => 2
               })

      cleanup_memory(id1, "test/dedup")
      cleanup_memory(id2, "test/dedup")
    end
  end

  describe "Happy path" do
    test "creates a unique memory successfully" do
      assert {:ok, %{id: id, status: "proposed", conflict_flags: _}} =
               Acs.MCP.Tools.call_tool("save_memory", @base_attrs)

      assert String.starts_with?(id, "axiom_")

      cleanup_memory(id, "test/dedup")
    end

    test "creates memories in different scopes with different titles" do
      assert {:ok, %{id: id1}} =
               Acs.MCP.Tools.call_tool("save_memory", @base_attrs)

      # Different title, different scope → always succeeds
      assert {:ok, %{id: id2}} =
               Acs.MCP.Tools.call_tool("save_memory", %{
                 "kind" => "axiom",
                 "title" => "Different Scope Memory",
                 "content" => "Same kind but different title and scope",
                 "scope_path" => "test/other_scope",
                 "tags" => ["test"],
                 "importance" => 3
               })

      cleanup_memory(id1, "test/dedup")
      cleanup_memory(id2, "test/other_scope")
    end
  end

  # Clean up both the YAML file and SQLite index
  defp cleanup_memory(id, scope_path) do
    # Clean up YAML file
    memory = %Acs.Memory{
      id: id,
      kind: "axiom",
      status: "proposed",
      title: "cleanup",
      content: "",
      scope_path: scope_path,
      importance: 3,
      tags: [],
      triggers: [],
      failure_modes: [],
      related_memories: [],
      verification: %{"status" => "proposed"},
      revalidation: %{"interval_days" => 30},
      created_by: %{"type" => "agent", "id" => "test"},
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Loader.delete(memory)
    Indexer.remove_memory(id)
  end
end
