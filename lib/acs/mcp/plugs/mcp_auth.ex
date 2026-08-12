defmodule Acs.MCP.Plugs.MCPAuth do
  @moduledoc """
  Authentication plug for the ACS MCP HTTP server.

  Uses a configurable chain of authentication strategies.
  Strategies are defined in `:auth_strategies` config key (list of module names).
  Default: `[Acs.MCP.Plugs.Strategies.Developer, Acs.MCP.Plugs.Strategies.Default]`

  Each strategy is tried in order until one returns `{:ok, ...}`.
  If all fail, returns 401.

  Log ingestion (`/api/logs/ingest`) requires `X-Log-Ingest-Key` matching
  `:log_ingest_key` config.

  Sets `conn.assigns.agent_role`, `conn.assigns.agent_org_id`,
  `conn.assigns.agent_permissions`, and
  `conn.assigns.agent_identity` on success.
  """
  import Plug.Conn
  require Logger

  @default_strategies [
    Acs.MCP.Plugs.Strategies.Developer,
    Acs.MCP.Plugs.Strategies.Default
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      health_check?(conn) ->
        conn

      String.starts_with?(conn.request_path, "/api/logs/ingest") ->
        authenticate_log_ingest(conn)

      true ->
        conn = fetch_query_params(conn)
        key = extract_key(conn)
        strategies = auth_strategies()

        case authenticate_with_strategies(key, conn, strategies) do
          {:ok, result} ->
            with {:ok, result} <- authorize_oidc_user(result, conn.assigns[:current_org]),
                 {:ok, org_id} <- resolve_org(result.org_id, conn.assigns[:current_org]) do
              :ok = Acs.Org.put_current(org_id)

              authority_sort_order =
                resolve_authority_sort_order(org_id, result.role, result[:authority_level_slug])

              Process.put(:acs_mcp_authority_level, result[:authority_level_slug])
              Process.put(:acs_mcp_authority_sort_order, authority_sort_order)

              Acs.Observability.Events.put_context(
                org: org_id,
                agent_id: result[:agent_identity],
                role: result.role,
                request_id: conn_request_id(conn)
              )

              # Success is high-frequency on MCP; metadata context is enough for Axiom.
              Logger.debug("MCP auth ok",
                action: "auth_ok",
                status: "ok",
                org: org_id,
                agent_id: result[:agent_identity],
                role: result.role
              )

              conn
              |> assign(:agent_role, result.role)
              |> assign(:agent_org_id, org_id)
              |> assign(:agent_permissions, result.permissions)
              |> assign(:agent_allowed_teams, result[:allowed_teams])
              |> assign(:agent_allowed_projects, result[:allowed_projects])
              |> assign(:agent_identity, result[:agent_identity])
              |> assign(:agent_kind, result[:kind] || "code")
              |> assign(:agent_authority_level, result[:authority_level_slug])
              |> assign(:agent_authority_sort_order, authority_sort_order)
            else
              {:error, reason} -> unauthorized(conn, reason)
            end

          {:error, reason} ->
            unauthorized(conn, reason)
        end
    end
  end

  defp resolve_org(auth_org, request_org) do
    configured = Acs.Org.configured()

    cond do
      is_binary(auth_org) and auth_org != "" and request_org in [nil, "default", configured] ->
        {:ok, auth_org}

      is_binary(auth_org) and auth_org != "" and auth_org == request_org ->
        {:ok, auth_org}

      is_binary(auth_org) and auth_org != "" ->
        Logger.warning("MCP org mismatch",
          action: "org_resolve",
          status: "mismatch",
          org: request_org,
          error_type: "org_mismatch"
        )

        {:error, "Authenticated organization does not match request host"}

      request_org in [nil, "default", configured] ->
        {:ok, configured}

      true ->
        Logger.warning("MCP org credential not scoped",
          action: "org_resolve",
          status: "forbidden",
          org: request_org,
          error_type: "org_not_scoped"
        )

        {:error, "This credential is not scoped for the requested organization"}
    end
  end

  defp authorize_oidc_user(
         %{oidc_issuer: issuer, oidc_subject: subject} = result,
         request_org
       )
       when is_binary(issuer) and issuer != "" and is_binary(subject) and subject != "" do
    if accounts_authorization_available?() do
      case resolve_oidc_user(issuer, subject, result, request_org) do
        nil ->
          {:error, "OAuth user is not authorized for this organization"}

        user ->
          authorize_local_user(result, user, request_org)
      end
    else
      {:error, "OAuth user authorization is unavailable"}
    end
  end

  defp authorize_oidc_user(result, _request_org), do: {:ok, result}

  # Web/Claude may use email OTP or Google (different Auth0 `sub`). Fall back to
  # verified email within the request org.
  defp resolve_oidc_user(issuer, subject, result, request_org) do
    case Acs.Accounts.get_user_by_oidc_identity(issuer, subject) do
      %{id: _} = user ->
        user

      nil ->
        email = result[:email] || result["email"]

        if is_binary(email) and email != "" and
             function_exported?(Acs.Accounts, :get_user_by_email, 2) do
          Acs.Accounts.get_user_by_email(email, resolved_request_org(request_org))
        else
          nil
        end
    end
  end

  defp authorize_local_user(result, user, request_org) do
    request_org = resolved_request_org(request_org)

    case Acs.Accounts.organization_for_user(user) do
      org when is_map(org) ->
        with "ready" <- Map.get(org, :provisioning_status),
             slug when is_binary(slug) and slug == request_org <- Map.get(org, :slug),
             {:ok, role} <- oidc_role(Map.get(user, :org_role), result.permissions) do
          # Prefer human name over Auth0 sub (email|…) / raw email for agent roster.
          # Merge, not update syntax: strategies may omit :authority_level_slug entirely.
          {:ok,
           Map.merge(result, %{
             role: role,
             org_id: slug,
             agent_identity: Acs.Accounts.User.display_name(user),
             authority_level_slug: Map.get(user, :authority_level_slug)
           })}
        else
          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          _ ->
            {:error, "OAuth user is not authorized for this organization"}
        end

      _ ->
        {:error, "OAuth user is not authorized for this organization"}
    end
  end

  defp accounts_authorization_available? do
    Code.ensure_loaded?(Acs.Accounts) and
      function_exported?(Acs.Accounts, :get_user_by_oidc_identity, 2) and
      function_exported?(Acs.Accounts, :organization_for_user, 1)
  end

  defp resolved_request_org(nil), do: Acs.Org.configured()
  defp resolved_request_org(org), do: org

  defp oidc_role(org_role, permissions) when is_list(permissions) do
    with {:ok, local_role} <- local_oidc_role(org_role),
         {:ok, token_role} <- token_oidc_role(permissions) do
      if local_role == :admin and token_role == :admin do
        {:ok, "admin"}
      else
        {:ok, "collaborator"}
      end
    end
  end

  defp oidc_role(_, _), do: {:error, "OAuth token is missing MCP permissions"}

  defp local_oidc_role(role) when role in ["owner", "admin"], do: {:ok, :admin}
  defp local_oidc_role("member"), do: {:ok, :collaborator}
  defp local_oidc_role(_), do: {:error, "OAuth user is not authorized for this organization"}

  defp token_oidc_role(permissions) do
    cond do
      "mcp:admin" in permissions -> {:ok, :admin}
      "mcp:tools" in permissions -> {:ok, :collaborator}
      true -> {:error, "OAuth token is missing MCP permissions"}
    end
  end

  defp authenticate_log_ingest(conn) do
    expected = Application.get_env(:steward_acs, :log_ingest_key)

    ingest_key =
      case get_req_header(conn, "x-log-ingest-key") do
        [key | _] when is_binary(key) and key != "" -> key
        _ -> nil
      end

    cond do
      is_nil(expected) or expected == "" ->
        unauthorized(conn, "Log ingest is not configured")

      is_nil(ingest_key) ->
        unauthorized(conn, "Missing X-Log-Ingest-Key header")

      secure_compare(ingest_key, expected) ->
        org_id = conn.assigns[:current_org] || Acs.Org.current()
        :ok = Acs.Org.put_current(org_id)

        Acs.Observability.Events.put_context(
          org: org_id,
          agent_id: "service",
          role: "service",
          request_id: conn_request_id(conn)
        )

        conn
        |> assign(:agent_role, "service")
        |> assign(:agent_org_id, org_id)
        |> assign(:agent_permissions, nil)
        |> assign(:agent_identity, "service")

      true ->
        unauthorized(conn, "Invalid log ingest key")
    end
  end

  defp health_check?(conn) do
    conn.method == "GET" and conn.request_path == "/mcp/health"
  end

  defp extract_key(conn) do
    conn
    |> header_api_key()
    |> case do
      key when is_binary(key) -> key
      _ -> bearer_api_key(conn) || query_api_key(conn)
    end
  end

  defp header_api_key(conn) do
    case get_req_header(conn, "x-api-key") do
      [key | _] when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp bearer_api_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key | _] when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp query_api_key(conn) do
    if query_key_auth_enabled?() do
      case conn.query_params["api_key"] do
        key when is_binary(key) and key != "" -> key
        _ -> nil
      end
    else
      nil
    end
  end

  defp query_key_auth_enabled? do
    Application.get_env(:steward_acs, :mcp_query_key_auth, false)
  end

  defp auth_strategies do
    case Application.get_env(:steward_acs, :auth_strategies) do
      strategies when is_list(strategies) -> strategies
      _ -> @default_strategies
    end
  end

  defp authenticate_with_strategies(_key, _conn, []) do
    {:error, "Missing or invalid API key"}
  end

  defp authenticate_with_strategies(key, conn, [strategy | rest]) do
    case strategy.authenticate(key, conn) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> authenticate_with_strategies(key, conn, rest)
    end
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_compare(_, _), do: false

  defp unauthorized(conn, reason) do
    body = Jason.encode!(%{error: reason})

    Logger.warning("MCP auth failed: #{reason}",
      action: "auth_fail",
      status: "401",
      error_type: String.slice(to_string(reason), 0, 200),
      org: conn.assigns[:current_org] || conn.assigns[:agent_org_id],
      agent_id: conn.assigns[:agent_identity],
      request_id: conn_request_id(conn)
    )

    conn =
      conn
      |> maybe_put_oauth_challenge()
      |> put_resp_content_type("application/json")

    conn
    |> send_resp(401, body)
    |> halt()
  end

  defp conn_request_id(conn) do
    case conn.assigns[:request_id] || Plug.Conn.get_resp_header(conn, "x-request-id") do
      id when is_binary(id) and id != "" -> id
      [id | _] when is_binary(id) and id != "" -> id
      _ -> Logger.metadata()[:request_id]
    end
  end

  defp maybe_put_oauth_challenge(conn) do
    alias Acs.MCP.OAuth.Config

    case {Config.enabled?(), Config.protected_resource_metadata_url(conn)} do
      {true, url} when is_binary(url) ->
        challenge = ~s(Bearer error="invalid_token", resource_metadata="#{url}")
        Plug.Conn.put_resp_header(conn, "www-authenticate", challenge)

      _ ->
        conn
    end
  end

  # Clearance from the principal's authority_level_slug (OAuth user or API key).
  # Role never bypasses — missing slug → org lowest.
  defp resolve_authority_sort_order(org, _role, slug) when is_binary(org) do
    Acs.AuthorityLevels.viewer_sort_order(org, slug)
  end

  defp resolve_authority_sort_order(_, _, _), do: nil
end
