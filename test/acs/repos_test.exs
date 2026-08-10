defmodule Acs.ReposTest do
  use ExUnit.Case, async: true

  alias Acs.Repos

  describe "normalize/1" do
    test "lowercases, trims, and replaces invalid characters" do
      assert Repos.normalize("  My Repo-2  ") == "my-repo-2"
    end

    test "returns nil for empty" do
      assert Repos.normalize("") == nil
      assert Repos.normalize(nil) == nil
    end
  end

  describe "repo_for_file_path/1" do
    test "extracts app from lib path" do
      assert Repos.repo_for_file_path("/home/x/code/steward_acs/lib/acs/repos.ex") ==
               "steward_acs"
    end

    test "returns nil when no lib segment" do
      assert Repos.repo_for_file_path("/home/x/code/acme-web/README.md") == nil
    end
  end

  describe "repo_for_scope/1" do
    test "first path segment is the repo" do
      assert Repos.repo_for_scope("acme-web/support/refunds") == "acme-web"
    end

    test "nil for nil scope" do
      assert Repos.repo_for_scope(nil) == nil
    end
  end

  describe "guidance/0" do
    test "returns repo guidance when repo declared" do
      guidance = Repos.guidance()

      assert is_binary(guidance)
      assert guidance =~ "repo"
    end
  end
end
