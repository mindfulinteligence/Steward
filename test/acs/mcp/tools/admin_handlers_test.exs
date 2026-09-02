defmodule Acs.MCP.Tools.AdminHandlersTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.AdminHandlers

  setup do
    on_exit(fn -> Acs.Org.clear_request_org() end)
    :ok
  end

  describe "create_org/1" do
    test "provisions the org and mints an org-scoped collaborator developer key" do
      assert {:ok, result} =
               AdminHandlers.create_org(%{"name" => "Acme", "slug" => "acme-provisioning"})

      assert result.slug == "acme-provisioning"
      assert String.starts_with?(result.developer_key, "acs_dev_")
      assert is_binary(result.key_prefix) and result.key_prefix != ""

      [dev] = Acs.Developers.list_developers("acme-provisioning")
      assert dev.org == "acme-provisioning"
      assert dev.role == "collaborator"
      assert dev.key_prefix == result.key_prefix
    end

    test "requires name and slug" do
      assert {:error, _} = AdminHandlers.create_org(%{"slug" => "no-name"})
      assert {:error, _} = AdminHandlers.create_org(%{"name" => "No Slug"})
    end
  end

  describe "generate_key/1" do
    test "without an org override, still resolves to the caller's own org" do
      assert {:ok, result} =
               AdminHandlers.generate_key(%{
                 "name" => "own-org-dev",
                 "_auth_org_id" => "default"
               })

      assert result.org == "default"
    end
  end
end
