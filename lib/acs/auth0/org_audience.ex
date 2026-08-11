defmodule Acs.Auth0.OrgAudience do
  @moduledoc """
  Ensures an Auth0 API (resource server) exists for each tenant MCP audience.

  Caddy injects `audience=https://{host}/mcp/sse` on `/authorize`. Self-serve
  orgs never appeared in `priv/orgs.yaml`, so Auth0 returned "Service not found"
  until someone ran `scripts/ensure-auth0-org-audiences.sh` by hand.

  Called from `Acs.Orgs.Provisioner` when Management API creds are configured.
  Best-effort: failures are logged; provisioning still succeeds.
  """

  require Logger

  alias Acs.Auth0.Management
  alias Acs.MCP.OAuth.Config, as: OAuthConfig

  @doc "Fire-and-forget ensure for a new or re-provisioned org slug."
  @spec ensure_async(String.t()) :: :ok
  def ensure_async(slug) when is_binary(slug) and slug != "" do
    if Management.configured?() do
      # ponytail: no GenServer — one-shot Task is enough; ceiling is Auth0 rate limits
      # on burst org creates. Upgrade: queue + backoff if we ever bulk-import tenants.
      Task.start(fn ->
        case ensure(slug) do
          :ok ->
            Logger.info("[Auth0.OrgAudience] ensured audience for org=#{slug}")

          {:error, reason} ->
            Logger.warning("[Auth0.OrgAudience] ensure failed org=#{slug}: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  def ensure_async(_), do: :ok

  @doc "Synchronously ensure Auth0 API + third-party grant + MCP role permissions."
  @spec ensure(String.t()) :: :ok | {:error, term()}
  def ensure(slug) when is_binary(slug) and slug != "" do
    with {:ok, cfg} <- Management.config(),
         {:ok, token} <- Management.token(cfg),
         true <- present_base_domain?(cfg),
         audience <- audience_for(slug, cfg.base_domain),
         {:ok, _} <- ensure_resource_server(cfg, token, audience),
         :ok <- ensure_third_party_grant(cfg, token, audience),
         :ok <- ensure_role_permissions(cfg, token, audience),
         :ok <- ensure_broker_callback(cfg, token, slug, cfg.base_domain) do
      :ok
    else
      false -> {:error, :mgmt_not_configured}
      other -> other
    end
  end

  def ensure(_), do: {:error, :invalid_slug}

  @doc false
  def audience_for(slug, base_domain)
      when is_binary(slug) and is_binary(base_domain) do
    "https://#{slug}.#{base_domain}/mcp/sse"
  end

  @doc false
  def broker_callback_url(slug, base_domain)
      when is_binary(slug) and is_binary(base_domain) do
    "https://#{slug}.#{base_domain}/oauth/callback"
  end

  defp present_base_domain?(%{base_domain: base}) when is_binary(base) do
    String.trim(base) != ""
  end

  defp present_base_domain?(_), do: false

  defp ensure_resource_server(cfg, token, audience) do
    case find_resource_server(cfg, token, audience) do
      {:ok, id} ->
        patch_resource_server(cfg, token, id)

      :not_found ->
        create_resource_server(cfg, token, audience)

      {:error, _} = err ->
        err
    end
  end

  defp find_resource_server(cfg, token, audience) do
    case Management.get(cfg, token, "/api/v2/resource-servers") do
      {:ok, list} when is_list(list) ->
        case Enum.find(list, &(Map.get(&1, "identifier") == audience)) do
          %{"id" => id} -> {:ok, id}
          _ -> :not_found
        end

      other ->
        other
    end
  end

  defp create_resource_server(cfg, token, audience) do
    body = %{
      name: "Steward ACS MCP (#{audience})",
      identifier: audience,
      signing_alg: "RS256",
      token_lifetime: 604_800,
      scopes: [%{value: "mcp:tools", description: "Call Steward ACS MCP tools"}],
      enforce_policies: true,
      token_dialect: "access_token_authz"
    }

    case Management.post(cfg, token, "/api/v2/resource-servers", body) do
      {:ok, %{"id" => id}} -> {:ok, id}
      other -> other
    end
  end

  defp patch_resource_server(cfg, token, id) do
    case Management.patch(cfg, token, "/api/v2/resource-servers/#{id}", %{
           enforce_policies: true,
           token_dialect: "access_token_authz"
         }) do
      {:ok, _} -> {:ok, id}
      other -> other
    end
  end

  defp ensure_third_party_grant(cfg, token, audience) do
    q = URI.encode_www_form(audience)

    case Management.get(cfg, token, "/api/v2/client-grants?audience=#{q}") do
      {:ok, grants} when is_list(grants) ->
        if Enum.any?(
             grants,
             &(&1["default_for"] == "third_party_clients" and &1["audience"] == audience)
           ) do
          :ok
        else
          case Management.post(cfg, token, "/api/v2/client-grants", %{
                 default_for: "third_party_clients",
                 audience: audience,
                 scope: ["mcp:tools"],
                 subject_type: "user"
               }) do
            {:ok, _} -> :ok
            other -> other
          end
        end

      other ->
        other
    end
  end

  defp ensure_role_permissions(cfg, token, audience) do
    case Management.get(cfg, token, "/api/v2/roles") do
      {:ok, roles} when is_list(roles) ->
        roles
        |> Enum.filter(&(&1["name"] in ["MCP User", "claude_mcp"]))
        |> Enum.each(fn %{"id" => role_id} ->
          _ =
            Management.post(cfg, token, "/api/v2/roles/#{role_id}/permissions", %{
              permissions: [
                %{
                  resource_server_identifier: audience,
                  permission_name: "mcp:tools"
                }
              ]
            })
        end)

        :ok

      other ->
        other
    end
  end

  # The broker relays every connector through the fixed DCR Auth0 client, so
  # Auth0 validates each org's broker callback (https://{slug}.{base}/oauth/callback)
  # against that client's allowlist. Without this, Claude connecting to a new
  # org host hits "Callback URL mismatch" at /authorize. Additive merge: other
  # connectors' callbacks are never removed.
  defp ensure_broker_callback(cfg, token, slug, base_domain) do
    with client_id when is_binary(client_id) <- OAuthConfig.fixed_dcr_client_id() do
      callback = broker_callback_url(slug, base_domain)

      case Management.get(
             cfg,
             token,
             "/api/v2/clients/#{client_id}?fields=callbacks&include_fields=true"
           ) do
        {:ok, %{"callbacks" => callbacks}} when is_list(callbacks) ->
          if callback in callbacks do
            :ok
          else
            case Management.patch(cfg, token, "/api/v2/clients/#{client_id}", %{
                   callbacks: [callback | callbacks]
                 }) do
              {:ok, _} -> :ok
              other -> other
            end
          end

        {:ok, _} ->
          :ok

        other ->
          other
      end
    else
      _ -> :ok
    end
  end
end
