defmodule Acs.Orgs do
  @moduledoc """
  Organization lookup and provisioning.

  Database organizations are authoritative once present. YAML remains a read-only
  fallback while existing installations are expanded.
  """
  import Ecto.Query, warn: false

  alias Acs.Accounts
  alias Acs.Accounts.{AccountAuditEvent, User}
  alias Acs.Auth0.McpRole
  alias Acs.Orgs.{Organization, Provisioner}
  alias Acs.Repo

  def list_all do
    case Acs.OrgsCache.get() do
      nil ->
        database_orgs = Repo.all(Organization)

        database_slugs = MapSet.new(database_orgs, & &1.slug)
        legacy_orgs = Enum.reject(load_yaml_orgs(), &MapSet.member?(database_slugs, &1.slug))

        result = Enum.sort_by(database_orgs ++ legacy_orgs, & &1.slug)
        Acs.OrgsCache.put(result)
        result

      cached ->
        cached
    end
  end

  def get_by_slug(slug) when is_binary(slug) do
    slug = normalize_subdomain(slug)
    Repo.get_by(Organization, slug: slug) || Enum.find(load_yaml_orgs(), &(&1.slug == slug))
  end

  def get_by_subdomain(subdomain) when is_binary(subdomain) do
    subdomain = normalize_subdomain(subdomain)

    # Not a valid DNS label → cannot be an org; skip the DB (scanner junk).
    if Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,62}\z/, subdomain) do
      Acs.OrgsCache.fetch_subdomain(subdomain, fn ->
        Repo.get_by(Organization, subdomain: subdomain) ||
          legacy_org_by_subdomain(subdomain)
      end)
    end
  end

  def resolve_subdomain(subdomain) do
    subdomain = normalize_subdomain(subdomain)

    cond do
      subdomain in reserved_subdomains() ->
        {:error, :reserved_subdomain}

      Acs.Org.multi_tenant?() ->
        case get_by_subdomain(subdomain) do
          %Organization{slug: slug} -> {:ok, slug}
          _ -> {:error, :unknown_org}
        end

      true ->
        {:ok, subdomain}
    end
  end

  def create(attrs) do
    attrs = default_subdomain(attrs)

    case %Organization{} |> Organization.changeset(attrs) |> Repo.insert() do
      {:ok, organization} ->
        Acs.OrgsCache.invalidate()
        _ = Acs.AuthorityLevels.ensure_defaults!(organization.slug)
        Provisioner.provision(organization)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def create_for_user(%User{id: user_id}, attrs) do
    attrs = default_subdomain(attrs)

    with {:ok, organization} <-
           Repo.transaction(fn ->
             user = Repo.get!(User, user_id)

             if user.organization_id do
               Repo.rollback(:already_in_organization)
             end

             with {:ok, organization} <-
                    %Organization{} |> Organization.changeset(attrs) |> Repo.insert(),
                  {1, _} <-
                    Repo.update_all(
                      from(candidate in User,
                        where: candidate.id == ^user.id and is_nil(candidate.organization_id)
                      ),
                      set: [
                        organization_id: organization.id,
                        org_role: "owner",
                        org: organization.slug,
                        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
                      ]
                    ),
                  :ok <- Accounts.revoke_user_auth(user.id, broadcast: false),
                  {:ok, _audit} <-
                    %AccountAuditEvent{}
                    |> AccountAuditEvent.changeset(%{
                      actor_id: user.id,
                      target_user_id: user.id,
                      organization_id: organization.id,
                      event: "organization.created",
                      metadata: Jason.encode!(%{"slug" => organization.slug})
                    })
                    |> Repo.insert() do
               organization
             else
               {0, _} -> Repo.rollback(:already_in_organization)
               {:error, changeset} -> Repo.rollback(changeset)
             end
           end) do
      result = Provisioner.provision(organization)
      user = Repo.get!(User, user_id)
      McpRole.ensure_for_email_async(user.email)
      result
    end
  end

  def retry_provisioning(
        %User{organization_id: organization_id, org_role: "owner"},
        %Organization{id: organization_id} = organization
      ) do
    Provisioner.provision(%{organization | provisioning_status: "pending"})
  end

  def retry_provisioning(_, _), do: {:error, :unauthorized}

  @doc "Imports the explicitly configured legacy YAML registry into the database."
  def import_yaml do
    load_yaml_orgs()
    |> Enum.reduce_while({:ok, 0}, fn legacy, {:ok, count} ->
      attrs = %{
        name: legacy.name,
        slug: legacy.slug,
        subdomain: legacy.subdomain,
        plan: legacy.plan,
        provisioning_status: "ready"
      }

      case Repo.get_by(Organization, slug: legacy.slug) do
        %Organization{subdomain: subdomain} = organization when subdomain == legacy.subdomain ->
          case organization
               |> Organization.provisioning_changeset(%{
                 provisioning_status: "ready",
                 provisioning_error: nil
               })
               |> Repo.update() do
            {:ok, _organization} -> {:cont, {:ok, count}}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end

        %Organization{} ->
          {:halt, {:error, {:conflict, legacy.slug}}}

        nil ->
          case %Organization{} |> Organization.changeset(attrs) |> Repo.insert() do
            {:ok, _organization} -> {:cont, {:ok, count + 1}}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
      end
    end)
    |> tap(fn
      {:ok, _} -> Acs.OrgsCache.invalidate()
      _ -> :ok
    end)
  end

  def ensure_default! do
    case get_by_slug("default") do
      %Organization{} = organization -> organization
      nil -> elem(create(%{name: "Default", slug: "default", subdomain: "default"}), 1)
    end
  end

  defp default_subdomain(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :subdomain) or Map.has_key?(attrs, "subdomain") -> attrs
      Map.has_key?(attrs, :slug) -> Map.put(attrs, :subdomain, Map.get(attrs, :slug))
      Map.has_key?(attrs, "slug") -> Map.put(attrs, "subdomain", Map.get(attrs, "slug"))
      true -> attrs
    end
  end

  defp legacy_org_by_subdomain(subdomain) do
    case Enum.find(load_yaml_orgs(), &(&1.subdomain == subdomain)) do
      %Organization{slug: slug} = legacy ->
        if Repo.exists?(from organization in Organization, where: organization.slug == ^slug),
          do: nil,
          else: legacy

      nil ->
        nil
    end
  end

  defp reserved_subdomains, do: ~w(www obsidian api account)

  defp normalize_subdomain(nil), do: "default"
  defp normalize_subdomain(""), do: "default"
  defp normalize_subdomain("www"), do: "default"
  defp normalize_subdomain(subdomain), do: subdomain |> String.trim() |> String.downcase()

  defp load_yaml_orgs do
    case YamlElixir.read_from_file(orgs_path()) do
      {:ok, %{"orgs" => organizations}} when is_map(organizations) ->
        organizations
        |> Enum.map(fn {_slug, attrs} ->
          attrs = if is_map(attrs), do: attrs, else: %{}

          %Organization{
            id: Map.get(attrs, "slug"),
            name: Map.get(attrs, "name"),
            slug: Map.get(attrs, "slug"),
            subdomain: Map.get(attrs, "subdomain"),
            plan: Map.get(attrs, "plan", "free")
          }
        end)
        |> Enum.sort_by(& &1.slug)

      _ ->
        []
    end
  end

  defp orgs_path do
    Application.get_env(:steward_acs, :orgs_file) ||
      Application.app_dir(:steward_acs, "priv/orgs.yaml")
  end
end
