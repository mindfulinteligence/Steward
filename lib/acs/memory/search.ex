defmodule Acs.Memory.Search do
  @moduledoc """
  Search and retrieval interface for the memory system.

  Provides both basic keyword search (via SQLite LIKE) and
  structured queries (by scope, kind, status, importance).

  Supports three search modes:
  - `"auto"` (default): hybrid search (semantic + lexical + scope + metadata) when
    embeddings are available, falling back to LIKE-based search
  - `"keyword"`: forces LIKE-based FTS search via Indexer
  - `"semantic"`: forces embedding-based vector search
  """

  require Logger

  @doc """
  Normalize MCP status filter: omit/`nil`/`""` → `"approved"`; `"all"` → no filter (`nil`).
  """
  def resolve_status_filter(nil), do: "approved"
  def resolve_status_filter(""), do: "approved"
  def resolve_status_filter("all"), do: nil
  def resolve_status_filter(status) when is_binary(status), do: status
  def resolve_status_filter(_), do: "approved"

  @doc """
  Searches memories using the specified mode.

  Options:
  - `:mode` - "auto" (default), "keyword", or "semantic"
  - Other options passed through to the underlying search (scope_path, kind, limit, etc.)
  """
  def search(query, opts \\ []) do
    mode = Keyword.get(opts, :mode, "auto")

    case mode do
      "keyword" ->
        Acs.Memory.Indexer.search(query, opts)

      "semantic" ->
        search_semantic(query, opts)

      "auto" ->
        search_auto(query, opts)
    end
  end

  @doc """
  Like `search/2`, but also returns a scores map when hybrid/semantic results are available.

  Returns `{memories, scores_map}` where scores_map is `%{memory_id => float}`.
  When only keyword results are available, scores_map is empty.
  """
  def search_with_scores(query, opts \\ []) do
    mode = Keyword.get(opts, :mode, "auto")

    case mode do
      "keyword" ->
        {Acs.Memory.Indexer.search(query, opts), %{}}

      "semantic" ->
        search_semantic_with_scores(query, opts)

      "auto" ->
        search_auto_with_scores(query, opts)
    end
  end

  defp fetch_memories_by_ids_with_org(memory_ids, opts) do
    org = Keyword.get(opts, :org, Acs.Org.current())
    ctx = Acs.Abac.from_keyword(opts)

    Acs.Memory.Indexer.get_memories_by_ids(memory_ids, org)
    |> Enum.reduce(%{}, fn {id, schema}, acc ->
      if Acs.Abac.visible?(ctx, schema), do: Map.put(acc, id, schema), else: acc
    end)
  end

  defp search_auto(query, opts) do
    if hybrid_available?(opts) do
      hybrid_results = Acs.Memory.HybridSearch.search(query, opts)
      memory_ids = Enum.map(hybrid_results.results, & &1.memory_id)

      # Hybrid may drop weak summary/content-only hits under min_score; fall back
      # so exact LIKE matches (e.g. keyword only in summary) are not lost.
      if memory_ids == [] do
        Logger.debug("[Search] Hybrid returned no hits, falling back to keyword search")
        Acs.Memory.Indexer.search(query, opts)
      else
        memories_map = fetch_memories_by_ids_with_org(memory_ids, opts)

        memory_ids
        |> Enum.map(fn id -> Map.get(memories_map, id) end)
        |> Enum.reject(&is_nil/1)
        |> apply_status_filter(opts)
      end
    else
      Logger.warning("[Search] Hybrid search unavailable, falling back to keyword search")
      Acs.Memory.Indexer.search(query, opts)
    end
  end

  defp search_auto_with_scores(query, opts) do
    if hybrid_available?(opts) do
      hybrid_results = Acs.Memory.HybridSearch.search(query, opts)
      memory_ids = Enum.map(hybrid_results.results, & &1.memory_id)

      if memory_ids == [] do
        Logger.debug("[Search] Hybrid returned no hits, falling back to keyword search")
        {Acs.Memory.Indexer.search(query, opts), %{}}
      else
        memories_map = fetch_memories_by_ids_with_org(memory_ids, opts)
        scores_map = Map.new(hybrid_results.results, fn r -> {r.memory_id, r.total_score} end)

        memories =
          memory_ids
          |> Enum.map(fn id -> Map.get(memories_map, id) end)
          |> Enum.reject(&is_nil/1)
          |> apply_status_filter(opts)

        {memories, Map.take(scores_map, Enum.map(memories, & &1.id))}
      end
    else
      Logger.warning("[Search] Hybrid search unavailable, falling back to keyword search")
      {Acs.Memory.Indexer.search(query, opts), %{}}
    end
  end

  defp search_semantic(query, opts) do
    if embedding_ready?(opts) do
      case Acs.Repo.Pgvector.resolve_embedding(query, opts) do
        {:ok, embedding} ->
          limit = Keyword.get(opts, :limit, 20)
          similar = tenant_similar(embedding, opts, limit)
          memory_ids = Enum.map(similar, & &1.memory_id)

          if memory_ids == [] do
            []
          else
            memories_map = fetch_memories_by_ids_with_org(memory_ids, opts)

            memory_ids
            |> Enum.map(fn id -> Map.get(memories_map, id) end)
            |> Enum.reject(&is_nil/1)
            |> apply_status_filter(opts)
          end

        {:error, _reason} ->
          []
      end
    else
      Logger.warning("[Search] Embeddings unavailable for semantic search")
      []
    end
  end

  defp search_semantic_with_scores(query, opts) do
    if embedding_ready?(opts) do
      case Acs.Repo.Pgvector.resolve_embedding(query, opts) do
        {:ok, embedding} ->
          limit = Keyword.get(opts, :limit, 20)
          similar = tenant_similar(embedding, opts, limit)

          memory_ids = Enum.map(similar, & &1.memory_id)

          if memory_ids == [] do
            {[], %{}}
          else
            memories_map = fetch_memories_by_ids_with_org(memory_ids, opts)
            scores_map = Map.new(similar, fn s -> {s.memory_id, s.similarity} end)

            memories =
              memory_ids
              |> Enum.map(fn id -> Map.get(memories_map, id) end)
              |> Enum.reject(&is_nil/1)
              |> apply_status_filter(opts)

            {memories, Map.take(scores_map, Enum.map(memories, & &1.id))}
          end

        {:error, _reason} ->
          {[], %{}}
      end
    else
      Logger.warning("[Search] Embeddings unavailable for semantic search")
      {[], %{}}
    end
  end

  # Precomputed `:embedding` opts skip the Ollama availability probe.
  defp embedding_ready?(opts) do
    case Keyword.get(opts, :embedding) do
      emb when is_list(emb) and emb != [] -> true
      _ -> Acs.Memory.Embedding.available?()
    end
  end

  defp apply_status_filter(memories, opts) do
    case Keyword.get(opts, :status) do
      nil ->
        memories

      statuses when is_list(statuses) ->
        Enum.filter(memories, &(&1.status in statuses))

      status when is_binary(status) ->
        Enum.filter(memories, &(&1.status == status))

      _ ->
        memories
    end
  end

  defp tenant_similar(embedding, opts, limit) do
    org = Keyword.get(opts, :org, Acs.Org.current())

    Acs.Memory.VectorIndex.search_similar(embedding,
      limit: max(limit * 10, 100),
      org: org,
      current_repo: opts[:current_repo],
      repo: opts[:repo],
      repo_mode: opts[:repo_mode] || :blended,
      origin: opts[:origin]
    )
    |> Enum.filter(fn result ->
      cond do
        org == Acs.Org.configured() -> not String.contains?(result.memory_id, ":")
        is_binary(org) -> String.starts_with?(result.memory_id, org <> ":")
        true -> false
      end
    end)
    |> Enum.take(limit)
  end

  defp hybrid_available?(opts) do
    module_ok? =
      Code.ensure_loaded?(Acs.Memory.HybridSearch) &&
        function_exported?(Acs.Memory.HybridSearch, :search, 2)

    case Keyword.get(opts, :embedding) do
      emb when is_list(emb) and emb != [] -> module_ok?
      _ -> module_ok? && Acs.Memory.Embedding.available?()
    end
  end

  @doc """
  Lists memories with structured filters.
  """
  def list(opts \\ []) do
    Acs.Memory.Indexer.list_memories(opts)
  end

  @doc """
  Gets a single memory by ID.
  """
  def get(memory_id) do
    Acs.Memory.Indexer.get_memory(memory_id)
  end

  @doc """
  Finds memories relevant to a given context string and scope.
  Uses simple keyword matching and scope overlap.
  Returns top results ranked by relevance.
  """
  def find_relevant(context, opts \\ []) do
    keywords = extract_keywords(context)

    memories = search(keywords, opts)

    approved = Enum.filter(memories, fn m -> m.status == "approved" end)

    Enum.sort_by(approved, & &1.importance, :desc)
  end

  defp extract_keywords(context) when is_binary(context) do
    context
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(fn w -> String.length(w) < 3 end)
    |> Enum.reject(fn w -> w in ~w(the and for are but not you all can had her was has had) end)
    |> Enum.take(10)
    |> Enum.join(" ")
  end

  defp extract_keywords(_), do: ""
end
