defmodule Acs.Specs.Search do
  @moduledoc """
  Search across cognition spec entries.

  Supports three modes:
  - `"keyword"` (default): in-memory substring matching with weighted scoring
  - `"semantic"`: vector search via embeddings for meaning-based retrieval
  - `"hybrid"`: combines keyword and semantic scores

  For semantic/hybrid modes, results include chunked content with source/origin
  provenance for RAG (Retrieval Augmented Generation).
  """

  require Logger

  alias Acs.Specs.Loader

  @max_results 20
  @default_min_score 0.45

  @doc """
  Search across all loaded spec entries. Returns `{:ok, [%Entry{}]}` or `{:ok, [%{chunk_map}]}`.

  ## Options
    * `:app` — Filter by app (string or nil)
    * `:status` — Filter by status (string or nil)
    * `:limit` — Max results (default: 20)
    * `:mode` — "keyword" (default), "semantic", or "hybrid"
  """
  def search(query, opts \\ []) do
    with :ok <- validate_app_filter(opts[:app]) do
      if query in [nil, ""] do
        {:ok, []}
      else
        mode = Keyword.get(opts, :mode, "hybrid")

        case mode do
          "semantic" -> search_semantic(query, opts)
          "hybrid" -> search_hybrid(query, opts)
          _ -> search_keyword(query, opts)
        end
      end
    end
  end

  defp validate_app_filter(nil), do: :ok
  defp validate_app_filter(app), do: Loader.validate_app(app)

  defp maybe_filter_by_app(entries, nil), do: entries
  defp maybe_filter_by_app(entries, app), do: Enum.filter(entries, &(&1.app == app))

  defp search_keyword(query, opts) do
    app = opts[:app]
    status_filter = opts[:status]
    limit = opts[:limit] || @max_results
    query_words = tokenize(query)

    entries_result =
      case Keyword.fetch(opts, :entries) do
        {:ok, entries} when is_list(entries) -> {:ok, maybe_filter_by_app(entries, app)}
        _ -> Loader.load_all(app: app)
      end

    with {:ok, entries} <- entries_result do
      results =
        entries
        |> Enum.map(fn entry ->
          score = score_entry(entry, query_words)
          %{entry: entry, score: score}
        end)
        |> Enum.reject(fn %{score: score} -> score == 0 end)
        |> Enum.sort_by(fn %{score: score} -> score end, :desc)
        |> maybe_filter_by_status(status_filter)
        |> Enum.take(limit)
        |> Enum.map(fn %{entry: entry} -> entry end)

      {:ok, results}
    end
  end

  defp search_semantic(query, opts) do
    limit = opts[:limit] || @max_results
    app = opts[:app]
    min_score = Keyword.get(opts, :min_score, @default_min_score)
    vector_opts = vector_opts(opts, limit: limit, app: app)

    case Acs.Specs.VectorSearch.search(query, vector_opts) do
      {:ok, results} ->
        enriched =
          results
          |> Enum.filter(&(&1.similarity >= min_score))
          |> Enum.map(&enrich_rag_result/1)

        {:ok, enriched}

      {:error, reason} ->
        Logger.warning("[Specs.Search] Semantic search unavailable: #{reason}")
        {:ok, []}
    end
  end

  defp search_hybrid(query, opts) do
    limit = opts[:limit] || @max_results
    app = opts[:app]
    min_score = Keyword.get(opts, :min_score, @default_min_score)

    keyword_opts = Keyword.put(opts, :mode, "keyword")
    {:ok, keyword_results} = search_keyword(query, keyword_opts)

    keyword_ids =
      keyword_results
      |> Enum.map(fn e -> "#{e.app}/#{e.id}" end)
      |> MapSet.new()

    vector_opts = vector_opts(opts, limit: limit * 2, app: app)

    case Acs.Specs.VectorSearch.search(query, vector_opts) do
      {:ok, semantic_results} ->
        max_keyword_score = if keyword_results == [], do: 0.0, else: 1.0

        keyword_scored =
          keyword_results
          |> Enum.with_index()
          |> Enum.map(fn {entry, idx} ->
            score = max_keyword_score - idx / (length(keyword_results) + 1) * 0.3
            %{type: :entry, entry: entry, score: score}
          end)

        semantic_scored =
          semantic_results
          |> Enum.map(fn result ->
            id = "#{result.app}/#{result.path}"
            score_boost = if MapSet.member?(keyword_ids, id), do: 0.2, else: 0.0
            %{type: :chunk, chunk: result, score: result.similarity + score_boost}
          end)

        merged =
          (keyword_scored ++ semantic_scored)
          |> Enum.filter(&(&1.score >= min_score))
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.take(limit)

        enriched =
          Enum.map(merged, fn
            %{type: :entry, entry: entry} ->
              entry

            %{type: :chunk, chunk: chunk} ->
              enrich_rag_result(chunk)
          end)

        {:ok, enriched}

      {:error, _reason} ->
        {:ok, keyword_results}
    end
  end

  defp vector_opts(opts, overrides) do
    Keyword.merge(
      overrides,
      Keyword.take(opts, [:embedding, :org, :repo, :current_repo, :repo_mode, :origin])
    )
  end

  defp enrich_rag_result(%{
         app: app,
         path: path,
         chunk_index: idx,
         source: source,
         content: content,
         similarity: sim
       }) do
    %{
      __rag_chunk: true,
      app: app,
      path: path,
      chunk_index: idx,
      source: source || "#{app}/#{path}",
      content: content,
      similarity: Float.round(sim, 4),
      context: "Spec: #{app}/#{path} | Source: #{source || "#{app}/#{path}"} | Section #{idx}"
    }
  end

  defp enrich_rag_result(_), do: nil

  # Tokenize a query string into lowercase words.
  defp tokenize(query) do
    query
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
  end

  # Score a single entry against query words.
  # Higher scores for title and purpose matches; lower for constraints and failure modes.
  defp score_entry(entry, query_words) do
    title = (entry.title || "") |> String.downcase()
    purpose = (entry.purpose || "") |> String.downcase()
    tags = (entry.tags || []) |> Enum.map(&String.downcase/1)
    invariants = (entry.invariants || []) |> Enum.map(&normalize_to_string/1)
    workflows = (entry.workflows || []) |> Enum.map(&normalize_to_string/1)
    failure_modes = (entry.failure_modes || []) |> Enum.map(&normalize_to_string/1)
    constraints = (entry.constraints || []) |> Enum.map(&normalize_to_string/1)

    Enum.reduce(query_words, 0, fn word, acc ->
      acc +
        if(String.contains?(title, word), do: 10, else: 0) +
        if(String.contains?(purpose, word), do: 8, else: 0) +
        Enum.count(tags, &(&1 == word)) * 5 +
        Enum.count(invariants, &String.contains?(&1, word)) * 3 +
        Enum.count(workflows, &String.contains?(&1, word)) * 3 +
        Enum.count(failure_modes, &String.contains?(&1, word)) * 2 +
        Enum.count(constraints, &String.contains?(&1, word)) * 2
    end)
  end

  # Convert any value to a downcased string for scoring.
  # Strings are downcased directly.
  # Maps are flattened to "key: value, key2: value2" format.
  # All other values are converted via to_string/1.
  defp normalize_to_string(value) when is_binary(value), do: String.downcase(value)

  defp normalize_to_string(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
    |> Enum.join(", ")
    |> String.downcase()
  end

  defp normalize_to_string(value), do: value |> to_string() |> String.downcase()

  # Filter results by status. Returns all results when status is nil.
  defp maybe_filter_by_status(results, nil), do: results

  defp maybe_filter_by_status(results, status) do
    Enum.filter(results, fn %{entry: entry} -> entry.status == status end)
  end
end
