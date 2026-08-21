defmodule AcsWeb.McpUrlsTest do
  use ExUnit.Case, async: true

  alias AcsWeb.McpUrls

  setup do
    original = Application.get_env(:steward_acs, :mcp_public_url)

    on_exit(fn ->
      Application.put_env(:steward_acs, :mcp_public_url, original)
    end)

    Application.put_env(:steward_acs, :mcp_public_url, "https://prod.stewardacs.xyz")
    :ok
  end

  test "symmetric coding and chat paths" do
    [coding, chat] = McpUrls.endpoints()

    assert coding.path == "/mcp/coding/sse"
    assert coding.url == "https://prod.stewardacs.xyz/mcp/coding/sse"

    assert chat.path == "/mcp/chat/sse"
    assert chat.url == "https://prod.stewardacs.xyz/mcp/chat/sse"
  end

  test "chat_system_prompt is mandate-only with different always vs opt-in intros" do
    always = McpUrls.chat_system_prompt(:always)
    opt_in = McpUrls.chat_system_prompt(:opt_in)
    default = McpUrls.chat_system_prompt()

    assert always == default
    assert always =~ "Steward ACS — Always Active"
    assert always =~ "Don't ask whether to use Steward"
    assert always =~ "Before doing a task, or when you need org or process knowledge"
    refute always =~ "Ask the user at the start of each conversation"
    refute always =~ "every turn"

    assert opt_in =~ "Steward ACS — Opt In"
    assert opt_in =~ "Ask the user at the start of each conversation"
    assert opt_in =~ "Before doing a task, or when you need org or process knowledge"
    refute opt_in =~ "Don't ask whether to use Steward"
    refute opt_in =~ "every turn"

    for prompt <- [always, opt_in] do
      assert prompt =~ "Never use `tool_search`"
      assert prompt =~ "`steward_ask()`"
      assert prompt =~ "`steward_write`"
      assert prompt =~ "guidance packet"
      refute prompt =~ "| Tool |"
      refute prompt =~ "`get_started`"
    end
  end

  test "coding_system_prompt loads AGENTS_STEWARD instructions" do
    prompt = McpUrls.coding_system_prompt()

    assert prompt =~ "Steward ACS — Agent Instructions"
    assert prompt =~ "get_present_status"
    assert prompt =~ "create_work"
  end

  test "project setup prompt carries the organization URL and safe merge workflow" do
    prompt = McpUrls.project_setup_prompt(URI.parse("https://acme.stewardacs.xyz/welcome"))

    assert prompt =~ "Organization URL: https://acme.stewardacs.xyz"
    assert prompt =~ "Coding MCP URL: https://acme.stewardacs.xyz/mcp/sse"
    assert prompt =~ "Preserve all existing instructions and MCP servers"
    assert prompt =~ "Create or update `AGENTS_STEWARD.md`"
    assert prompt =~ "Ensure the root `AGENTS.md` contains"
    assert prompt =~ "get_started(audience: \"coding\")"
    assert prompt =~ "Steward ACS — Agent Instructions"
    refute prompt =~ "x-api-key"
  end
end
