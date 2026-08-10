defmodule Acs.Memory.HybridSearch do
  @moduledoc """
  Hybrid search combining lexical, semantic, scope, and metadata signals.

  Scoring components (each 0.0–1.0):
  - Lexical: LIKE substring tiers (title/summary/content)
  - Semantic: cosine similarity of Ollama embeddings
  - Scope: exact / parent / sibling heuristics
  - Metadata: importance + status
  - Audience: exact / legacy / mismatch
  - Repo: current-repo match (org-wide neutral, other repos down-ranked)

  Default blend (overridable via `config :steward_acs, Acs.Memory.HybridSearch, weights: %{...}`):

      total = 0.25*semantic + 0.15*lexical + 0.25*scope + 0.10*metadata + 0.15*audience + 0.10*repo

  This total is a ranking score, not a calibrated probability. Impressions are
  logged via `Acs.Observability.AgentOps.log_search/1` so weights can be refit
  from later outcome labels (used in guidance, useful feedback, empty→save).
  """

  alias Acs.Memory.{Indexer, VectorIndex, Embedding}

  @default_limit 20
  # Raised with scope-heavy weights so weak content-only LIKE hits stay out.
  @default_min_score 0.45
  @weight_version "v3-sem0.25-lex0.15-scope0.25-meta0.10-aud0.15-repo0.10"

  @default_weights %{
    semantic: 0.25,
    lexical: 0.15,
    scope: 0.25,
    metadata: 0.10,
    audience: 0.15,
    repo: 0.10
  }

  @doc """
  Performs hybrid search across memory corpus.

  Options:
  - `:query` - search query string
  - `:scope` / `:scope_path` - filter by scope prefix
  - `:audience` - requesting audience ("coding" | "chat") for audience-weighted scoring
  - `:limit` - max results (default 20)
  - `:min_score` - drop blended totals below this (default 0.45), unless title lexical ≥ 0.7
  - `:weights` - map override `%{semantic:, lexical:, scope:, metadata:, audience:}`
  - `:embedding` - precomputed query embedding (skips Ollama when provided)
  - `:org` - tenant filter for vector search
  - `:repo` - filter to exactly this repo
  - `:current_repo` - the caller's repo for repo-aware ranking/labels
  - `:repo_mode` - `:local` (current repo + org-wide), `:exact` (current repo only), `:blended` (default, down-rank other repos)
  - `:log_search` - set `false` to skip impression telemetry (tests)
  """
  # Title match (0.7+) is a strong exact signal; keep it even when weighted total
  # sits just under min_score (common for proposed/stale or low-importance rows).
  @title_lexical_floor 0.7

  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)
    min_score = Keyword.get(opts, :min_score, @default_min_score)
    weights = resolve_weights(opts)
    # Callers (Search.find_relevant, MCP) pass :scope_path; accept both.
    scope = Keyword.get(opts, :scope) || Keyword.get(opts, :scope_path)
    audience = Keyword.get(opts, :audience)
    team_filter = Keyword.get(opts, :team_filter)
    project_filter = Keyword.get(opts, :project_filter)
    org = Keyword.get(opts, :org) || Acs.Org.current()
    current_repo = opts[:current_repo]
    repo = opts[:repo]

    query_embedding = get_query_embedding(query, opts)

    lexical_opts =
      opts
      |> Keyword.put(:limit, limit * 2)
      |> Keyword.put(:org, org)
      |> maybe_put_scope_path(scope)

    # Lexical DB scan and vector ANN in parallel once embedding is ready.
    {lexical_results, semantic_scores} =
      run_lexical_and_semantic(query, lexical_opts, query_embedding, org, limit, opts)

    scored_results =
      lexical_results
      |> Enum.map(fn memory ->
        semantic = Map.get(semantic_scores, memory.id, 0.0)
        lexical = compute_lexical_score(memory, query)
        scope_score = compute_scope_score(memory.scope_path, scope)
        repo_score = compute_repo_score(memory.repo, current_repo, repo)

        meta =
          compute_metadata_score(memory, team_filter: team_filter, project_filter: project_filter)

        aud = compute_audience_score(memory.audience, audience)

        total =
          weights.semantic * semantic +
            weights.lexical * lexical +
            weights.scope * scope_score +
            weights.metadata * meta +
            weights.audience * aud +
            weights.repo * repo_score

        %{
          memory_id: memory.id,
          title: memory.title,
          scope_path: memory.scope_path,
          kind: memory.kind,
          status: memory.status,
          importance: memory.importance,
          repo: memory.repo,
          origin: memory.origin,
          cross_repo:
            is_binary(current_repo) and is_binary(memory.repo) and memory.repo != current_repo,
          scores: %{
            semantic: semantic,
            lexical: lexical,
            scope: scope_score,
            metadata: meta,
            audience: aud,
            repo: repo_score
          },
          total_score: Float.round(total, 4)
        }
      end)
      |> Enum.filter(&keep_hybrid_result?(&1, min_score))
      |> Enum.sort_by(& &1.total_score, :desc)
      |> Enum.take(limit)

    result = %{query: query, results: scored_results, total: length(scored_results)}

    maybe_log_search(result, weights, opts)
    result
  end

  @doc "Active blend weights (config + defaults). Sum should be 1.0."
  def weights(opts \\ []) do
    resolve_weights(opts)
  end

  @doc false
  def weight_version, do: @weight_version

  defp resolve_weights(opts) do
    configured =
      case Application.get_env(:steward_acs, __MODULE__, [])[:weights] do
        %{} = w -> w
        _ -> %{}
      end

    override =
      case Keyword.get(opts, :weights) do
        %{} = w -> w
        _ -> %{}
      end

    @default_weights
    |> Map.merge(atomize_weight_keys(configured))
    |> Map.merge(atomize_weight_keys(override))
  end

  defp atomize_weight_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> map
  end

  defp keep_hybrid_result?(result, min_score) do
    result.total_score >= min_score or result.scores.lexical >= @title_lexical_floor
  end

  defp maybe_log_search(result, weights, opts) do
    if Keyword.get(opts, :log_search, true) do
      top =
        result.results
        |> Enum.take(5)
        |> Enum.map(fn r ->
          %{
            "memory_id" => r.memory_id,
            "total_score" => r.total_score,
            "semantic" => r.scores.semantic,
            "lexical" => r.scores.lexical,
            "scope" => r.scores.scope,
            "metadata" => r.scores.metadata,
            "audience" => r.scores.audience,
            "repo" => r.scores.repo,
            "cross_repo" => r.cross_repo
          }
        end)

      Acs.Observability.AgentOps.log_search(
        query: result.query,
        result_count: result.total,
        weight_version: @weight_version,
        weights: weights,
        top_results: top,
        org: Keyword.get(opts, :org),
        audience: Keyword.get(opts, :audience),
        scope_path: Keyword.get(opts, :scope) || Keyword.get(opts, :scope_path)
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  # Prefer embedding from opts; fall back to embedding the query string.
  defp get_query_embedding(query, opts) when is_binary(query) do
    case Keyword.get(opts, :embedding) do
      emb when is_list(emb) and emb != [] ->
        emb

      _ ->
        case Embedding.embed_text(Embedding.retrieval_query(query)) do
          {:ok, embedding} -> embedding
          _ -> nil
        end
    end
  end

  defp run_lexical_and_semantic(query, lexical_opts, nil, _org, _limit) do
    {Indexer.search(query, lexical_opts), %{}}
  end

  defp run_lexical_and_semantic(query, lexical_opts, embedding, org, limit, opts) do
    vector_limit = max(limit * 10, 100)

    lexical_task =
      Task.async(fn ->
        Acs.Org.with_current(org, fn -> Indexer.search(query, lexical_opts) end)
      end)

    semantic_task =
      Task.async(fn ->
        Acs.Org.with_current(org, fn ->
          VectorIndex.search_similar(embedding,
            limit: vector_limit,
            org: org,
            current_repo: opts[:current_repo],
            repo: opts[:repo],
            repo_mode: opts[:repo_mode] || :blended,
            origin: opts[:origin]
          )
          |> Map.new(fn %{memory_id: id, similarity: sim} -> {id, sim} end)
        end)
      end)

    lexical_results = Task.await(lexical_task, 15_000)
    semantic_scores = Task.await(semantic_task, 15_000)
    {lexical_results, semantic_scores}
  end

  defp compute_lexical_score(memory, query) do
    query_lower = String.downcase(query)

    title_match = String.contains?(String.downcase(memory.title), query_lower)
    content_match = String.contains?(String.downcase(memory.content || ""), query_lower)
    summary_match = String.contains?(String.downcase(memory.summary || ""), query_lower)

    cond do
      title_match && summary_match -> 0.9
      title_match -> 0.7
      content_match -> 0.5
      summary_match -> 0.4
      true -> 0.0
    end
  end

  defp compute_scope_score(_scope_path, nil), do: 0.5

  defp compute_scope_score(scope_path, filter_scope) do
    cond do
      scope_path == filter_scope ->
        1.0

      String.starts_with?(scope_path, filter_scope <> "/") ->
        0.7

      String.starts_with?(filter_scope, scope_path) ->
        0.7

      true ->
        scope_segments = String.split(scope_path, "/")
        filter_segments = String.split(filter_scope, "/")

        if scope_segments != [] and filter_segments != [] and
             hd(scope_segments) == hd(filter_segments) do
          0.4
        else
          0.1
        end
    end
  end

  defp compute_metadata_score(memory, opts) do
    importance_score = memory.importance / 5.0

    status_score =
      case memory.status do
        "approved" -> 1.0
        "proposed" -> 0.7
        "archived" -> 0.3
        _ -> 0.5
      end

    team_bonus = compute_team_project_bonus(memory, opts)

    0.6 * importance_score + 0.4 * status_score + team_bonus
  end

  defp compute_audience_score(_mem_audience, nil), do: 0.5

  defp compute_audience_score(mem_audience, req_audience) do
    mem = mem_audience && String.trim(mem_audience)
    req = req_audience && String.trim(req_audience)

    cond do
      mem == req -> 1.0
      is_nil(mem) or mem == "" -> 0.5
      true -> 0.2
    end
  end

  # Repo ranking: exact `repo` filter always scores full. Without a current
  # repo context, stay neutral (0.5) so legacy searches are unaffected. With
  # context: current-repo memories score 1.0, org-wide (repo nil) 0.6, any
  # other repo 0.2 — down-ranked but still eligible in blended mode.
  defp compute_repo_score(_mem_repo, _current_repo, repo) when is_binary(repo), do: 1.0

  defp compute_repo_score(_mem_repo, nil, _repo), do: 0.5

  defp compute_repo_score(mem_repo, current_repo, _repo) do
    mem = mem_repo && String.trim(mem_repo)

    cond do
      mem == current_repo -> 1.0
      is_nil(mem) or mem == "" -> 0.6
      true -> 0.2
    end
  end

  defp compute_team_project_bonus(memory, opts) do
    team_filter = Keyword.get(opts, :team_filter)
    project_filter = Keyword.get(opts, :project_filter)

    cond do
      team_filter && memory.team == team_filter -> 0.05
      project_filter && memory.project == project_filter -> 0.05
      memory.team || memory.project -> 0.02
      true -> 0.0
    end
  end

  defp maybe_put_scope_path(opts, nil), do: opts
  defp maybe_put_scope_path(opts, scope), do: Keyword.put(opts, :scope_path, scope)
end
