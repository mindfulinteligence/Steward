defmodule AcsWeb.McpUrls do
  @moduledoc """
  Public MCP SSE connector URLs for the dashboard.

  Symmetric paths:

  - `/mcp/coding/sse` — Cursor, Claude Code, OpenCode
  - `/mcp/chat/sse` — Claude.ai, ChatGPT

  `/mcp/sse` remains a coding alias (OAuth API identifier).
  """

  @coding_path "/mcp/coding/sse"
  @chat_path "/mcp/chat/sse"
  @chat_system_prompt_body_file "prompts/chat_system_prompt_body.md"
  @coding_system_prompt_file "prompts/coding_system_prompt.md"

  @chat_always_intro """
  # Steward ACS — Always Active

  Before doing a task, or when you need org or process knowledge, call `steward_ask()` and follow its guidance packet. Save durable results with `steward_write`. Never use `tool_search`. Don't ask whether to use Steward.
  """

  @chat_opt_in_intro """
  # Steward ACS — Opt In

  Ask the user at the start of each conversation whether to use Steward; if they decline, ignore this prompt. Before doing a task, or when you need org or process knowledge, call `steward_ask()` and follow its guidance packet. Save durable results with `steward_write`. Never use `tool_search`.
  """

  @type endpoint :: %{
          id: String.t(),
          copy_status_id: String.t(),
          audience: String.t(),
          title: String.t(),
          clients: String.t(),
          path: String.t(),
          url: String.t()
        }

  @type chat_prompt_mode :: :always | :opt_in

  @doc """
  Paste into Claude.ai / ChatGPT connector custom instructions.

  Modes:
  - `:always` (default) — Steward available; call when starting a task or needing org knowledge
  - `:opt_in` — ask the user before using Steward

  Mandate-only paste; workflow detail lives in the `steward_ask()` guidance packet.
  Optional shared body: `priv/prompts/chat_system_prompt_body.md` (usually empty).
  """
  @spec chat_system_prompt() :: String.t()
  @spec chat_system_prompt(chat_prompt_mode()) :: String.t()
  def chat_system_prompt(mode \\ :always)

  def chat_system_prompt(:always), do: compose_chat_prompt(@chat_always_intro)
  def chat_system_prompt(:opt_in), do: compose_chat_prompt(@chat_opt_in_intro)
  def chat_system_prompt(_), do: chat_system_prompt(:always)

  defp compose_chat_prompt(intro) do
    body =
      read_prompt(Path.join(:code.priv_dir(:steward_acs), @chat_system_prompt_body_file)) || ""

    [String.trim(intro), body]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Paste into the project's `AGENTS.md` (or agent rules file).

  Prefers repo-root `AGENTS_STEWARD.md` in dev; falls back to
  `priv/prompts/coding_system_prompt.md` in releases.
  """
  @spec coding_system_prompt() :: String.t()
  def coding_system_prompt do
    [
      Path.join(File.cwd!(), "AGENTS_STEWARD.md"),
      Path.join(:code.priv_dir(:steward_acs), @coding_system_prompt_file)
    ]
    |> Enum.find_value("", &read_prompt/1)
  end

  @doc "One paste that lets a coding agent configure the current project for this organization."
  @spec project_setup_prompt(URI.t() | nil) :: String.t()
  def project_setup_prompt(uri \\ nil) do
    organization_url = base_url(uri)
    mcp_url = organization_url <> "/mcp/sse"

    """
    Set up Steward for the project in your current working directory.

    Organization URL: #{organization_url}
    Coding MCP URL: #{mcp_url}
    MCP server name: steward

    Do the setup now:
    1. Inspect the repository and its existing agent/MCP files. Preserve all existing instructions and MCP servers.
    2. Configure a project-local MCP server named `steward` at `#{mcp_url}` using this coding client's native format. Use URL/OAuth only—do not add API keys or headers. If only a user-level MCP configuration is supported, explain that before changing files outside this project.
    3. Create or update `AGENTS_STEWARD.md` from the instruction block below. Replace `Repo: steward_acs` with `Repo: <this repository's name>` after verifying the repository root with `git rev-parse --show-toplevel`.
    4. Ensure the root `AGENTS.md` contains: `Check if @AGENTS_STEWARD.md exists. If yes, follow the instructions there.` Do not replace unrelated project instructions.
    5. Validate every configuration file you changed. Do not commit secrets. The organization URL and agent instructions are safe to commit.
    6. Tell me which files changed and the exact restart/reconnect step. After I complete browser OAuth and reconnect, call `get_started(audience: "coding")` to verify the organization and tools.

    --- BEGIN AGENTS_STEWARD.md ---
    #{coding_system_prompt()}
    --- END AGENTS_STEWARD.md ---
    """
    |> String.trim()
  end

  defp read_prompt(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> nil
          trimmed -> trimmed
        end

      {:error, _} ->
        nil
    end
  end

  @doc false
  @spec endpoints(URI.t() | nil) :: [endpoint()]
  def endpoints(uri \\ nil) do
    base = base_url(uri)

    [
      %{
        id: "mcp-coding-url",
        copy_status_id: "mcp-coding-copy-status",
        audience: "coding",
        title: "Coding",
        clients: "Cursor, Claude Code, OpenCode",
        path: @coding_path,
        url: base <> @coding_path
      },
      %{
        id: "mcp-chat-url",
        copy_status_id: "mcp-chat-copy-status",
        audience: "chat",
        title: "Chat",
        clients: "Claude.ai, ChatGPT",
        path: @chat_path,
        url: base <> @chat_path
      }
    ]
  end

  defp base_url(%URI{host: host} = uri) when is_binary(host) and host != "" do
    build_base(uri.scheme || endpoint_scheme(), host, uri.port)
  end

  defp base_url(_uri) do
    case Application.get_env(:steward_acs, :mcp_public_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        build_base(endpoint_scheme(), default_host(), endpoint_port())
    end
  end

  defp default_host do
    cond do
      Acs.Org.multi_tenant?() and is_binary(Acs.Org.base_domain()) ->
        "#{Acs.Org.current()}.#{Acs.Org.base_domain()}"

      true ->
        configured_host()
    end
  end

  defp configured_host do
    account_host = Application.get_env(:steward_acs, :account_host)
    endpoint_host = endpoint_url_config() |> Keyword.get(:host)

    Enum.find([account_host, endpoint_host, "localhost"], "localhost", &valid_host?/1)
  end

  defp build_base(scheme, host, port) do
    scheme = normalize_scheme(scheme)
    port = normalize_port(port, scheme)

    %URI{scheme: scheme, host: host, port: port}
    |> URI.to_string()
    |> String.trim_trailing("/")
  end

  defp endpoint_scheme do
    endpoint_url_config() |> Keyword.get(:scheme, "http") |> normalize_scheme()
  end

  defp endpoint_port do
    endpoint_url_config()
    |> Keyword.get(:port)
    |> then(&(&1 || listener_port()))
  end

  defp listener_port do
    Application.get_env(:steward_acs, AcsWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, 4001)
  end

  defp endpoint_url_config do
    Application.get_env(:steward_acs, AcsWeb.Endpoint, []) |> Keyword.get(:url, [])
  end

  defp normalize_scheme(scheme) when scheme in ["https", :https], do: "https"
  defp normalize_scheme(_), do: "http"

  defp normalize_port(nil, _), do: nil
  defp normalize_port(port, "https") when port in [443, "443"], do: nil
  defp normalize_port(port, "http") when port in [80, "80"], do: nil
  defp normalize_port(port, _) when is_integer(port), do: port
  defp normalize_port(port, _) when is_binary(port), do: String.to_integer(port)

  defp valid_host?(host) when is_binary(host) do
    Regex.match?(~r/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/i, host)
  end

  defp valid_host?(_), do: false
end
