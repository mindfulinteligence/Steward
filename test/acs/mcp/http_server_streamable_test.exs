defmodule Acs.MCP.HTTPServerStreamableTest do
  use Acs.DataCase, async: false

  alias Acs.Developers
  alias Acs.MCP.HTTPServer

  test "POST /mcp/chat/sse accepts Streamable HTTP JSON-RPC (not 404)" do
    {:ok, %{key: raw_key}} =
      Developers.generate_key("streamable-chat-test", role: "admin", org: "dev")

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0.0.1"}
        }
      })

    conn =
      Plug.Test.conn(:post, "/mcp/chat/sse", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", raw_key)
      |> HTTPServer.call([])

    refute conn.status == 404
    assert conn.status in [200, 202]
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
  end

  test "x-mcp-session-id header keeps the session sticky across requests" do
    {:ok, %{key: raw_key}} =
      Developers.generate_key("streamable-sticky-test", role: "admin", org: "dev")

    initialize_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0.0.1"}
        }
      })

    first =
      Plug.Test.conn(:post, "/mcp/coding/sse", initialize_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", raw_key)
      |> HTTPServer.call([])

    assert first.status in [200, 202]
    session_id = get_resp_header(first, "x-mcp-session-id") |> List.first()
    assert is_binary(session_id) and session_id != ""

    # A client that echoes the session header back must keep the same session,
    # so per-session state (e.g. the qualified agent name) does not rotate.
    second =
      Plug.Test.conn(:post, "/mcp/coding/sse", initialize_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", raw_key)
      |> Plug.Conn.put_req_header("x-mcp-session-id", session_id)
      |> HTTPServer.call([])

    assert second.status in [200, 202]
    assert get_resp_header(second, "x-mcp-session-id") |> List.first() == session_id
  end

  test "GET /mcp/v1/messages returns 405 so clients do not treat it as a dead session" do
    {:ok, %{key: raw_key}} =
      Developers.generate_key("streamable-get-test", role: "admin", org: "dev")

    conn =
      Plug.Test.conn(:get, "/mcp/v1/messages")
      |> Plug.Conn.put_req_header("x-api-key", raw_key)
      |> HTTPServer.call([])

    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST"]
  end

  test "chat-kind developer key seeds chat audience on a non-audience URL" do
    {:ok, %{key: raw_key}} =
      Developers.generate_key("streamable-kind-chat", role: "admin", org: "dev", kind: "chat")

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0.0.1"}
        }
      })

    conn =
      Plug.Test.conn(:post, "/mcp/sse", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", raw_key)
      |> HTTPServer.call([])

    assert conn.status in [200, 202]
    session_id = get_resp_header(conn, "x-mcp-session-id") |> List.first()
    assert is_binary(session_id) and session_id != ""

    assert {:ok, %{audience: :chat, audience_source: :url}} =
             Acs.MCP.ClientSession.fetch(session_id)
  end

  test "code-kind developer key seeds coding audience on a non-audience URL" do
    {:ok, %{key: raw_key}} =
      Developers.generate_key("streamable-kind-code", role: "admin", org: "dev", kind: "code")

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0.0.1"}
        }
      })

    conn =
      Plug.Test.conn(:post, "/mcp/sse", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", raw_key)
      |> HTTPServer.call([])

    assert conn.status in [200, 202]
    session_id = get_resp_header(conn, "x-mcp-session-id") |> List.first()

    assert {:ok, %{audience: :coding}} = Acs.MCP.ClientSession.fetch(session_id)
  end

  defp get_resp_header(conn, key), do: Plug.Conn.get_resp_header(conn, key)
end
