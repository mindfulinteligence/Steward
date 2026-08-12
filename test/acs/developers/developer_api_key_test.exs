defmodule Acs.Developers.DeveloperApiKeyTest do
  use Acs.DataCase, async: true

  alias Acs.Developers.DeveloperApiKey

  @valid_attrs %{
    key_hash: "abc123",
    developer_name: "Test Dev",
    role: "admin",
    cluster: "dev",
    kind: "code"
  }

  describe "changeset/2" do
    test "valid with required attributes" do
      changeset = DeveloperApiKey.changeset(%DeveloperApiKey{}, @valid_attrs)
      assert changeset.valid?
    end

    test "requires key_hash" do
      changeset = DeveloperApiKey.changeset(%DeveloperApiKey{}, %{@valid_attrs | key_hash: nil})
      refute changeset.valid?
      assert errors_on(changeset)[:key_hash]
    end

    test "requires developer_name" do
      changeset =
        DeveloperApiKey.changeset(%DeveloperApiKey{}, %{@valid_attrs | developer_name: nil})

      refute changeset.valid?
      assert errors_on(changeset)[:developer_name]
    end

    test "validates role inclusion" do
      changeset =
        DeveloperApiKey.changeset(%DeveloperApiKey{}, %{@valid_attrs | role: "superadmin"})

      refute changeset.valid?
    end

    test "accepts valid roles" do
      for role <- ~w(admin service reader) do
        changeset = DeveloperApiKey.changeset(%DeveloperApiKey{}, %{@valid_attrs | role: role})
        assert changeset.valid?, "role #{role} should be valid"
      end
    end

    test "defaults to collaborator role and default cluster" do
      changeset =
        DeveloperApiKey.changeset(%DeveloperApiKey{}, %{
          key_hash: "hash",
          developer_name: "default-test"
        })

      assert changeset.valid?
      assert get_field(changeset, :role) == "collaborator"
    end

    test "defaults kind to code" do
      changeset =
        DeveloperApiKey.changeset(%DeveloperApiKey{}, %{
          key_hash: "hash",
          developer_name: "kind-default-test"
        })

      assert get_field(changeset, :kind) == "code"
    end

    test "validates kind inclusion" do
      changeset =
        DeveloperApiKey.changeset(%DeveloperApiKey{}, %{@valid_attrs | kind: "agent"})

      refute changeset.valid?
    end

    test "accepts code and chat kinds" do
      for kind <- ~w(code chat) do
        changeset = DeveloperApiKey.changeset(%DeveloperApiKey{}, %{@valid_attrs | kind: kind})
        assert changeset.valid?, "kind #{kind} should be valid"
      end
    end
  end
end
