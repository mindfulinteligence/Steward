defmodule Acs.MCP.Tools.ChatSurfaceTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.Tools.ChatSurface

  test "ask action matrix maps to fine-grained handlers" do
    assert ChatSurface.routed_tool("steward_ask", %{}) == "get_started"
    assert ChatSurface.routed_tool("steward_ask", %{"action" => "start"}) == "get_started"
    assert ChatSurface.routed_tool("steward_ask", %{"content_query" => "pricing"}) == "ask"
    assert ChatSurface.routed_tool("steward_ask", %{"action" => "search"}) == "ask"
    assert ChatSurface.routed_tool("steward_ask", %{"action" => "skill"}) == "skill_get"
    assert ChatSurface.routed_tool("steward_ask", %{"action" => "document"}) == "specs_get"

    assert ChatSurface.routed_tool("steward_ask", %{"action" => "person_status"}) ==
             "get_person_status"

    assert ChatSurface.routed_tool("steward_ask", %{"action" => "present_status"}) ==
             "get_present_status"

    assert ChatSurface.routed_tool("steward_ask", %{"action" => "list_tasks"}) == "list_tasks"
  end

  test "write kind matrix maps to fine-grained handlers" do
    expected = %{
      "memory" => "save_memory",
      "document" => "documents_propose",
      "skill" => "skill_save",
      "memory_status" => "set_memory_status",
      "memory_update" => "update_memory",
      "person_status" => "set_person_status",
      "feedback" => "submit_task_feedback"
    }

    for {kind, handler} <- expected do
      assert ChatSurface.routed_tool("steward_write", %{"kind" => kind}) == handler
    end
  end

  test "work action matrix maps to fine-grained handlers" do
    expected = %{
      "create" => "create_work",
      "claim" => "claim_work",
      "release" => "release_work",
      "resolve_reminder" => "resolve_user_task"
    }

    for {action, handler} <- expected do
      assert ChatSurface.routed_tool("steward_work", %{"action" => action}) == handler
    end
  end

  test "memory args disambiguate façade kind from memory classification" do
    args = %{
      "kind" => "memory",
      "memory_kind" => "decision",
      "title" => "A durable decision",
      "_auth_audience" => "chat"
    }

    assert ChatSurface.canonical_args("steward_write", args) == %{
             "kind" => "decision",
             "title" => "A durable decision",
             "_auth_audience" => "chat"
           }
  end

  test "legacy chat aliases normalize without changing coding calls" do
    assert {"steward_ask", %{"action" => "search", "content_query" => "x"}} =
             ChatSurface.normalize_legacy_call("ask", %{"content_query" => "x"}, :chat)

    assert {"steward_write", %{"kind" => "memory", "memory_kind" => "warning"}} =
             ChatSurface.normalize_legacy_call("save_memory", %{"kind" => "warning"}, :chat)

    assert {"ask", %{"content_query" => "x"}} =
             ChatSurface.normalize_legacy_call("ask", %{"content_query" => "x"}, :coding)
  end

  test "chat next steps wrap fine-grained names and memory kind" do
    assert %{tool: "steward_ask", params: %{action: "skill", search: "deploy"}} =
             ChatSurface.consolidate_step(%{
               tool: "skill_get",
               prompt: "Load it",
               params: %{search: "deploy"}
             })

    assert %{
             tool: "steward_ask",
             params: %{action: "document", app: "steward_acs", path: "documents/reference/x"}
           } =
             ChatSurface.consolidate_step(%{
               tool: "specs_get",
               prompt: "Load document",
               params: %{app: "steward_acs", path: "documents/reference/x"}
             })

    assert %{tool: "steward_write", params: %{kind: "memory", memory_kind: "learning"}} =
             ChatSurface.consolidate_step(%{
               tool: "save_memory",
               prompt: "Save it",
               params: %{kind: "learning"}
             })
  end

  test "steward_ask schema includes document fetch branch" do
    ask = Enum.find(ChatSurface.tool_defs(), &(&1["name"] == "steward_ask"))
    branches = ask["inputSchema"]["oneOf"]

    assert Enum.any?(branches, fn b ->
             get_in(b, ["properties", "action", "enum"]) == ["document"] and
               "app" in b["required"] and "path" in b["required"]
           end)
  end

  test "tool schemas are three discriminated unions" do
    defs = ChatSurface.tool_defs()
    assert Enum.map(defs, & &1["name"]) == ~w(steward_ask steward_write steward_work)
    assert Enum.all?(defs, &is_list(&1["inputSchema"]["oneOf"]))
  end
end
