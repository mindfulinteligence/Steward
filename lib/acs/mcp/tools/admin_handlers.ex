defmodule Acs.MCP.Tools.AdminHandlers do
  @moduledoc """
  Handlers for admin-only MCP tools.
  """
  alias Acs.Developers
  require Logger

  def generate_key(args) do
    name = Map.get(args, "name") || Map.get(args, "developer_name")
    role = Map.get(args, "role", "collaborator")
    org = Map.get(args, "_auth_org_id", Acs.Org.current())

    cond do
      is_nil(name) or name == "" ->
        {:error, "name is required"}

      role not in ~w(admin service reader collaborator) ->
        {:error, "role must be one of: admin, service, reader, collaborator"}

      true ->
        case Developers.generate_key(name, role: role, org: org) do
          {:ok, %{key: raw_key, developer: dev}} ->
            {:ok,
             %{
               key: raw_key,
               key_prefix: dev.key_prefix,
               developer_name: dev.developer_name,
               role: dev.role,
               org: dev.org
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def list_keys(args) do
    org = Map.get(args, "_auth_org_id", Acs.Org.current())
    developers = Developers.list_developers(org)

    entries =
      Enum.map(developers, fn dev ->
        %{
          developer_name: dev.developer_name,
          role: dev.role,
          org: dev.org,
          key_prefix: dev.key_prefix,
          active: dev.active,
          last_used_at: format_datetime(dev.last_used_at),
          created_at: format_datetime(dev.inserted_at)
        }
      end)

    {:ok, %{developers: entries, total: length(entries)}}
  end

  def revoke_key(args) do
    developer_name = Map.get(args, "developer_name")

    if is_nil(developer_name) or developer_name == "" do
      {:error, "developer_name is required"}
    else
      case Developers.revoke_by_name(
             developer_name,
             Map.get(args, "_auth_org_id", Acs.Org.current())
           ) do
        {:ok, dev} ->
          {:ok,
           %{
             developer_name: dev.developer_name,
             active: dev.active,
             status: "revoked"
           }}

        {:error, :not_found} ->
          {:error, "Developer key not found"}

        {:error, reason} ->
          {:error, "Failed to revoke key: #{inspect(reason)}"}
      end
    end
  end

  def create_org(args) do
    name = Map.get(args, "name")
    slug = Map.get(args, "slug")
    subdomain = Map.get(args, "subdomain", slug)
    plan = Map.get(args, "plan", "free")

    cond do
      is_nil(name) or name == "" ->
        {:error, "name is required"}

      is_nil(slug) or slug == "" ->
        {:error, "slug is required"}

      true ->
        case Acs.Orgs.create(%{name: name, slug: slug, subdomain: subdomain, plan: plan}) do
          {:ok, org} ->
            case Developers.generate_key("#{org.slug}-provisioning",
                   role: "collaborator",
                   org: org.slug
                 ) do
              {:ok, %{key: raw_key, developer: dev}} ->
                {:ok,
                 %{
                   name: org.name,
                   slug: org.slug,
                   subdomain: org.subdomain,
                   plan: org.plan,
                   url: "https://#{org.subdomain}.#{Acs.Org.base_domain()}",
                   obsidian_url: "https://#{org.subdomain}.obsidian.#{Acs.Org.base_domain()}",
                   syncthing_note:
                     "Add syncthing_#{org.subdomain} service to docker-compose and a Caddy route for #{org.subdomain}.obsidian.#{Acs.Org.base_domain()}",
                   developer_key: raw_key,
                   key_prefix: dev.key_prefix,
                   developer_name: dev.developer_name
                 }}

              {:error, reason} ->
                {:error,
                 "Org #{org.slug} created, but developer key provisioning failed: #{inspect(reason)}"}
            end

          {:error, errors} ->
            {:error, "Failed to create org: #{inspect(errors)}"}
        end
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
end
