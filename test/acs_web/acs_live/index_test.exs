defmodule AcsWeb.AcsLive.IndexTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AcsWeb.AcsLive.Index

  setup do
    original = Application.get_env(:steward_acs, :mcp_public_url)
    Application.put_env(:steward_acs, :mcp_public_url, "https://prod.stewardacs.xyz")

    on_exit(fn ->
      Application.put_env(:steward_acs, :mcp_public_url, original)
    end)

    :ok
  end

  test "shows symmetric MCP connector URLs once in a compact disclosure" do
    html = render_dashboard()

    assert html =~ ~s(id="mcp-connectors")
    assert html =~ "Agent URLs"
    assert html =~ "/mcp/coding/sse"
    assert html =~ "/mcp/chat/sse"
    assert html =~ "https://prod.stewardacs.xyz/mcp/coding/sse"
    assert html =~ "https://prod.stewardacs.xyz/mcp/chat/sse"
    assert html =~ "Cursor, Claude Code, OpenCode"
    assert html =~ "Claude.ai, ChatGPT"
    assert html =~ "Paste into Claude system prompt"
    assert html =~ "Always Active — use when needed"
    assert html =~ "Opt In — ask before using Steward"
    assert html =~ "Copy Always Active"
    assert html =~ "Copy Opt In"
    assert html =~ "Copy this into your AGENTS.md"
    assert html =~ "Copy project setup prompt"
    assert html =~ "https://prod.stewardacs.xyz/mcp/sse"
    assert html =~ ~s(id="copy-project-setup-prompt")
    assert html =~ ~s(id="copy-chat-always-system-prompt")
    assert html =~ ~s(id="copy-chat-opt-in-system-prompt")
    assert html =~ ~s(id="copy-coding-coding-system-prompt")
    assert html =~ "Steward ACS — Always Active"
    assert html =~ "Steward ACS — Opt In"
    assert html =~ "Steward ACS — Agent Instructions"
    # One disclosure only — no duplicated connector blocks
    assert length(Regex.scan(~r/id="mcp-connectors"/, html)) == 1
    assert length(Regex.scan(~r/id="mcp-coding-url"/, html)) == 1
    assert length(Regex.scan(~r/id="mcp-chat-url"/, html)) == 1
  end

  test "guides an empty workspace through first-time setup" do
    html = render_dashboard()

    assert html =~ "Workspace overview"
    assert html =~ "Connect your first agent"
    assert html =~ "Configure MCP"
    assert html =~ "View tools"
    assert html =~ "dismiss-getting-started"
  end

  test "hides getting started after it has been dismissed" do
    html = render_dashboard(getting_started_dismissed: true)

    refute html =~ "Connect your first agent"
    refute html =~ "dismiss-getting-started"
    assert html =~ ~s(id="mcp-connectors")
    assert html =~ "Agent URLs"
    refute html =~ ~r/<details[^>]*id="mcp-connectors"[^>]*\bopen\b/
  end

  test "opens connector URLs during first-time setup" do
    html = render_dashboard(getting_started_dismissed: false)

    assert html =~ "Connect your first agent"
    assert html =~ ~r/<details[^>]*id="mcp-connectors"[^>]*\bopen\b/
  end

  test "explains a filtered empty task list and offers to clear it" do
    html = render_dashboard(selected_status: "in_progress")

    assert html =~ "No in progress tasks"
    assert html =~ "No tasks match the current status filter."
    assert html =~ "Clear filter"
  end

  defp render_dashboard(overrides \\ []) do
    assigns =
      Map.merge(
        %{
          agent_status: %{},
          tasks: [],
          locked_files: [],
          selected_status: "all",
          can_reset_data: false,
          getting_started_dismissed: false,
          mcp_endpoints: AcsWeb.McpUrls.endpoints(),
          chat_system_prompt: AcsWeb.McpUrls.chat_system_prompt(:always),
          chat_system_prompt_opt_in: AcsWeb.McpUrls.chat_system_prompt(:opt_in),
          coding_system_prompt: AcsWeb.McpUrls.coding_system_prompt(),
          project_setup_prompt: AcsWeb.McpUrls.project_setup_prompt()
        },
        Map.new(overrides)
      )

    render_component(&Index.render/1, assigns)
  end
end
