defmodule Acs.Memory.SearchStatusVisibilityTest do
  @moduledoc "Default-status and explicit-status behaviour for Search and QueryAgent."
  use Acs.DataCase, async: false

  alias Acs.Memory.Indexer
  alias Acs.Memory.Schema
  alias Acs.Memory.Search
  alias Acs.Repo

  @org "default"
  @scope "test/status_visibility"
  @keyword "zorbenite"

  setup do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    approved =
      Repo.insert!(%Schema{
        id: Ecto.UUID.generate(),
        org: @org,
        kind: "learning",
        title: "Zorbenite approved fact",
        content: "Approved content about zorbenite for testing status visibility.",
        scope_path: @scope,
        status: "approved",
        created_at: now,
        updated_at: now
      })

    deprecated =
      Repo.insert!(%Schema{
        id: Ecto.UUID.generate(),
        org: @org,
        kind: "learning",
        title: "Zorbenite deprecated fact",
        content: "Deprecated content about zorbenite for testing status visibility.",
        scope_path: @scope,
        status: "deprecated",
        created_at: now,
        updated_at: now
      })

    stale =
      Repo.insert!(%Schema{
        id: Ecto.UUID.generate(),
        org: @org,
        kind: "learning",
        title: "Zorbenite stale fact",
        content: "Stale content about zorbenite for testing status visibility.",
        scope_path: @scope,
        status: "stale",
        created_at: now,
        updated_at: now
      })

    %{approved: approved, deprecated: deprecated, stale: stale}
  end

  # --- Search.search/2 ---

  test "search with no :status returns only approved" do
    results = Search.search(@keyword, mode: "keyword", scope_path: @scope, org: @org)
    titles = Enum.map(results, & &1.title)
    assert "Zorbenite approved fact" in titles
    refute "Zorbenite deprecated fact" in titles
  end

  test "search with no :status returns both approved and stale, but not deprecated" do
    results = Search.search(@keyword, mode: "keyword", scope_path: @scope, org: @org)
    titles = Enum.map(results, & &1.title)
    assert "Zorbenite approved fact" in titles
    assert "Zorbenite stale fact" in titles
    refute "Zorbenite deprecated fact" in titles
  end

  test "search with status: deprecated returns only deprecated" do
    results =
      Search.search(@keyword,
        mode: "keyword",
        scope_path: @scope,
        org: @org,
        status: "deprecated"
      )

    titles = Enum.map(results, & &1.title)
    assert "Zorbenite deprecated fact" in titles
    refute "Zorbenite approved fact" in titles
  end

  test "search with status: list returns both" do
    results =
      Search.search(@keyword,
        mode: "keyword",
        scope_path: @scope,
        org: @org,
        status: ["approved", "deprecated"]
      )

    titles = Enum.map(results, & &1.title)
    assert "Zorbenite approved fact" in titles
    assert "Zorbenite deprecated fact" in titles
  end

  test "search with status: all returns both" do
    results =
      Search.search(@keyword, mode: "keyword", scope_path: @scope, org: @org, status: "all")

    titles = Enum.map(results, & &1.title)
    assert "Zorbenite approved fact" in titles
    assert "Zorbenite deprecated fact" in titles
  end

  # --- Search.list/1 ---

  test "list with no :status returns only approved" do
    results = Search.list(scope_path: @scope, org: @org)
    titles = Enum.map(results, & &1.title)
    assert "Zorbenite approved fact" in titles
    refute "Zorbenite deprecated fact" in titles
  end

  # --- QueryAgent.ask/1 MCP regression ---

  test "QueryAgent.ask with no status key returns only approved; status=all returns both" do
    Acs.Org.with_current(@org, fn ->
      args_no_status = %{
        "content_query" => @keyword,
        "include_documents" => false,
        "include_skills" => false,
        "include_agent_status" => false,
        "limit" => 10
      }

      {:ok, resp_approved_only} = Acs.MCP.Tools.QueryAgent.ask(args_no_status)
      assert resp_approved_only.response =~ "Zorbenite approved fact"
      refute resp_approved_only.response =~ "Zorbenite deprecated fact"

      args_all =
        Map.put(args_no_status, "status", "all")

      {:ok, resp_all} = Acs.MCP.Tools.QueryAgent.ask(args_all)
      assert resp_all.response =~ "Zorbenite approved fact"
      assert resp_all.response =~ "Zorbenite deprecated fact"
    end)
  end

  # --- Indexer.list_memories/1 directly ---

  test "Indexer.list_memories with no status returns both (indexer itself unfiltered)" do
    results = Indexer.list_memories(scope_path: @scope, org: @org)
    titles = Enum.map(results, & &1.title)
    assert "Zorbenite approved fact" in titles
    assert "Zorbenite deprecated fact" in titles
  end
end
