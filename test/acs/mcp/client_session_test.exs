defmodule Acs.MCP.ClientSessionTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.ClientSession

  test "URL-seeded audience wins over coding clientInfo" do
    ClientSession.seed_url_audience("sess_chat", :chat)

    ClientSession.bind("sess_chat", fn ->
      assert ClientSession.current_id() == "sess_chat"

      assert ClientSession.remember_initialize(
               %{"clientInfo" => %{"name" => "cursor"}},
               "agent-a"
             ) == :chat

      assert {:ok, %{audience: :chat, audience_source: :url}} =
               ClientSession.fetch("sess_chat")

      assert ClientSession.resolve_audience("agent-a") == :chat
    end)

    assert ClientSession.current_id() == nil
  end

  test "Claude clientInfo resolves to chat without URL seed" do
    ClientSession.bind("sess_claude", fn ->
      assert ClientSession.remember_initialize(
               %{"clientInfo" => %{"name" => "Claude"}},
               nil
             ) == :chat

      assert ClientSession.resolve_audience(nil) == :chat
    end)
  end

  test "coding clientInfo resolves to coding without URL seed" do
    ClientSession.bind("sess_coding", fn ->
      assert ClientSession.remember_initialize(
               %{"clientInfo" => %{"name" => "cursor"}},
               nil
             ) == :coding

      assert ClientSession.resolve_audience(nil) == :coding
    end)
  end

  test "seed_mcp_connect stores endpoint for provenance" do
    ClientSession.bind("sess_endpoint", fn ->
      :ok = ClientSession.seed_mcp_connect("sess_endpoint", "/mcp/chat/sse", :chat)

      assert ClientSession.resolve_mcp_endpoint(nil) == "/mcp/chat/sse"

      ClientSession.remember_initialize(
        %{"clientInfo" => %{"name" => "cursor"}},
        "agent-b"
      )

      assert ClientSession.resolve_mcp_endpoint("agent-b") == "/mcp/chat/sse"
      assert {:ok, %{mcp_endpoint: "/mcp/chat/sse"}} = ClientSession.fetch("sess_endpoint")
    end)
  end

  test "resolve_client_name and audience_source after initialize" do
    ClientSession.bind("sess_client_meta", fn ->
      :ok = ClientSession.seed_mcp_connect("sess_client_meta", "/mcp/chat/sse", :chat)

      assert ClientSession.remember_initialize(
               %{"clientInfo" => %{"name" => "claude.ai", "version" => "1.2.3"}},
               "agent-c"
             ) == :chat

      assert ClientSession.resolve_client_name("agent-c") == "claude.ai"
      assert ClientSession.resolve_client_version("agent-c") == "1.2.3"
      assert ClientSession.resolve_audience_source("agent-c") == :url
      assert ClientSession.resolve_mcp_endpoint("agent-c") == "/mcp/chat/sse"
    end)
  end

  test "get_or_assign_agent_name sticks a pool name to the session" do
    session_id = "sess_pool_#{System.unique_integer([:positive])}"

    ClientSession.bind(session_id, fn ->
      name1 = ClientSession.get_or_assign_agent_name()
      name2 = ClientSession.get_or_assign_agent_name()

      assert is_binary(name1)
      assert name1 != ""
      assert name1 != "unknown"
      assert name2 == name1
    end)
  end

  test "qualified agent name is stable across non-sticky requests for the same identity" do
    session_1 = "sess_qual_1_#{System.unique_integer([:positive])}"
    session_2 = "sess_qual_2_#{System.unique_integer([:positive])}"

    name_1 =
      ClientSession.bind(session_1, fn ->
        ClientSession.get_or_assign_qualified_agent_name("Nahar Emet")
      end)

    name_2 =
      ClientSession.bind(session_2, fn ->
        ClientSession.get_or_assign_qualified_agent_name("Nahar Emet")
      end)

    assert name_1 =~ ~r/^nahar_emet_/
    assert name_2 == name_1
  end

  test "qualified agent name sticks to a reused (sticky) session" do
    session_id = "sess_qual_sticky_#{System.unique_integer([:positive])}"

    ClientSession.bind(session_id, fn ->
      name1 = ClientSession.get_or_assign_qualified_agent_name("Nahar Emet")
      name2 = ClientSession.get_or_assign_qualified_agent_name("Nahar Emet")

      assert is_binary(name1)
      assert name1 != ""
      assert name2 == name1
    end)
  end

  test "different identities get distinct qualified agent names" do
    session_alpha = "sess_qual_a2_#{System.unique_integer([:positive])}"
    session_beta = "sess_qual_b2_#{System.unique_integer([:positive])}"

    name_alpha =
      ClientSession.bind(session_alpha, fn ->
        ClientSession.get_or_assign_qualified_agent_name("Nahar Emet")
      end)

    name_beta =
      ClientSession.bind(session_beta, fn ->
        ClientSession.get_or_assign_qualified_agent_name("Somebody Else")
      end)

    assert name_alpha =~ ~r/^nahar_emet_/
    assert name_beta =~ ~r/^somebody_else_/
    refute name_alpha == name_beta
  end
end
