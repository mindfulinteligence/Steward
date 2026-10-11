defmodule Acs.Orgs.Provisioner do
  alias Acs.Orgs.Organization
  alias Acs.Repo

  def provision(%Organization{} = organization) do
    if organization.provisioning_status == "ready" do
      {:ok, organization}
    else
      do_provision(organization)
    end
  end

  defp do_provision(organization) do
    try do
      if provision_paths?() do
        organization.slug
        |> paths()
        |> Enum.each(&File.mkdir_p!/1)
      end

      # Multi-tenant connectors need Auth0 API https://{slug}.{base}/mcp/sse
      # (Caddy injects that audience). Best-effort — does not block ready.
      Acs.Auth0.OrgAudience.ensure_async(organization.slug)

      update(organization, %{
        provisioning_status: "ready",
        provisioning_error: nil,
        provisioned_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    rescue
      error ->
        update(organization, %{
          provisioning_status: "failed",
          provisioning_error: Exception.message(error),
          provisioned_at: nil
        })
    end
  end

  defp update(organization, attrs) do
    case organization |> Organization.provisioning_changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        Acs.OrgsCache.invalidate()
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp paths(slug) do
    [
      Acs.Org.memory_dir(slug),
      Acs.Org.skills_dir(slug),
      Acs.Org.specs_dir(slug),
      Acs.Org.prompts_dir(slug),
      Acs.Org.tools_dir(slug)
    ]
  end

  defp provision_paths? do
    not Acs.Org.multi_tenant?() and
      (configured_path?(Application.get_env(:steward_acs, :obsidian_vault_path)) or
         configured_path?(System.get_env("SPECS_PATH")) or
         configured_path?(
           Application.get_env(:steward_acs, Acs.Specs.Loader, [])
           |> Keyword.get(:specs_path)
         ))
  end

  defp configured_path?(path), do: is_binary(path) and path != ""
end
