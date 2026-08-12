defmodule Acs.MCP.Plugs.Strategies.Developer do
  @moduledoc """
  Authentication strategy for ACS developer API keys.

  Keys start with `acs_dev_` prefix and are validated against
  the `Acs.Developers` context which stores SHA-256 hashes.

  The `org_id` field in the result carries the
  org label from the developer key, validated against the
  subdomain org when multi-tenancy is active.
  """
  @behaviour Acs.MCP.Plugs.AuthStrategy
  require Logger

  @key_prefix "acs_dev_"

  @impl true
  def authenticate(key, conn) do
    if is_binary(key) and String.starts_with?(key, @key_prefix) do
      case Acs.Developers.authenticate(key) do
        {:ok, result} ->
          key_org = result.org
          subdomain_org = conn.assigns[:current_org]

          if subdomain_org && subdomain_org != "default" && key_org != subdomain_org do
            {:error,
             "Developer key org '#{key_org}' does not match subdomain org '#{subdomain_org}'"}
          else
            Logger.debug(
              "[MCPAuth] authenticated via developer key: role=#{result.role} org=#{key_org}"
            )

            {:ok,
             %{
               role: result.role,
               org_id: key_org,
               permissions: [],
               kind: result[:kind] || "code",
               agent_identity: result.developer_name,
               authority_level_slug: result[:authority_level_slug] || "standard",
               allowed_teams: result[:allowed_teams],
               allowed_projects: result[:allowed_projects]
             }}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "Not a developer key"}
    end
  end
end
