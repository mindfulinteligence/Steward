defmodule AcsWeb.DocsControllerTest do
  use AcsWeb.ConnCase, async: true

  test "serves public documentation", %{conn: conn} do
    conn = get(conn, "/docs/install")

    assert html_response(conn, 200) =~ "ACS Installer Guide"
    assert html_response(conn, 200) =~ "Default Config"
  end

  test "explains Steward to people before the technical reference", %{conn: conn} do
    conn = get(conn, "/docs/overview")

    body = html_response(conn, 200)
    assert body =~ "shared operating system for AI agents"
    assert body =~ "Connect a coding agent"
    assert body =~ "How this helps a team"
  end

  test "redirects unknown pages to the overview", %{conn: conn} do
    assert redirected_to(get(conn, "/docs/not-a-page")) == "/docs/overview"
  end
end
