defmodule Acs.MCP.ProtocolTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Protocol

  describe "handle_message/7 auth requirements" do
    test "tools/call without agent role returns unauthorized" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "help", "arguments" => %{}}
      }

      assert {:ok, %{"error" => %{"code" => -32_001, "message" => "Unauthorized"}}} =
               Protocol.handle_message(msg, nil)
    end

    test "tools/list without agent role returns unauthorized" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list",
        "params" => %{}
      }

      assert {:ok, %{"error" => %{"code" => -32_001, "message" => "Unauthorized"}}} =
               Protocol.handle_message(msg, nil)
    end

    test "ordinary agents cannot override their organization for analysis" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "create_work",
          "arguments" => %{
            "_analysis_org_id" => "org-b",
            "agent_id" => "agent-a",
            "title" => "Must remain in org A"
          }
        }
      }

      assert {:ok, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Protocol.handle_message(msg, "collaborator", "org-a", [], nil, nil, "agent-a")

      assert %{"task_id" => task_id} = Jason.decode!(text)
      assert Acs.Org.with_current("org-a", fn -> Acs.get_task(task_id) end)
      refute Acs.Org.with_current("org-b", fn -> Acs.get_task(task_id) end)
    end

    test "cross-org analysis permission cannot target mutating tools" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "create_work",
          "arguments" => %{
            "_analysis_org_id" => "org-b",
            "agent_id" => "developer",
            "title" => "Cross-org mutation must be denied"
          }
        }
      }

      permissions = ["mcp:cross_org_analysis"]

      assert {:ok,
              %{
                "result" => %{
                  "isError" => true,
                  "content" => [%{"text" => text}]
                }
              }} =
               Protocol.handle_message(
                 msg,
                 "admin",
                 "org-a",
                 permissions,
                 nil,
                 nil,
                 "developer"
               )

      assert text =~ "only permitted for read-only tools"
      assert Acs.Org.with_current("org-a", fn -> Acs.Acs.list_tasks() end) == []
      assert Acs.Org.with_current("org-b", fn -> Acs.Acs.list_tasks() end) == []
    end

    test "initialize succeeds without agent role" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "initialize",
        "params" => %{}
      }

      assert {:ok, %{"result" => %{"protocolVersion" => _, "serverInfo" => info}}} =
               Protocol.handle_message(msg, nil)

      assert info["name"] == "Acs MCP Server"
      assert [%{"src" => src, "mimeType" => "image/png"} | _] = info["icons"]

      assert String.starts_with?(src, "http") or
               String.starts_with?(src, "data:image/png;base64,")
    end

    test "chat initialize instructions include authenticated display name" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "initialize",
        "params" => %{
          "clientInfo" => %{"name" => "claude.ai", "version" => "1"}
        }
      }

      assert {:ok, %{"result" => %{"instructions" => instructions}}} =
               Protocol.handle_message(
                 msg,
                 "collaborator",
                 "acme",
                 ["mcp:tools"],
                 nil,
                 nil,
                 "Nahar"
               )

      assert instructions =~ ~s(Connected ACS user: "Nahar")
      assert instructions =~ "never invent a nickname"
      assert instructions =~ "org or process knowledge"
      assert instructions =~ "steward_write"
      assert instructions =~ "never tool_search"
      refute instructions =~ "steward_ask(action:\"search\", content_query:)"
    end

    test "chat lists only consolidated tools and accepts a hidden legacy alias" do
      initialize = %{
        "jsonrpc" => "2.0",
        "id" => 20,
        "method" => "initialize",
        "params" => %{"clientInfo" => %{"name" => "claude.ai", "version" => "1"}}
      }

      assert {:ok, %{"result" => _}} =
               Protocol.handle_message(
                 initialize,
                 "collaborator",
                 "acme",
                 [],
                 nil,
                 nil,
                 "Alias User"
               )

      list = %{"jsonrpc" => "2.0", "id" => 21, "method" => "tools/list", "params" => %{}}

      assert {:ok, %{"result" => %{"tools" => tools}}} =
               Protocol.handle_message(list, "collaborator", "acme", [], nil, nil, "Alias User")

      assert Enum.map(tools, & &1["name"]) == ~w(steward_ask steward_write steward_work)
      assert Enum.all?(tools, &(&1["_meta"]["anthropic/alwaysLoad"] == true))

      legacy_call = %{
        "jsonrpc" => "2.0",
        "id" => 22,
        "method" => "tools/call",
        "params" => %{"name" => "get_started", "arguments" => %{}}
      }

      assert {:ok, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Protocol.handle_message(
                 legacy_call,
                 "collaborator",
                 "acme",
                 [],
                 nil,
                 nil,
                 "Alias User"
               )

      assert Jason.decode!(text)["connected_user"] == "Alias User"
    end

    test "notifications/initialized has no JSON-RPC response body" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized",
        "params" => %{}
      }

      assert {:ok, nil} = Protocol.handle_message(msg, nil)
    end

    test "authority context flows from handle_message args into tool handler" do
      title = "Authority flow unique #{System.unique_integer([:positive])}"

      call = %{
        "jsonrpc" => "2.0",
        "id" => 99,
        "method" => "tools/call",
        "params" => %{
          "name" => "save_memory",
          "arguments" => %{
            "kind" => "learning",
            "title" => title,
            "content" => "Proves authority context reaches the handler",
            "scope_path" => "acme/exec",
            "visibility" => "org",
            "intake_confirmed" => true
          }
        }
      }

      # args 8-9 = agent_authority_level, agent_authority_sort_order (the plug's
      # conn.assigns, which are invisible to the ToolRegistry GenServer process).
      assert {:ok, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Protocol.handle_message(
                 call,
                 "collaborator",
                 "acme",
                 [],
                 nil,
                 nil,
                 "alice@acme.com",
                 "high",
                 1
               )

      assert {:ok, %{"id" => id}} = Jason.decode(text)
      memory = Acs.Memory.Indexer.get_memory(id, "acme")

      # Previously nil flowed through and writer_authority_sort_order fell back
      # to the org's lowest rank (3); the authority must now be stamped rank 1.
      assert memory.authority_sort_order == 1
    end
  end

  describe "local mode coding identity (single-tenant admin self-identifies)" do
    setup do
      original = Application.get_env(:steward_acs, :developer_name)
      Application.put_env(:steward_acs, :developer_name, "Nahar")

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:steward_acs, :developer_name)
          _ -> Application.put_env(:steward_acs, :developer_name, original)
        end
      end)

      :ok
    end

    test "instructions expose no default identity but get_started uses the workspace developer name like remote" do
      initialize = %{
        "jsonrpc" => "2.0",
        "id" => 30,
        "method" => "initialize",
        "params" => %{"clientInfo" => %{"name" => "cursor", "version" => "1"}}
      }

      assert {:ok, %{"result" => %{"instructions" => instructions}}} =
               Protocol.handle_message(initialize, "admin", "acme", [], nil, nil, "Nahar")

      assert instructions =~ "no default agent identity"
      assert instructions =~ "get_present_status(agent_id: your_name)"

      call = %{
        "jsonrpc" => "2.0",
        "id" => 31,
        "method" => "tools/call",
        "params" => %{"name" => "get_started", "arguments" => %{}}
      }

      assert {:ok, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Protocol.handle_message(call, "admin", "acme", [], nil, nil, "Nahar")

      decoded = Jason.decode!(text)
      assert decoded["connected_user"] == "Nahar"
      assert decoded["authenticated_as"] == "Nahar"
      assert decoded["your_agent_id"] =~ ~r/^nahar_/
      assert decoded["agent_identity"] =~ "user + pool"
      assert decoded["get_started"] =~ ~s(Connected user: "Nahar")
    end

    test "local admin coding agent can create_work under its own agent_id" do
      initialize = %{
        "jsonrpc" => "2.0",
        "id" => 32,
        "method" => "initialize",
        "params" => %{"clientInfo" => %{"name" => "cursor", "version" => "1"}}
      }

      assert {:ok, %{"result" => _}} =
               Protocol.handle_message(initialize, "admin", "acme", [], nil, nil, "Nahar")

      call = %{
        "jsonrpc" => "2.0",
        "id" => 33,
        "method" => "tools/call",
        "params" => %{
          "name" => "create_work",
          "arguments" => %{"agent_id" => "opencode", "title" => "Local self-identified task"}
        }
      }

      assert {:ok, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Protocol.handle_message(call, "admin", "acme", [], nil, nil, "Nahar")

      assert %{"task_id" => task_id} = Jason.decode!(text)
      task = Acs.Org.with_current("acme", fn -> Acs.get_task(task_id) end)
      assert task.created_by_agent == "opencode"
    end
  end

  describe "multi-tenant coding agents get qualified user_name + pool names" do
    setup do
      original = Application.get_env(:steward_acs, :multi_tenant)

      Application.put_env(:steward_acs, :multi_tenant, true)

      on_exit(fn ->
        restore_multi_tenant(original)
        Acs.Org.clear_request_org()
      end)

      :ok
    end

    defp restore_multi_tenant(original) do
      case original do
        nil -> Application.delete_env(:steward_acs, :multi_tenant)
        _ -> Application.put_env(:steward_acs, :multi_tenant, original)
      end
    end

    test "coding initialize instructions include qualified agent name" do
      initialize = %{
        "jsonrpc" => "2.0",
        "id" => 40,
        "method" => "initialize",
        "params" => %{"clientInfo" => %{"name" => "cursor", "version" => "1"}}
      }

      assert {:ok, %{"result" => %{"instructions" => instructions}}} =
               Protocol.handle_message(initialize, "admin", "acme", [], nil, nil, "Nahar Emet")

      assert instructions =~ ~s(Connected as "Nahar Emet")
      assert instructions =~ ~s(Your agent name this session: "nahar_emet_)
      assert instructions =~ "user_name + pool"
      assert instructions =~ "pass it as agent_id on task tools"
    end

    test "coding get_started returns human connected_user and qualified your_agent_id" do
      initialize = %{
        "jsonrpc" => "2.0",
        "id" => 41,
        "method" => "initialize",
        "params" => %{"clientInfo" => %{"name" => "cursor", "version" => "1"}}
      }

      assert {:ok, %{"result" => _}} =
               Protocol.handle_message(initialize, "admin", "acme", [], nil, nil, "Nahar Emet")

      call = %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "method" => "tools/call",
        "params" => %{"name" => "get_started", "arguments" => %{}}
      }

      assert {:ok, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Protocol.handle_message(call, "admin", "acme", [], nil, nil, "Nahar Emet")

      decoded = Jason.decode!(text)
      assert decoded["connected_user"] == "Nahar Emet"
      assert decoded["authenticated_as"] == "Nahar Emet"
      assert decoded["your_agent_id"] =~ ~r/^nahar_emet_/
      assert decoded["agent_identity"] =~ "user + pool"
      assert decoded["get_started"] =~ ~s(Connected user: "Nahar Emet")
      assert decoded["get_started"] =~ ~r/ACS uses "nahar_emet_/
    end

    test "sessions of the same user resolve the same stable qualified agent name" do
      alias Acs.MCP.ClientSession

      session_a = "sess_qual_a_#{System.unique_integer([:positive])}"
      session_b = "sess_qual_b_#{System.unique_integer([:positive])}"

      name_a =
        ClientSession.bind(session_a, fn ->
          ClientSession.get_or_assign_qualified_agent_name("Nahar Emet")
        end)

      name_b =
        ClientSession.bind(session_b, fn ->
          ClientSession.get_or_assign_qualified_agent_name("Nahar Emet")
        end)

      assert name_a =~ ~r/^nahar_emet_/
      assert name_b == name_a
    end
  end
end
