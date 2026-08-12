defmodule Acs.Observability.AgentOpsTest do
  use ExUnit.Case, async: true

  alias Acs.Observability.AgentOps

  test "tool_family classifies retrieve write task other" do
    assert AgentOps.tool_family("ask") == "retrieve"
    assert AgentOps.tool_family("save_memory") == "write"
    assert AgentOps.tool_family("create_work") == "task"
    assert AgentOps.tool_family("help") == "other"
  end

  test "chat façade tool_family follows routed discriminator" do
    assert AgentOps.tool_family("steward_ask", %{"action" => "search"}) == "retrieve"
    assert AgentOps.tool_family("steward_ask", %{}) == "retrieve"
    assert AgentOps.tool_family("steward_write", %{"kind" => "memory"}) == "write"
    assert AgentOps.tool_family("steward_write", %{"kind" => "feedback"}) == "task"
    assert AgentOps.tool_family("steward_work", %{"action" => "create"}) == "task"
  end

  test "tool_signal maps learning quadrants" do
    assert AgentOps.tool_signal(true, "other", false, nil, false, false, nil) ==
             "misuse_discovery"

    assert AgentOps.tool_signal(false, "retrieve", true, 0, false, false, nil) == "gap_empty"
    assert AgentOps.tool_signal(false, "retrieve", false, 3, false, false, nil) == "works"
    assert AgentOps.tool_signal(false, "retrieve", false, nil, false, false, nil) == nil
    assert AgentOps.tool_signal(false, "write", false, nil, true, false, nil) == "misuse_write"

    assert AgentOps.tool_signal(false, "write", false, nil, false, true, nil) ==
             "surprise_persist"

    assert AgentOps.tool_signal(false, "write", false, nil, false, false, nil) == "works"

    assert AgentOps.tool_signal(false, "write", false, nil, false, false, "needs_input") ==
             "intake_gate"

    assert AgentOps.tool_signal(false, "write", false, nil, false, false, "bypass") ==
             "intake_bypass"
  end

  test "intake_meta detects needs_input and bypass" do
    assert %{outcome: "needs_input", question_id: "sensitive"} =
             AgentOps.intake_meta(
               "skill_save",
               {:ok,
                %{
                  status: "needs_input",
                  saved: false,
                  questions: [%{"id" => "sensitive"}],
                  intake: %{source: :heuristic}
                }},
               %{}
             )

    assert %{outcome: "bypass"} =
             AgentOps.intake_meta(
               "skill_save",
               {:ok, %{status: "saved", saved: true, intake: %{source: "heuristic"}}},
               %{"intake_confirmed" => true}
             )

    assert %{outcome: "allowed"} =
             AgentOps.intake_meta(
               "save_memory",
               {:ok, %{status: "proposed", saved: true, intake: %{source: "llm"}}},
               %{}
             )

    assert %{outcome: "allowed", provider: "openrouter", model: "deepseek/deepseek-4-flash"} =
             AgentOps.intake_meta(
               "save_memory",
               {:ok,
                %{
                  status: "proposed",
                  saved: true,
                  intake: %{
                    source: "llm",
                    provider: "openrouter",
                    model: "deepseek/deepseek-4-flash"
                  }
                }},
               %{}
             )
  end

  test "feedback_signal prefers win then gap then pain" do
    assert AgentOps.feedback_signal(true, "found X", nil, nil, nil) == "win"
    assert AgentOps.feedback_signal(false, nil, nil, nil, "need pricing") == "gap_info"
    assert AgentOps.feedback_signal(false, nil, "broke", nil, nil) == "pain"
    assert AgentOps.feedback_signal(true, nil, nil, nil, nil) == "works"
  end

  test "log_tool is fire-and-forget when exporters are down" do
    assert :ok =
             AgentOps.log_tool(
               tool_name: "ask",
               result: {:ok, %{summary: %{memory_count: 0, document_count: 0}}},
               latency_ms: 5,
               agent_id: "Ada",
               org: "default",
               audience: "chat",
               scope_path: "acme/pricing"
             )
  end

  test "log_embedding is fire-and-forget when exporters are down" do
    assert :ok =
             AgentOps.log_embedding(
               status: "ok",
               latency_ms: 42,
               model: "nomic-embed-text",
               prompt_chars: 120
             )
  end

  test "log_search is fire-and-forget when exporters are down" do
    assert :ok =
             AgentOps.log_search(
               query: "cache release",
               result_count: 1,
               weight_version: "v2-test",
               weights: %{semantic: 0.25, lexical: 0.15, scope: 0.3, metadata: 0.1, audience: 0.2},
               top_results: [%{"memory_id" => "m1", "total_score" => 0.7}],
               org: "default",
               audience: "coding",
               scope_path: "app/cache"
             )
  end

  test "log_tool tags write_without_retrieve then surprise_persist on same chain" do
    chain = "test-chain-#{System.unique_integer([:positive])}"

    assert :ok =
             AgentOps.log_tool(
               tool_name: "save_memory",
               result: {:ok, %{id: "m1"}},
               agent_id: "Ada",
               org: "default",
               audience: "coding",
               execution_id: chain,
               scope_path: "lib/acs/observability",
               kind: "learning"
             )

    assert :ok =
             AgentOps.log_tool(
               tool_name: "ask",
               result: {:ok, %{summary: %{memory_count: 0, document_count: 0}}},
               agent_id: "Ada",
               org: "default",
               audience: "coding",
               execution_id: chain,
               scope_path: "lib/acs/observability"
             )

    assert :ok =
             AgentOps.log_tool(
               tool_name: "save_memory",
               result: {:ok, %{id: "m2"}},
               agent_id: "Ada",
               org: "default",
               audience: "coding",
               execution_id: chain,
               scope_path: "lib/acs/observability",
               kind: "learning"
             )
  end

  test "log_feedback is fire-and-forget when exporters are down" do
    assert :ok =
             AgentOps.log_feedback(
               agent_id: "Ada",
               org: "default",
               audience: "chat",
               task_id: "t1",
               guidance_useful: true,
               learned_for_agents: "ask before inventing",
               had_issues: "empty ask twice",
               improvements: "seed pricing scope",
               info_needed: "pricing scope"
             )
  end

  test "tool_names_from_list sorts and extracts names" do
    assert AgentOps.tool_names_from_list([
             %{"name" => "save_memory"},
             %{"name" => "ask"},
             %{name: "get_started"},
             "submit_task_feedback",
             %{"name" => ""},
             %{}
           ]) == ["ask", "get_started", "save_memory", "submit_task_feedback"]
  end

  test "tools_hash is stable for same set regardless of input order" do
    a = AgentOps.tools_hash(["ask", "get_started", "save_memory"])
    b = AgentOps.tools_hash(["save_memory", "ask", "get_started"])
    assert a == b
    assert byte_size(a) == 64
  end

  test "tools_list_fields builds inventory shape for chat surface" do
    names = Enum.sort(Acs.MCP.CoreToolRoles.chat_surface())

    fields =
      AgentOps.tools_list_fields(names,
        audience: :chat,
        audience_source: :url,
        client_name: "claude.ai",
        client_version: "1.0",
        mcp_endpoint: "/mcp/chat/sse",
        role: "collaborator",
        org: "acme",
        agent_id: "Ada"
      )

    assert fields["audience"] == "chat"
    assert fields["audience_source"] == "url"
    assert fields["client_name"] == "claude.ai"
    assert fields["mcp_endpoint"] == "/mcp/chat/sse"
    assert fields["tool_count"] == length(names)
    assert fields["tool_names"] == names
    assert fields["tools_hash"] == AgentOps.tools_hash(names)
    assert fields["tool_names"] == ~w(steward_ask steward_work steward_write)
    assert "help" not in fields["tool_names"]
  end

  test "log_tools_list is fire-and-forget when exporters are down" do
    assert :ok =
             AgentOps.log_tools_list(
               tools: [%{"name" => "ask"}, %{"name" => "get_started"}],
               audience: "chat",
               audience_source: "url",
               client_name: "deploy-smoke-chat",
               mcp_endpoint: "/mcp/chat/sse",
               role: "collaborator",
               org: "default"
             )
  end
end
