defmodule AcsWeb.DocsControllerTest do
  use AcsWeb.ConnCase, async: true

  test "serves human-facing connection documentation", %{conn: conn} do
    conn = get(conn, "/docs/install")

    assert html_response(conn, 200) =~ "Connect an agent"
    assert html_response(conn, 200) =~ "MCP-compatible agents"
  end

  test "explains Steward to people before the technical reference", %{conn: conn} do
    conn = get(conn, "/docs/overview")

    body = html_response(conn, 200)
    assert body =~ "shared operating system for AI agents"
    assert body =~ "Why teams use it"
    assert body =~ "How it fits"
  end

  test "redirects unknown pages to the overview", %{conn: conn} do
    assert redirected_to(get(conn, "/docs/not-a-page")) == "/docs/overview"
  end
end
