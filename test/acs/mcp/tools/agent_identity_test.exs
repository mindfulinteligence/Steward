defmodule Acs.MCP.Tools.AgentIdentityTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools

  test "blank agent_id is coerced to OAuth auth identity" do
    assert {:ok, _result} =
             Tools.call_tool("get_present_status", %{
               "agent_id" => "",
               "_auth_agent_id" => "email|oauth-user",
               "_auth_role" => "member"
             })
  end

  test "mismatched agent_id still rejected when auth identity present for coding" do
    assert {:error, reason} =
             Tools.call_tool("get_present_status", %{
               "agent_id" => "Eve",
               "_auth_agent_id" => "email|oauth-user",
               "_auth_role" => "member",
               "_auth_audience" => "coding"
             })

    assert reason =~ "does not match authenticated identity"
  end

  test "chat audience coerces invented agent_id to OAuth identity" do
    assert {:ok, result} =
             Tools.call_tool("get_present_status", %{
               "agent_id" => "nahar-chat",
               "_auth_agent_id" => "Nahar",
               "_auth_role" => "member",
               "_auth_audience" => "chat"
             })

    assert Map.get(result, :agent_id) == "Nahar" or Map.get(result, :assigned_agent_id) == "Nahar"
  end

  test "chat steward_ask bootstrap returns authenticated identity and three-tool packet" do
    assert {:ok, packet} =
             Tools.call_tool("steward_ask", %{
               "_auth_agent_id" => "Nahar",
               "_auth_role" => "member",
               "_auth_audience" => "chat"
             })

    assert packet.connected_user == "Nahar"
    assert packet.authenticated_as == "Nahar"
    assert packet.your_agent_id == "Nahar"
    assert packet.agent_identity =~ "Nahar"
    assert packet.get_started =~ "steward_ask"
    assert packet.pending_reminders == []
    assert is_binary(packet.user_task_protocol)
    assert packet.pending_reminders_guidance =~ "steward_work"
    assert Enum.map(packet.tools, & &1.tool) == ~w(steward_ask steward_write steward_work)
    assert Enum.all?(packet._next, &(&1.tool in ~w(steward_ask steward_write steward_work)))
  end

  test "coding get_started returns connected_user from MCP token developer_name" do
    assert {:ok, packet} =
             Tools.call_tool("get_started", %{
               "audience" => "coding",
               "_auth_agent_id" => "nahar-dev",
               "_auth_role" => "admin",
               "_auth_audience" => "coding"
             })

    assert packet.connected_user == "nahar-dev"
    assert packet.authenticated_as == "nahar-dev"
    assert packet.agent_identity =~ "nahar-dev"
    assert packet.get_started =~ "Connected user: \"nahar-dev\""
  end

  test "local mode coding get_started uses the workspace developer name like remote" do
    original = Application.get_env(:steward_acs, :developer_name)
    Application.put_env(:steward_acs, :developer_name, "Nahar")

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:steward_acs, :developer_name)
        _ -> Application.put_env(:steward_acs, :developer_name, original)
      end
    end)

    assert {:ok, packet} =
             Tools.call_tool("get_started", %{
               "audience" => "coding",
               "_auth_role" => "admin",
               "_auth_audience" => "coding"
             })

    assert packet.connected_user == "Nahar"
    assert packet.authenticated_as == "Nahar"
    assert packet.your_agent_id =~ ~r/^nahar_/
    assert packet.agent_identity =~ "user + pool"
    assert packet.get_started =~ ~s(Connected user: "Nahar")
  end
end
