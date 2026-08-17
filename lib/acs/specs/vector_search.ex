defmodule Acs.Specs.VectorSearch do
  @moduledoc """
  Vector search and RAG retrieval for spec entries.

  Chunks large specs (document-type with lots of content) into segments
  and indexes each chunk with its source/origin context. Enables semantic
  retrieval of relevant spec fragments with provenance tracking.
  """

  require Logger

  alias Acs.Repo.Pgvector
  alias Acs.Specs.Entry
  alias Acs.Specs.Loader

  @table_name "spec_embeddings"
  @chunk_max_words 500
  @chunk_overlap_words 50

  def create_table(repo \\ Acs.Repo) do
    if Pgvector.enabled?(repo) do
      repo.query("CREATE EXTENSION IF NOT EXISTS vector")

      repo.query("""
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          id TEXT NOT NULL,
          app TEXT NOT NULL DEFAULT '',
          path TEXT NOT NULL DEFAULT '',
          chunk_index INTEGER NOT NULL DEFAULT 0,
          source TEXT DEFAULT '',
          content TEXT NOT NULL DEFAULT '',
          org TEXT NOT NULL DEFAULT 'default',
          repo TEXT,
          origin TEXT,
          embedding vector(#{Pgvector.dimensions()}) NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT NOW(),
          PRIMARY KEY (id, org)
        )
      """)

      repo.query("""
        CREATE INDEX IF NOT EXISTS spec_embeddings_embedding_hnsw_idx
          ON #{@table_name} USING hnsw (embedding vector_cosine_ops)
      """)
    else
      repo.query("""
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          id TEXT NOT NULL,
          app TEXT NOT NULL DEFAULT '',
          path TEXT NOT NULL DEFAULT '',
          chunk_index INTEGER NOT NULL DEFAULT 0,
          source TEXT DEFAULT '',
          content TEXT NOT NULL DEFAULT '',
          org TEXT NOT NULL DEFAULT 'default',
          repo TEXT,
          origin TEXT,
          embedding TEXT NOT NULL,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (id, org)
        )
      """)
    end

    repo.query("""
      CREATE INDEX IF NOT EXISTS idx_spec_embeddings_app_path
      ON #{@table_name} (app, path)
    """)

    ensure_metadata_columns(repo)

    :ok
  end

  defp ensure_metadata_columns(repo) do
    Enum.each(["repo", "origin"], fn column ->
      case repo.query("SELECT #{column} FROM #{@table_name} LIMIT 0") do
        {:ok, _} -> :ok
        _ -> repo.query("ALTER TABLE #{@table_name} ADD COLUMN #{column} TEXT")
      end
    end)
  end

  def upsert_chunk(
        id,
        app,
        path,
        chunk_index,
        source,
        content,
        embedding,
        org \\ Acs.Org.current(),
        repo \\ Acs.Repo,
        options \\ []
      )
      when is_binary(id) and is_list(embedding) do
    vector_literal = Pgvector.encode(embedding)

    if Pgvector.enabled?(repo) do
      repo.query(
        """
        INSERT INTO #{@table_name} (id, app, path, chunk_index, source, content, org, repo, origin, embedding, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, ($10::text)::vector, NOW())
        ON CONFLICT (id, org) DO UPDATE SET
          repo = EXCLUDED.repo,
          origin = EXCLUDED.origin,
          embedding = EXCLUDED.embedding,
          content = EXCLUDED.content,
          source = EXCLUDED.source,
          updated_at = EXCLUDED.updated_at
        """,
        [
          id,
          app,
          path,
          chunk_index,
          source,
          content,
          org,
          options[:repo],
          options[:origin],
          vector_literal
        ]
      )
    else
      repo.query(
        """
        INSERT INTO #{@table_name} (id, app, path, chunk_index, source, content, org, repo, origin, embedding, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
        ON CONFLICT(id, org) DO UPDATE SET
          repo = excluded.repo,
          origin = excluded.origin,
          embedding = excluded.embedding,
          content = excluded.content,
          source = excluded.source,
          updated_at = excluded.updated_at
        """,
        [
          id,
          app,
          path,
          chunk_index,
          source,
          content,
          org,
          options[:repo],
          options[:origin],
          vector_literal
        ]
      )
    end

    :ok
  end

  @batch_upsert_max_rows 50

  def upsert_chunks(entries, repo \\ Acs.Repo) when is_list(entries) and entries != [] do
    entries
    |> Enum.chunk_every(@batch_upsert_max_rows)
    |> Enum.each(fn chunk ->
      {sql, params} = build_batch_upsert(chunk, repo)
      repo.query(sql, params)
    end)

    :ok
  end

  defp build_batch_upsert(entries, repo) do
    if Pgvector.enabled?(repo) do
      values =
        entries
        |> Enum.with_index(1)
        |> Enum.map_join(", ", fn {_entry, i} ->
          p = (i - 1) * 10 + 1

          "($#{p}, $#{p + 1}, $#{p + 2}, $#{p + 3}, $#{p + 4}, $#{p + 5}, $#{p + 6}, $#{p + 7}, $#{p + 8}, ($#{p + 9}::text)::vector, NOW())"
        end)

      params =
        Enum.flat_map(entries, fn {id, app, path, chunk_index, source, content, embedding, org,
                                   entry_repo, origin} ->
          [
            id,
            app,
            path,
            chunk_index,
            source,
            content,
            org,
            entry_repo,
            origin,
            Pgvector.encode(embedding)
          ]
        end)

      {"""
       INSERT INTO #{@table_name} (id, app, path, chunk_index, source, content, org, repo, origin, embedding, updated_at)
       VALUES #{values}
       ON CONFLICT (id, org) DO UPDATE SET
         repo = EXCLUDED.repo,
         origin = EXCLUDED.origin,
         embedding = EXCLUDED.embedding,
         content = EXCLUDED.content,
         source = EXCLUDED.source,
         updated_at = EXCLUDED.updated_at
       """, params}
    else
      values =
        entries
        |> Enum.map_join(", ", fn _entry -> "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))" end)

      params =
        Enum.flat_map(entries, fn {id, app, path, chunk_index, source, content, embedding, org,
                                   entry_repo, origin} ->
          [
            id,
            app,
            path,
            chunk_index,
            source,
            content,
            org,
            entry_repo,
            origin,
            Pgvector.encode(embedding)
          ]
        end)

      {"""
       INSERT INTO #{@table_name} (id, app, path, chunk_index, source, content, org, repo, origin, embedding, updated_at)
       VALUES #{values}
       ON CONFLICT(id, org) DO UPDATE SET
         repo = excluded.repo,
         origin = excluded.origin,
         embedding = excluded.embedding,
         content = excluded.content,
         source = excluded.source,
         updated_at = excluded.updated_at
       """, params}
    end
  end

  def remove_embeddings(app, path, org \\ Acs.Org.current(), repo \\ Acs.Repo) do
    repo.query(
      "DELETE FROM #{@table_name} WHERE app = ? AND path = ? AND org = ?",
      [app, path, org]
    )

    :ok
  end

  def remove_all_for_app(app, org \\ Acs.Org.current(), repo \\ Acs.Repo) do
    repo.query("DELETE FROM #{@table_name} WHERE app = ? AND org = ?", [app, org])
    :ok
  end

  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    app = Keyword.get(opts, :app)
    org = Pgvector.org_filter(opts)
    {pg_filter, pg_params} = spec_filters(opts, :pg, 2 + Enum.count([org, app], &is_binary/1))
    {sqlite_filter, sqlite_params} = spec_filters(opts, :sqlite, 0)

    with {:ok, embedding} <- Pgvector.resolve_embedding(query, opts) do
      if Pgvector.enabled?() do
        search_pg(embedding, org, app, limit, pg_filter, pg_params)
      else
        search_sqlite(embedding, org, app, limit, sqlite_filter, sqlite_params)
      end
    else
      {:error, reason} ->
        Logger.warning("[Specs.VectorSearch] Embedding failed: #{reason}")
        {:error, reason}
    end
  end

  defp search_pg(embedding, org, app, limit, filter_sql, filter_params) do
    vector_literal = Pgvector.encode(embedding)

    {sql, params} =
      build_pg_search_sql(org, app, vector_literal, limit, filter_sql, filter_params)

    case Acs.Repo.query(sql, params) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        scored =
          Enum.map(rows, fn [
                              id,
                              chunk_app,
                              chunk_path,
                              chunk_index,
                              source,
                              content,
                              repo,
                              origin,
                              similarity
                            ] ->
            %{
              id: id,
              app: chunk_app,
              path: chunk_path,
              chunk_index: chunk_index,
              source: source,
              content: content,
              repo: repo,
              origin: origin,
              similarity: Pgvector.to_float(similarity)
            }
          end)

        {:ok, scored}

      _ ->
        {:ok, []}
    end
  end

  defp build_pg_search_sql(org, app, vector_literal, limit, filter_sql, filter_params) do
    {conditions, params, next} =
      {[], [vector_literal], 2}
      |> maybe_pg_condition(org, "org")
      |> maybe_pg_condition(app, "app")

    limit_param = next + length(filter_params)

    {"""
     SELECT id, app, path, chunk_index, source, content, repo, origin,
            1 - (embedding <=> ($1::text)::vector) AS similarity
     FROM #{@table_name}
     WHERE #{Enum.join(if(conditions == [], do: ["1=1"], else: conditions), " AND ")}#{filter_sql}
     ORDER BY embedding <=> ($1::text)::vector
     LIMIT $#{limit_param}
     """, params ++ filter_params ++ [limit]}
  end

  defp search_sqlite(embedding, org, app, limit, filter_sql, filter_params) do
    {sql, params} = build_search_sql(org, app, filter_sql, filter_params)

    case Acs.Repo.query(sql, params) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        scored =
          rows
          |> Enum.map(fn [
                           id,
                           chunk_app,
                           chunk_path,
                           chunk_index,
                           source,
                           content,
                           repo,
                           origin,
                           embedding_json
                         ] ->
            case Jason.decode(embedding_json) do
              {:ok, emb} ->
                %{
                  id: id,
                  app: chunk_app,
                  path: chunk_path,
                  chunk_index: chunk_index,
                  source: source,
                  content: content,
                  repo: repo,
                  origin: origin,
                  similarity: Acs.Memory.Embedding.cosine_similarity(embedding, emb)
                }

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.similarity, :desc)
          |> Enum.take(limit)

        {:ok, scored}

      _ ->
        {:ok, []}
    end
  end

  defp build_search_sql(org, app, filter_sql, filter_params) do
    conditions = [] |> maybe_sqlite_condition(org, "org") |> maybe_sqlite_condition(app, "app")
    conditions = if conditions == [], do: ["1=1"], else: conditions

    {"SELECT id, app, path, chunk_index, source, content, repo, origin, embedding FROM #{@table_name} WHERE #{Enum.join(conditions, " AND ")}#{filter_sql}",
     Enum.reject([org, app], &is_nil/1) ++ filter_params}
  end

  defp maybe_pg_condition({conditions, params, next}, nil, _column),
    do: {conditions, params, next}

  defp maybe_pg_condition({conditions, params, next}, value, column),
    do: {conditions ++ ["#{column} = $#{next}"], params ++ [value], next + 1}

  defp maybe_sqlite_condition(conditions, nil, _column), do: conditions
  defp maybe_sqlite_condition(conditions, _value, column), do: conditions ++ ["#{column} = ?"]

  defp spec_filters(opts, dialect, start) do
    target = opts[:repo] || opts[:current_repo]
    mode = opts[:repo_mode] || :blended
    origin = opts[:origin]
    ph = fn n -> if dialect == :pg, do: "$#{n}", else: "?" end

    {parts, params, next} =
      cond do
        is_binary(target) and mode in [:exact, "exact"] ->
          {[" AND repo = #{ph.(start)}"], [target], start + 1}

        is_binary(target) and mode in [:local, "local"] ->
          {[" AND (repo = #{ph.(start)} OR repo IS NULL)"], [target], start + 1}

        true ->
          {[], [], start}
      end

    if is_binary(origin),
      do: {Enum.join(parts ++ [" AND origin = #{ph.(next)}"], ""), params ++ [origin]},
      else: {Enum.join(parts, ""), params}
  end

  def ensure_embeddings do
    unless Acs.Memory.Embedding.available?() do
      Logger.warning("[Specs.VectorSearch] Ollama not available, skipping")
      {:error, "Ollama unavailable"}
    else
      do_ensure_embeddings()
    end
  end

  defp do_ensure_embeddings do
    create_table()

    {:ok, entries} = Loader.load_all()
    existing = existing_chunk_ids()

    unembedded_chunks =
      Enum.flat_map(entries, fn entry ->
        entry
        |> chunk_entry()
        |> Enum.reject(fn chunk -> MapSet.member?(existing, chunk.id) end)
      end)

    results = Acs.Memory.Embedding.embed_batch(Enum.map(unembedded_chunks, & &1.text))

    {embedded, failed, successes} =
      unembedded_chunks
      |> Enum.zip(results)
      |> Enum.reduce({0, 0, []}, fn
        {chunk, {:ok, embedding}}, {emb_acc, fail_acc, ok} ->
          {emb_acc + 1, fail_acc, [{chunk, embedding} | ok]}

        {chunk, {:error, reason}}, {emb_acc, fail_acc, ok} ->
          Logger.warning("[Specs.VectorSearch] Failed to embed chunk #{chunk.id}: #{reason}")

          {emb_acc, fail_acc + 1, ok}
      end)

    if successes != [] do
      upsert_chunks(
        Enum.map(successes, fn {chunk, embedding} ->
          {chunk.id, chunk.app, chunk.path, chunk.chunk_index, chunk.source, chunk.content,
           embedding, Acs.Org.current(), Map.get(chunk, :repo), Map.get(chunk, :origin)}
        end)
      )
    end

    stats = %{
      total_entries: length(entries),
      total_chunks: count_chunks(entries),
      existing: MapSet.size(existing),
      embedded: embedded,
      failed: failed
    }

    Logger.info(
      "[Specs.VectorSearch] ensure_embeddings: #{stats.total_entries} entries, #{stats.total_chunks} chunks, #{stats.existing} existing, #{stats.embedded} new, #{stats.failed} failed"
    )

    {:ok, stats}
  end

  defp count_chunks(entries) do
    Enum.reduce(entries, 0, fn entry, acc ->
      acc + length(chunk_entry(entry))
    end)
  end

  defp existing_chunk_ids do
    case Acs.Repo.query("SELECT id FROM #{@table_name}") do
      {:ok, %{rows: rows}} ->
        rows |> Enum.map(fn [id] -> id end) |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end

  def chunk_entry(%Entry{} = entry) do
    id_prefix = "#{entry.app}/#{entry.id}"

    if entry.document_type && entry.content && String.length(entry.content) > 0 do
      chunk_document(entry, id_prefix)
    else
      chunk_spec(entry, id_prefix)
    end
  end

  defp chunk_document(%Entry{} = entry, id_prefix) do
    source = entry.source || Loader.file_path(entry.app, entry.id)
    paragraphs = split_paragraphs(entry.content || "")

    paragraphs
    |> group_into_chunks()
    |> Enum.with_index()
    |> Enum.map(fn {text, idx} ->
      chunk_id = "#{id_prefix}~chunk#{idx}"

      %{
        id: chunk_id,
        app: entry.app,
        path: entry.id,
        chunk_index: idx,
        source: source,
        content: text,
        text:
          build_chunk_text(%{
            title: entry.title,
            source: source,
            content: text
          })
      }
    end)
  end

  defp chunk_spec(%Entry{} = entry, id_prefix) do
    source = entry.source || Loader.file_path(entry.app, entry.id)

    sections = [
      {"purpose", entry.purpose},
      {"invariants", Enum.join(entry.invariants || [], "\n")},
      {"workflows", Enum.join(entry.workflows || [], "\n")},
      {"failure_modes", Enum.join(entry.failure_modes || [], "\n")},
      {"constraints", Enum.join(entry.constraints || [], "\n")},
      {"input_output", "#{entry.input || ""}\n#{entry.output || ""}"},
      {"transformation", entry.expected_transformation || ""}
    ]

    sections
    |> Enum.filter(fn {_name, text} -> is_binary(text) and String.trim(text) != "" end)
    |> Enum.with_index()
    |> Enum.map(fn {{name, text}, idx} ->
      chunk_id = "#{id_prefix}~#{name}"

      %{
        id: chunk_id,
        app: entry.app,
        path: entry.id,
        chunk_index: idx,
        source: source,
        content: text,
        text:
          build_chunk_text(%{
            title: entry.title,
            source: source,
            section: name,
            content: text
          })
      }
    end)
  end

  defp build_chunk_text(%{content: content} = meta) do
    meta_parts =
      [:title, :source, :section]
      |> Enum.map(fn key ->
        case Map.get(meta, key) do
          nil -> nil
          "" -> nil
          val -> "#{String.capitalize(to_string(key))}: #{val}"
        end
      end)
      |> Enum.reject(&is_nil/1)

    (meta_parts ++ [content])
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp split_paragraphs(content) do
    content
    |> String.split("\n\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp group_into_chunks(paragraphs) do
    group_into_chunks(paragraphs, [], [], 0)
  end

  defp group_into_chunks([], _current, acc, _word_count) do
    Enum.reverse(acc)
  end

  defp group_into_chunks([p | rest], current, acc, word_count) do
    p_word_count = count_words(p)
    new_count = word_count + p_word_count

    if new_count > @chunk_max_words and current != [] do
      chunk_text = Enum.join(current, "\n\n")
      remainder = merge_overlap(current, p)

      group_into_chunks(
        rest,
        remainder,
        [chunk_text | acc],
        count_words(Enum.join(remainder, "\n\n"))
      )
    else
      group_into_chunks(rest, current ++ [p], acc, new_count)
    end
  end

  defp merge_overlap(current, next_paragraph) do
    overlap =
      current
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn p, {acc, count} ->
        wc = count_words(p)

        if count + wc <= @chunk_overlap_words do
          {[p | acc], count + wc}
        else
          {acc, count}
        end
      end)
      |> elem(0)

    overlap ++ [next_paragraph]
  end

  defp count_words(text) when is_binary(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp count_words(_), do: 0
end
