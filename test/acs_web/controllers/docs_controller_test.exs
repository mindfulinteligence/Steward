defmodule AcsWeb.DocsControllerTest do
  use AcsWeb.ConnCase, async: true

  test "serves human-facing connection documentation", %{conn: conn} do
    conn = get(conn, "/docs/install")

    body = html_response(conn, 200)
    assert body =~ "Install a private Steward instance"
    assert body =~ "http://localhost:4001/mcp/v1/messages"
  end

  test "explains Steward to people before the technical reference", %{conn: conn} do
    conn = get(conn, "/docs/overview")

    body = html_response(conn, 200)
    assert body =~ "Set up Steward for your team"
    assert body =~ "https://&lt;workspace-host&gt;/mcp/sse"
    assert body =~ "What the agent instructions must enforce"
  end

  test "redirects unknown pages to the overview", %{conn: conn} do
    assert redirected_to(get(conn, "/docs/not-a-page")) == "/docs/overview"
  end

  test "release image includes every external documentation source" do
    dockerfile = File.read!("Dockerfile")
    dockerignore = File.read!(".dockerignore")

    assert dockerfile =~ "COPY guides guides"
    assert dockerfile =~ "COPY README.md README.md"
    refute dockerignore =~ ~r/^guides$/m
  end
end
