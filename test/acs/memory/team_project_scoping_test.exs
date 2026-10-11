defmodule Acs.Memory.TeamProjectScopingTest do
  @moduledoc """
  Regression test for the `team`/`project` filters on `Acs.Memory.Search` and
  `Acs.MCP.Tools.QueryAgent.ask/1`.

  These were previously dead: `team`/`project` were threaded through as extra
  keyword opts but no query path ever applied them as a `WHERE` clause — the
  keyword-search list path silently ignored them, and passing a team alongside
  a `content_query` caused the query text itself to be dropped instead of
  combined with the team filter. A caller relying on `team`/`project` to keep
  one org's memories out of another's results would have gotten identical,
  unscoped results for any team name, real or made up.
  """
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.QueryAgent
  alias Acs.Memory.Indexer
  alias Acs.Memory.Schema
  alias Acs.Memory.Search
  alias Acs.Repo

  @org "default"
  @scope "test/team_project_scoping"
  @keyword "glimmerfrost"

  setup do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    team_a =
      Repo.insert!(%Schema{
        id: Ecto.UUID.generate(),
        org: @org,
        kind: "learning",
        title: "Glimmerfrost team A memory",
        content: "Glimmerfrost content scoped to team alpha.",
        scope_path: @scope,
        status: "approved",
        team: "team-alpha",
        created_at: now,
        updated_at: now
      })

    team_b =
      Repo.insert!(%Schema{
        id: Ecto.UUID.generate(),
        org: @org,
        kind: "learning",
        title: "Glimmerfrost team B memory",
        content: "Glimmerfrost content scoped to team beta.",
        scope_path: @scope,
        status: "approved",
        team: "team-beta",
        created_at: now,
        updated_at: now
      })

    %{team_a: team_a, team_b: team_b}
  end

  test "Indexer.list_memories/1 filters by :team" do
    results = Indexer.list_memories(org: @org, scope_path: @scope, team: "team-alpha")
    titles = Enum.map(results, & &1.title)

    assert "Glimmerfrost team A memory" in titles
    refute "Glimmerfrost team B memory" in titles
  end

  test "Indexer.list_memories/1 with a made-up team returns nothing" do
    results = Indexer.list_memories(org: @org, scope_path: @scope, team: "no-such-team")
    assert results == []
  end

  test "Search.search/2 (keyword mode) filters by :team without dropping the query" do
    results =
      Search.search(@keyword, mode: "keyword", org: @org, scope_path: @scope, team: "team-alpha")

    titles = Enum.map(results, & &1.title)
    assert "Glimmerfrost team A memory" in titles
    refute "Glimmerfrost team B memory" in titles
  end

  test "QueryAgent.ask/1 combines content_query with a team filter instead of dropping the query" do
    {:ok, result} =
      QueryAgent.ask(%{
        "content_query" => @keyword,
        "team" => "team-alpha",
        "include_documents" => false,
        "include_skills" => false,
        "include_agent_status" => false,
        "limit" => 10
      })

    assert result.response =~ "Glimmerfrost team A memory"
    refute result.response =~ "Glimmerfrost team B memory"
  end

  test "QueryAgent.ask/1 with a made-up team returns no memories for a real query" do
    {:ok, result} =
      QueryAgent.ask(%{
        "content_query" => @keyword,
        "team" => "no-such-team",
        "include_documents" => false,
        "include_skills" => false,
        "include_agent_status" => false,
        "limit" => 10
      })

    refute result.response =~ "Glimmerfrost team A memory"
    refute result.response =~ "Glimmerfrost team B memory"
    assert result.summary.memory_count == 0
  end
end
