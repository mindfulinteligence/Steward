defmodule Acs.MCP.Protocol do
  @moduledoc """
  Model Context Protocol (MCP) JSON-RPC message handling.

  Injects authentication context (`_auth_role`, `_auth_org_id`, `_auth_permissions`)
  into tool call arguments. `_auth_permissions` is always set (may be nil if the auth
  strategy doesn't provide permissions). Downstream RBAC enforcement in ToolRegistry
  checks these values against tool-level role and permission requirements.
  """

  alias Acs.MCP.ToolRegistry

  @mcp_version "2024-11-05"
  @cross_org_read_only_tools ~w(query list_tasks get_logs query_memories list_error_traces)

  @doc """
  Processes a JSON-RPC message and returns the appropriate response.

  Accepts optional authentication context:
  - `agent_role` - Role assigned to the calling agent (required for `tools/list` and `tools/call`)
  - `agent_org_id` - Organization ID for the calling agent
  - `agent_permissions` - List of permission strings for the calling agent
    (used for permission-based RBAC, see `permissions` in YAML tool definitions)
  """
  @spec handle_message(String.t() | map(), binary() | nil, binary() | nil, list(String.t()) | nil) ::
          {:ok, map() | nil}
          | {:error, String.t()}

  def handle_message(
        message,
        agent_role \\ nil,
        agent_org_id \\ nil,
        agent_permissions \\ nil,
        agent_allowed_teams \\ nil,
        agent_allowed_projects \\ nil,
        agent_identity \\ nil,
        agent_authority_level \\ nil,
        agent_authority_sort_order \\ nil
      )

  def handle_message(
        message,
        agent_role,
        agent_org_id,
        agent_permissions,
        agent_allowed_teams,
        agent_allowed_projects,
        agent_identity,
        agent_authority_level,
        agent_authority_sort_order
      )
      when is_binary(message) do
    case Jason.decode(message) do
      {:ok, decoded} ->
        handle_message(
          decoded,
          agent_role,
          agent_org_id,
          agent_permissions,
          agent_allowed_teams,
          agent_allowed_projects,
          agent_identity,
          agent_authority_level,
          agent_authority_sort_order
        )

      {:error, reason} ->
        {:error, "Failed to parse JSON: #{inspect(reason)}"}
    end
  end

  def handle_message(
        %{"jsonrpc" => "2.0", "id" => id, "method" => method} = msg,
        agent_role,
        agent_org_id,
        agent_permissions,
        agent_allowed_teams,
        agent_allowed_projects,
        agent_identity,
        agent_authority_level,
        agent_authority_sort_order
      )
      when not is_nil(id) do
    params = msg["params"] || %{}

    handle_request(
      id,
      method,
      params,
      agent_role,
      agent_org_id,
      agent_permissions,
      agent_allowed_teams,
      agent_allowed_projects,
      agent_identity,
      agent_authority_level,
      agent_authority_sort_order
    )
  end

  def handle_message(
        %{"jsonrpc" => "2.0", "method" => method} = msg,
        _agent_role,
        _agent_org_id,
        _agent_permissions,
        _agent_allowed_teams,
        _agent_allowed_projects,
        _agent_identity,
        _agent_authority_level,
        _agent_authority_sort_order
      ) do
    params = msg["params"] || %{}
    handle_notification(method, params)
  end

  def handle_message(
        %{"jsonrpc" => "2.0"} = _msg,
        _agent_role,
        _agent_org_id,
        _agent_permissions,
        _agent_allowed_teams,
        _agent_allowed_projects,
        _agent_identity,
        _agent_authority_level,
        _agent_authority_sort_order
      ) do
    {:ok, error_response(nil, -32600, "Invalid Request", "Missing method")}
  end

  def handle_message(
        _msg,
        _agent_role,
        _agent_org_id,
        _agent_permissions,
        _agent_allowed_teams,
        _agent_allowed_projects,
        _agent_identity,
        _agent_authority_level,
        _agent_authority_sort_order
      ) do
    {:ok, error_response(nil, -32600, "Invalid Request", "Not a valid JSON-RPC 2.0 message")}
  end

  @doc """
  Builds a success JSON-RPC response.
  """
  def success_response(id, result) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }
  end

  @doc """
  Builds an error JSON-RPC response.
  """
  def error_response(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if data, do: Map.put(error, "data", data), else: error
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end

  defp handle_request(
         id,
         "initialize",
         params,
         _agent_role,
         _agent_org_id,
         _agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         agent_identity,
         _agent_authority_level,
         _agent_authority_sort_order
       ) do
    audience = Acs.MCP.ClientSession.remember_initialize(params || %{}, agent_identity)

    result = %{
      "protocolVersion" => @mcp_version,
      "capabilities" => server_capabilities(),
      "serverInfo" => server_info(),
      "instructions" => audience_instructions(audience, agent_identity)
    }

    {:ok, success_response(id, result)}
  end

  defp handle_request(
         id,
         "tools/list",
         _params,
         agent_role,
         agent_org_id,
         agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         agent_identity,
         _agent_authority_level,
         _agent_authority_sort_order
       ) do
    with :ok <- require_agent_role(agent_role) do
      audience = Acs.MCP.ClientSession.resolve_audience(agent_identity)

      tools =
        ToolRegistry.list_tools_mcp(agent_role, agent_org_id, agent_permissions, audience)

      Acs.Observability.AgentOps.log_tools_list(
        tools: tools,
        audience: audience,
        audience_source: Acs.MCP.ClientSession.resolve_audience_source(agent_identity),
        client_name: Acs.MCP.ClientSession.resolve_client_name(agent_identity),
        client_version: Acs.MCP.ClientSession.resolve_client_version(agent_identity),
        mcp_endpoint: Acs.MCP.ClientSession.resolve_mcp_endpoint(agent_identity),
        role: agent_role,
        org: agent_org_id,
        agent_id: agent_identity
      )

      {:ok, success_response(id, %{"tools" => tools})}
    else
      {:error, reason} ->
        {:ok, error_response(id, -32001, "Unauthorized", reason)}
    end
  end

  defp handle_request(
         id,
         "tools/call",
         params,
         agent_role,
         agent_org_id,
         agent_permissions,
         agent_allowed_teams,
         agent_allowed_projects,
         agent_identity,
         agent_authority_level,
         agent_authority_sort_order
       ) do
    with :ok <- require_agent_role(agent_role) do
      do_tools_call(
        id,
        params,
        agent_role,
        agent_org_id,
        agent_permissions,
        agent_allowed_teams,
        agent_allowed_projects,
        agent_identity,
        agent_authority_level,
        agent_authority_sort_order
      )
    else
      {:error, reason} ->
        {:ok, error_response(id, -32001, "Unauthorized", reason)}
    end
  end

  defp handle_request(
         id,
         "ping",
         _params,
         _agent_role,
         _agent_org_id,
         _agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         _agent_identity,
         _agent_authority_level,
         _agent_authority_sort_order
       ) do
    {:ok, success_response(id, %{})}
  end

  defp handle_request(
         id,
         method,
         _params,
         _agent_role,
         _agent_org_id,
         _agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         _agent_identity,
         _agent_authority_level,
         _agent_authority_sort_order
       ) do
    {:ok, error_response(id, -32601, "Method not found", method)}
  end

  defp handle_notification("initialized", _params), do: {:ok, nil}
  defp handle_notification("notifications/initialized", _params), do: {:ok, nil}
  defp handle_notification("shutdown", _params), do: {:ok, nil}
  defp handle_notification("$/cancelRequest", _params), do: {:ok, nil}
  defp handle_notification(_method, _params), do: {:ok, nil}

  defp require_agent_role(role) when is_binary(role) and role != "", do: :ok
  defp require_agent_role(_), do: {:error, "Missing authentication context"}

  defp analysis_org(name, params, credential_org, permissions) do
    if cross_org_tool_allowed?(name, params, credential_org, permissions) do
      requested_analysis_org(params)
    else
      credential_org
    end
  end

  defp cross_org_tool_allowed?(name, params, credential_org, permissions) do
    cross_org_tool_requested?(params, credential_org) and
      is_list(permissions) and "mcp:cross_org_analysis" in permissions and
      name in @cross_org_read_only_tools and Acs.MCP.Tools.has_tool?(name)
  end

  defp cross_org_tool_disallowed?(name, params, credential_org, permissions) do
    cross_org_tool_requested?(params, credential_org) and
      is_list(permissions) and "mcp:cross_org_analysis" in permissions and
      name not in @cross_org_read_only_tools
  end

  defp cross_org_tool_requested?(params, credential_org) do
    case requested_analysis_org(params) do
      requested_org when is_binary(requested_org) and requested_org != "" ->
        requested_org != credential_org

      _ ->
        false
    end
  end

  defp requested_analysis_org(params), do: params["analysis_org"] || params["_analysis_org_id"]

  defp do_tools_call(
         id,
         params,
         agent_role,
         agent_org_id,
         agent_permissions,
         agent_allowed_teams,
         agent_allowed_projects,
         agent_identity,
         agent_authority_level,
         agent_authority_sort_order
       ) do
    requested_name = params["name"]
    requested_arguments = params["arguments"] || %{}
    audience = Acs.MCP.ClientSession.resolve_audience(agent_identity)

    {name, requested_arguments} =
      if is_map(requested_arguments) do
        Acs.MCP.Tools.ChatSurface.normalize_legacy_call(
          requested_name,
          requested_arguments,
          audience
        )
      else
        {requested_name, requested_arguments}
      end

    resource_org =
      if is_map(requested_arguments),
        do: analysis_org(name, requested_arguments, agent_org_id, agent_permissions),
        else: agent_org_id

    coding_self_identify? =
      audience == :coding and not Acs.Org.multi_tenant?() and agent_role == "admin"

    coding_qualified_name? =
      audience == :coding and Acs.Org.multi_tenant?() and usable_agent_identity?(agent_identity)

    agent_id =
      cond do
        coding_self_identify? ->
          nil

        coding_qualified_name? ->
          Acs.MCP.ClientSession.get_or_assign_qualified_agent_name(agent_identity) ||
            agent_identity

        usable_agent_identity?(agent_identity) ->
          agent_identity

        true ->
          Acs.MCP.ClientSession.get_or_assign_agent_name()
      end

    attribution_id =
      cond do
        coding_self_identify? ->
          Acs.Org.usable_developer_name() || Acs.Org.developer_name()

        usable_agent_identity?(agent_identity) ->
          agent_identity

        true ->
          Acs.Org.developer_name()
      end

    auth_context = %{
      credential_org: agent_org_id,
      resource_org: resource_org,
      role: agent_role,
      permissions: agent_permissions,
      allowed_teams: agent_allowed_teams,
      allowed_projects: agent_allowed_projects,
      authority_level: agent_authority_level,
      authority_sort_order: agent_authority_sort_order,
      agent_id: agent_id,
      attribution_id: attribution_id,
      audience: audience,
      audience_source: Acs.MCP.ClientSession.resolve_audience_source(agent_identity),
      client_name: Acs.MCP.ClientSession.resolve_client_name(agent_identity),
      working_repo: Acs.MCP.ClientSession.resolve_working_repo(agent_identity),
      workspace_id: Acs.MCP.ClientSession.resolve_workspace_id(agent_identity),
      mcp_endpoint: Acs.MCP.ClientSession.resolve_mcp_endpoint(agent_identity)
    }

    cond do
      not is_binary(name) or name == "" ->
        {:ok, error_response(id, -32602, "Invalid params", "Missing 'name' parameter")}

      not is_map(requested_arguments) ->
        {:ok, error_response(id, -32602, "Invalid params", "'arguments' must be an object")}

      cross_org_tool_disallowed?(name, requested_arguments, agent_org_id, agent_permissions) ->
        Acs.Observability.Events.warning("MCP cross-org tool blocked: #{name}",
          action: name,
          status: "forbidden",
          org: resource_org,
          agent_id: agent_identity,
          role: agent_role,
          error_type: "cross_org_disallowed"
        )

        {:ok,
         success_response(id, %{
           "content" => [
             %{
               "type" => "text",
               "text" =>
                 "Error: \"Cross-organization analysis is only permitted for read-only tools\""
             }
           ],
           "isError" => true
         })}

      true ->
        case ToolRegistry.invoke(name, requested_arguments, auth_context) do
          {:ok, result} ->
            {:ok,
             success_response(id, %{
               "content" => [
                 %{"type" => "text", "text" => Jason.encode!(result, pretty: true)}
               ]
             })}

          {:error, reason} ->
            Acs.Observability.Events.warning("MCP tool unauthorized: #{name}",
              action: name,
              status: "forbidden",
              org: resource_org,
              agent_id: agent_identity,
              role: agent_role,
              error_type: String.slice(to_string(reason), 0, 200)
            )

            {:ok,
             success_response(id, %{
               "content" => [%{"type" => "text", "text" => "Error: #{inspect(reason)}"}],
               "isError" => true
             })}
        end
    end
  end

  defp server_capabilities do
    %{
      "tools" => %{
        "listChanged" => true,
        "progressiveDisclosure" => true
      }
    }
  end

  defp server_info do
    %{
      "name" => "Acs MCP Server",
      "version" => "0.1.0",
      "websiteUrl" => "https://stewardacs.xyz",
      "icons" => server_icons()
    }
  end

  # SEP-973 — clients that honor icons (Inspector, some hosts). Claude.ai
  # currently uses the apex-domain favicon instead; keep this for when it does.
  defp server_icons do
    for src <- icon_srcs() do
      %{"src" => src, "mimeType" => "image/png"}
    end
  end

  defp icon_srcs do
    [public_favicon_url(), favicon_data_uri()]
    |> Enum.reject(&is_nil/1)
  end

  defp public_favicon_url do
    case Application.get_env(:steward_acs, :mcp_public_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/") <> "/favicon.png"

      _ ->
        case System.get_env("PHX_HOST") do
          host when is_binary(host) and host != "" -> "https://" <> host <> "/favicon.png"
          _ -> nil
        end
    end
  end

  defp favicon_data_uri do
    path = Path.join(:code.priv_dir(:steward_acs), "static/favicon.png")

    case File.read(path) do
      {:ok, bin} -> "data:image/png;base64," <> Base.encode64(bin)
      _ -> nil
    end
  end

  defp audience_instructions(:chat, agent_identity) do
    base =
      """
      ACS audience: chat. Tools: steward_ask, steward_write, steward_work — call by name; never tool_search. Before doing a task, or when you need org or process knowledge, call steward_ask() and follow its guidance packet. Save durable results with steward_write. Connect via /mcp/chat/sse.
      """
      |> String.trim()

    if usable_agent_identity?(agent_identity) do
      base <>
        " Connected ACS user: \"#{agent_identity}\". Omit agent_id on tool calls; never invent a nickname."
    else
      base
    end
  end

  defp audience_instructions(_coding, agent_identity) do
    base =
      """
      ACS audience: coding agent. Create/claim tasks, lock files before edits. Save before release: skill_save (how-to procedures), specs_propose for code specs OR documents (document_type + title + content), save_memory (short truths). Scopes may be code paths or business domains (org/domain/topic). Call get_started or generate_guidance_packet(scope_path:) when entering a new area. Connect via /mcp/sse.
      """
      |> String.trim()

    cond do
      not Acs.Org.multi_tenant?() ->
        owner =
          case Acs.Org.usable_developer_name() do
            name when is_binary(name) ->
              " Workspace owner: \"#{name}\" (attribution; use it when asking for this person's memories)."

            _ ->
              ""
          end

        base <>
          " Local mode: no default agent identity — register via get_present_status(agent_id: your_name) and pass that agent_id to task tools." <>
          owner

      usable_agent_identity?(agent_identity) ->
        agent_name =
          Acs.MCP.ClientSession.get_or_assign_qualified_agent_name(agent_identity) ||
            agent_identity

        base <>
          " Connected as \"#{agent_identity}\" (acs_dev_ developer_name or OAuth display name). Your agent name this session: \"#{agent_name}\" (user_name + pool) — pass it as agent_id on task tools. get_started returns connected_user — use that human name when asking for this person's memories."

      true ->
        base
    end
  end

  # Placeholder ACS_DEVELOPER_NAME / missing identity must not block the pool.
  defp usable_agent_identity?(id) when is_binary(id) do
    trimmed = String.trim(id)
    trimmed != "" and trimmed != "unknown"
  end

  defp usable_agent_identity?(_), do: false
end
