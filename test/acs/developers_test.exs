defmodule Acs.DevelopersTest do
  use Acs.DataCase, async: false

  alias Acs.Developers
  alias Acs.Developers.DeveloperApiKey
  alias Acs.Repo

  describe "generate_key/2" do
    test "generates a valid developer key" do
      assert {:ok, %{key: raw_key, developer: dev}} = Developers.generate_key("test-user")
      assert String.starts_with?(raw_key, "acs_dev_")
      # prefix (acs_dev_) + hex
      assert byte_size(raw_key) == 8 + 64
      assert dev.developer_name == "test-user"
      assert dev.role == "collaborator"
      assert dev.active == true
    end

    test "accepts custom role and org options" do
      assert {:ok, %{developer: dev}} =
               Developers.generate_key("svc-user", role: "service", org: "prod")

      assert dev.role == "service"
      assert dev.org == "prod"
    end

    test "stores SHA-256 hash not raw key" do
      {:ok, %{key: raw_key, developer: dev}} = Developers.generate_key("hash-test")
      hash = :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
      assert dev.key_hash == hash
      assert dev.key_hash != raw_key
    end

    test "stores key prefix for identification" do
      {:ok, %{key: raw_key, developer: dev}} = Developers.generate_key("prefix-test")
      prefix = String.slice(raw_key, 0, 12)
      assert dev.key_prefix == prefix
    end
  end

  describe "authenticate/1" do
    test "returns role and org on valid key" do
      {:ok, %{key: raw_key}} =
        Developers.generate_key("auth-test", role: "admin", org: "staging")

      assert {:ok, %{role: "admin", org: "staging"}} = Developers.authenticate(raw_key)
    end

    test "returns error on invalid key" do
      assert {:error, "Invalid API key"} =
               Developers.authenticate(
                 "acs_dev_invalid_key_here_that_is_long_enough_to_be_a_key_but_not_in_db"
               )
    end

    test "returns error on revoked key" do
      {:ok, %{key: raw_key, developer: dev}} = Developers.generate_key("revoke-test")
      Developers.revoke(dev.id)
      assert {:error, "Invalid API key"} = Developers.authenticate(raw_key)
    end

    test "returns error on wrong hash" do
      assert {:error, "Invalid API key"} = Developers.authenticate("not-even-a-dev-key")
    end
  end

  describe "list_developers/0" do
    test "returns all developers" do
      Developers.generate_key("user-a")
      Developers.generate_key("user-b")
      devs = Developers.list_developers()
      assert length(devs) >= 2
      assert Enum.any?(devs, fn d -> d.developer_name == "user-a" end)
    end
  end

  describe "revoke/1" do
    test "marks key as inactive" do
      {:ok, %{developer: dev}} = Developers.generate_key("to-revoke")
      assert dev.active == true
      {:ok, revoked} = Developers.revoke(dev.id)
      assert revoked.active == false
    end

    test "returns error for unknown id" do
      assert {:error, :not_found} = Developers.revoke(Ecto.UUID.generate())
    end
  end

  describe "revoke_by_name/2" do
    test "revokes a key by developer_name" do
      {:ok, %{developer: dev}} = Developers.generate_key("by-name-revoke")
      assert {:ok, %{active: false}} = Developers.revoke_by_name("by-name-revoke")
      refute Repo.get!(DeveloperApiKey, dev.id).active
    end

    test "revokes ALL keys sharing a developer_name (was a crash)" do
      {:ok, %{developer: dev1}} = Developers.generate_key("dup-name")
      {:ok, %{developer: dev2}} = Developers.generate_key("dup-name")

      # Regression: Repo.get_by/3 raised "expected at most one result but got 2"
      # and ToolRegistry.safe_execute swallowed it to "Tool execution failed".
      assert {:ok, %{active: false}} = Developers.revoke_by_name("dup-name")
      refute Repo.get!(DeveloperApiKey, dev1.id).active
      refute Repo.get!(DeveloperApiKey, dev2.id).active
    end

    test "does not revoke keys of another org" do
      {:ok, %{developer: dev}} = Developers.generate_key("org-iso-revoke", org: "other")
      assert {:error, :not_found} = Developers.revoke_by_name("org-iso-revoke")
      assert Repo.get!(DeveloperApiKey, dev.id).active
    end

    test "returns error for unknown developer_name" do
      assert {:error, :not_found} = Developers.revoke_by_name("no-such-developer")
    end
  end

  describe "hash_key/1" do
    test "produces consistent SHA-256 hex digest" do
      hash1 = Developers.hash_key("test-key")
      hash2 = Developers.hash_key("test-key")
      assert hash1 == hash2
      # 32 bytes = 64 hex chars
      assert byte_size(hash1) == 64
    end

    test "produces different hashes for different keys" do
      refute Developers.hash_key("key-a") == Developers.hash_key("key-b")
    end
  end
end
