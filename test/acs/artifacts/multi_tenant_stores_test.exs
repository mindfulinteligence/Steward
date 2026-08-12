defmodule Acs.Artifacts.MultiTenantStoresTest do
  use Acs.DataCase, async: false

  alias Acs.Artifacts.{Ledger, Skill}
  alias Acs.MCP.ToolLoader
  alias Acs.MCP.Tools.DynamicTools
  alias Acs.Orgs.Organization
  alias Acs.Skills.Store
  alias Acs.Specs.{Entry, Loader}

  setup do
    previous_multi_tenant = Application.get_env(:steward_acs, :multi_tenant)
    previous_vault = Application.get_env(:steward_acs, :obsidian_vault_path)

    vault =
      Path.join(System.tmp_dir!(), "acs-artifact-stores-#{System.unique_integer([:positive])}")

    Application.put_env(:steward_acs, :multi_tenant, true)
    Application.put_env(:steward_acs, :obsidian_vault_path, vault)

    on_exit(fn ->
      restore_env(:multi_tenant, previous_multi_tenant)
      restore_env(:obsidian_vault_path, previous_vault)
      Acs.Org.clear_request_org()
      File.rm_rf!(vault)
    end)

    %{vault: vault}
  end

  test "stores skill revisions and status reads in the database without a skill file", %{
    vault: vault
  } do
    org = create_org("artifact-skills")

    Acs.Org.with_current(org.slug, fn ->
      assert {:ok, %{id: "release-runbook", path: nil}} =
               Store.save_skill("Release Runbook", "Initial runbook.",
                 description: "Release safely",
                 tags: ["release"]
               )

      assert {:ok, %{path: nil}} =
               Store.save_skill("Release Runbook", "Revised runbook.",
                 description: "Release safely"
               )

      assert :ok = Store.update_status("Release Runbook", "approved", "reviewer-7")

      assert %{
               id: "release-runbook",
               name: "Release Runbook",
               content: "Revised runbook.",
               status: "approved"
             } =
               Store.get_skill("Release Runbook")

      assert Repo.get_by!(Skill, organization_id: org.id, name: "Release Runbook").public_id ==
               "Release Runbook"

      assert [first, _second, third] = Ledger.history("Release Runbook", :skill, org.slug)
      assert first.revision_number == 1
      assert third.operation == "transition"
    end)

    refute File.exists?(Path.join([vault, "orgs", org.slug, "skills", "release-runbook.md"]))
  end

  test "saves, loads, and revises specs from the database without a spec file", %{vault: vault} do
    org = create_org("artifact-specs")

    Acs.Org.with_current(org.slug, fn ->
      assert :ok = Loader.save(spec_entry("Initial purpose for ledger storage."))

      assert {:ok, %{purpose: "Initial purpose for ledger storage."}} =
               Loader.load("ledger_app", "artifact_store")

      assert :ok = Loader.save(spec_entry("Revised purpose for ledger storage."))

      assert {:ok, %{purpose: "Revised purpose for ledger storage."}} =
               Loader.load("ledger_app", "artifact_store")

      assert [_first, second] = Ledger.history("ledger_app/artifact_store", :spec, org.slug)
      assert second.revision_number == 2
    end)

    refute File.exists?(
             Path.join([vault, "orgs", org.slug, "specs", "ledger_app", "artifact_store.yaml"])
           )
  end

  test "persists tenant tools to the ledger and loads them through the database source", %{
    vault: vault
  } do
    org = create_org("artifact-tools")

    args = %{
      "name" => "tenant-lookup",
      "app" => "tenant_app",
      "description" => "Look up tenant data.",
      "inputSchema" => %{"type" => "object", "properties" => %{}},
      "endpoint" => "http://93.184.216.34:8080/lookup",
      "_auth_credential_org_id" => org.slug
    }

    assert {:ok, %{path: path},
            {:database, org_slug, "tenant_app/tenant-lookup", _previous, _head}} =
             DynamicTools.persist_tool(args)

    assert path == "db://#{org.slug}/tenant_app/tenant-lookup"
    assert org_slug == org.slug

    assert {:ok, [config]} = ToolLoader.load_source({:tenant_db, org.slug})
    assert config["app"] == "tenant_app"
    assert config["_source"].path == path
    assert [%{"name" => "tenant-lookup"}] = config["tools"]

    refute File.exists?(Path.join([vault, "orgs", org.slug, "acstools", "tenant-lookup.yaml"]))
  end

  test "honors database prompt overrides and ignores tenant vault files", %{vault: vault} do
    org = create_org("artifact-prompts")
    override = Path.join([vault, "orgs", org.slug, "prompts", "skills", "instructions.md"])
    File.mkdir_p!(Path.dirname(override))
    File.write!(override, "tenant override must not be read")

    bundled =
      Path.join([
        Application.app_dir(:steward_acs),
        "priv",
        "prompts",
        "skills",
        "instructions.md"
      ])

    Acs.Org.with_current(org.slug, fn ->
      assert Acs.Prompts.instructions("skills") == String.trim(File.read!(bundled))
      refute Acs.Prompts.instructions("skills") == "tenant override must not be read"

      assert {:ok, _} =
               Acs.Prompts.Store.save_override("skills", "instructions", "database override")

      assert Acs.Prompts.instructions("skills") == "database override"

      assert {:ok, _} =
               Acs.Prompts.Store.save_override(
                 "skills",
                 "instructions",
                 "revised database override"
               )

      assert Acs.Prompts.instructions("skills") == "revised database override"
      assert Acs.Prompts.Store.override_exists?("skills", "instructions")

      assert [%{category: "skills", name: "instructions"}] = Acs.Prompts.Store.overrides()

      assert [_first, second] =
               Acs.Artifacts.Ledger.history("skills/instructions", :prompt, org.slug)

      assert second.revision_number == 2
      assert second.operation == "revise"

      assert {:ok, _} = Acs.Prompts.Store.tombstone("skills", "instructions")

      assert [_first, _second, third] =
               Acs.Artifacts.Ledger.history("skills/instructions", :prompt, org.slug)

      assert third.operation == "tombstone"
      assert Acs.Prompts.instructions("skills") == String.trim(File.read!(bundled))
      refute Acs.Prompts.Store.override_exists?("skills", "instructions")
      assert Acs.Prompts.Store.overrides() == []
    end)

    refute File.exists?(
             Path.join([vault, "orgs", org.slug, "prompts", "skills", "instructions.md"])
           ) and Acs.Prompts.instructions("skills") == "tenant override must not be read"
  end

  defp spec_entry(purpose) do
    Entry.from_map(%{
      "app" => "ledger_app",
      "id" => "artifact_store",
      "title" => "Artifact Store",
      "purpose" => purpose,
      "invariants" => ["Writes append a revision."],
      "workflows" => ["Save and load the specification."],
      "failure_modes" => ["A stale write is rejected."],
      "tags" => ["ledger"]
    })
  end

  defp create_org(suffix) do
    value = "#{suffix}-#{System.unique_integer([:positive])}"

    %Organization{}
    |> Organization.changeset(%{
      name: value,
      slug: value,
      subdomain: value,
      plan: "free",
      provisioning_status: "ready"
    })
    |> Repo.insert!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:steward_acs, key)
  defp restore_env(key, value), do: Application.put_env(:steward_acs, key, value)
end
