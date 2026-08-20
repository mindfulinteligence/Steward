defmodule Acs.Memory.VectorIndex do
  @moduledoc """
  Vector storage and similarity search for memory embeddings.

  - SQLite / local: embeddings stored as JSON text; cosine in Elixir.
  - Postgres / Neon: `pgvector` column + `<=>` cosine distance in SQL.
  """

  require Logger

  alias Acs.Memory.Embedding
  alias Acs.Memory.Retry
  alias Acs.Repo.Pgvector

  @table_name "memory_embeddings"

  @doc """
  Create the memory_embeddings table if it doesn't exist.
  """
  def create_embeddings_table(repo \\ Acs.Repo) do
    if Pgvector.enabled?(repo) do
      repo.query("CREATE EXTENSION IF NOT EXISTS vector")

      repo.query("""
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          memory_id TEXT NOT NULL,
           org TEXT NOT NULL DEFAULT 'default',
           repo TEXT,
           origin TEXT,
           content_hash TEXT,
           embedding_model TEXT,
           embedding vector(#{Pgvector.dimensions()}) NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT NOW(),
          PRIMARY KEY (memory_id, org)
        )
      """)

      repo.query("""
        CREATE INDEX IF NOT EXISTS memory_embeddings_embedding_hnsw_idx
          ON #{@table_name} USING hnsw (embedding vector_cosine_ops)
      """)
    else
      repo.query("""
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          memory_id TEXT NOT NULL,
           org TEXT NOT NULL DEFAULT 'default',
           repo TEXT,
           origin TEXT,
           content_hash TEXT,
           embedding_model TEXT,
           embedding TEXT NOT NULL,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (memory_id, org)
        )
      """)
    end

    :ok
  end

  @doc """
  Store or update embedding for a memory, scoped to an org.
  """
  def upsert_embedding(
        memory_id,
        embedding,
        org \\ Acs.Org.current(),
        repo \\ Acs.Repo,
        options \\ []
      )
      when is_binary(memory_id) and is_list(embedding) and is_binary(org) do
    index_id = Acs.Org.memory_index_id(memory_id, org)
    vector_literal = Pgvector.encode(embedding)

    Retry.with_busy_retry(fn ->
      result =
        if Pgvector.enabled?(repo) do
          # ($n::text)::vector: Postgrex has no vector OID without the pgvector package.
          repo.query(
            """
              INSERT INTO #{@table_name} (memory_id, org, repo, origin, embedding, updated_at)
              VALUES ($1, $2, $3, $4, ($5::text)::vector, NOW())
              ON CONFLICT (memory_id, org) DO UPDATE SET
                repo = EXCLUDED.repo,
                origin = EXCLUDED.origin,
                embedding = EXCLUDED.embedding,
                updated_at = EXCLUDED.updated_at
            """,
            [index_id, org, options[:repo], options[:origin], vector_literal]
          )
        else
          repo.query(
            """
              INSERT INTO #{@table_name} (memory_id, org, repo, origin, embedding, updated_at)
              VALUES (?, ?, ?, ?, ?, datetime('now'))
              ON CONFLICT(memory_id, org) DO UPDATE SET
                repo = excluded.repo,
                origin = excluded.origin,
                embedding = excluded.embedding,
                updated_at = excluded.updated_at
            """,
            [index_id, org, options[:repo], options[:origin], vector_literal]
          )
        end

      case result do
        {:ok, _} -> :ok
        {:error, reason} -> raise "memory embedding upsert failed: #{inspect(reason)}"
      end
    end)

    :ok
  end

  @batch_upsert_max_rows 50

  @doc """
  Batch store or update embeddings for multiple memories.

  Entries are `{memory_id, embedding, org, repo, origin, content_hash,
  embedding_model}` tuples. Rows are
  upserted in multi-row statements (chunked to respect SQLite's parameter
  limit) instead of one round-trip per memory.
  """
  def upsert_embeddings(entries, repo \\ Acs.Repo) when is_list(entries) and entries != [] do
    entries
    |> Enum.chunk_every(@batch_upsert_max_rows)
    |> Enum.each(fn chunk ->
      {sql, params} = build_batch_upsert(chunk, repo)

      Retry.with_busy_retry(fn ->
        case repo.query(sql, params) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            raise "memory embeddings upsert failed: #{inspect(reason)}"
        end
      end)
    end)

    :ok
  end

  defp build_batch_upsert(entries, repo) do
    if Pgvector.enabled?(repo) do
      values =
        entries
        |> Enum.with_index(1)
        |> Enum.map_join(", ", fn {_entry, i} ->
          p = (i - 1) * 7 + 1

          "($#{p}, $#{p + 1}, $#{p + 2}, $#{p + 3}, $#{p + 4}, $#{p + 5}, ($#{p + 6}::text)::vector, NOW())"
        end)

      params =
        Enum.flat_map(entries, fn {
                                    memory_id,
                                    embedding,
                                    org,
                                    entry_repo,
                                    origin,
                                    content_hash,
                                    embedding_model
                                  } ->
          [
            Acs.Org.memory_index_id(memory_id, org),
            org,
            entry_repo,
            origin,
            content_hash,
            embedding_model,
            Pgvector.encode(embedding)
          ]
        end)

      {"""
       INSERT INTO #{@table_name} (memory_id, org, repo, origin, content_hash, embedding_model, embedding, updated_at)
       VALUES #{values}
       ON CONFLICT (memory_id, org) DO UPDATE SET
          repo = EXCLUDED.repo,
          origin = EXCLUDED.origin,
          content_hash = EXCLUDED.content_hash,
          embedding_model = EXCLUDED.embedding_model,
         embedding = EXCLUDED.embedding,
         updated_at = EXCLUDED.updated_at
       """, params}
    else
      values =
        entries
        |> Enum.map_join(", ", fn _entry -> "(?, ?, ?, ?, ?, ?, ?, datetime('now'))" end)

      params =
        Enum.flat_map(entries, fn {
                                    memory_id,
                                    embedding,
                                    org,
                                    entry_repo,
                                    origin,
                                    content_hash,
                                    embedding_model
                                  } ->
          [
            Acs.Org.memory_index_id(memory_id, org),
            org,
            entry_repo,
            origin,
            content_hash,
            embedding_model,
            Pgvector.encode(embedding)
          ]
        end)

      {"""
       INSERT INTO #{@table_name} (memory_id, org, repo, origin, content_hash, embedding_model, embedding, updated_at)
       VALUES #{values}
       ON CONFLICT(memory_id, org) DO UPDATE SET
         repo = excluded.repo,
         origin = excluded.origin,
         content_hash = excluded.content_hash,
         embedding_model = excluded.embedding_model,
         embedding = excluded.embedding,
         updated_at = excluded.updated_at
       """, params}
    end
  end

  @doc """
  Find top-k similar memories by embedding, optionally scoped to an org.
  """
  @spec search_similar([float()], keyword(), module()) :: [
          %{memory_id: String.t(), similarity: float()}
        ]
  def search_similar(embedding, options \\ [], repo \\ Acs.Repo)
      when is_list(embedding) and is_list(options) do
    limit = Keyword.get(options, :limit, 10)
    org = Pgvector.org_filter(options)
    filters = vector_filters(options)

    if Pgvector.enabled?(repo) do
      search_similar_pg(embedding, org, limit, filters, repo)
    else
      search_similar_sqlite(embedding, org, limit, filters, repo)
    end
  end

  @doc """
  Delete embedding when memory is deleted.
  """
  def remove_embedding(memory_id, org \\ Acs.Org.current(), repo \\ Acs.Repo)
      when is_binary(memory_id) and is_binary(org) do
    index_id = Acs.Org.memory_index_id(memory_id, org)

    Retry.with_busy_retry(fn ->
      sql =
        if Pgvector.enabled?(repo) do
          {"DELETE FROM #{@table_name} WHERE memory_id = $1 AND org = $2", [index_id, org]}
        else
          {"DELETE FROM #{@table_name} WHERE memory_id = ? AND org = ?", [index_id, org]}
        end

      {query, params} = sql
      repo.query(query, params)
    end)

    :ok
  end

  @doc """
  Find memories above similarity threshold, optionally scoped to an org.
  """
  @spec search_threshold([float()], float(), keyword(), module()) :: [
          %{memory_id: String.t(), similarity: float()}
        ]
  def search_threshold(embedding, threshold, options \\ [], repo \\ Acs.Repo)
      when is_list(embedding) and is_number(threshold) do
    embedding
    |> search_similar(Keyword.put(options, :limit, 1000), repo)
    |> Enum.filter(&(&1.similarity >= threshold))
  end

  defp search_similar_pg(embedding, org, limit, filters, repo) do
    vector_literal = Pgvector.encode(embedding)
    {filter_sql, filter_params, next_param} = pg_filter_sql(filters, 3)

    {sql, params} =
      if org do
        {"""
         SELECT memory_id, 1 - (embedding <=> ($1::text)::vector) AS similarity
         FROM #{@table_name}
         WHERE org = $2#{filter_sql}
         ORDER BY embedding <=> ($1::text)::vector
         LIMIT $#{next_param}
         """, [vector_literal, org] ++ filter_params ++ [limit]}
      else
        {"""
         SELECT memory_id, 1 - (embedding <=> ($1::text)::vector) AS similarity
         FROM #{@table_name}
         ORDER BY embedding <=> ($1::text)::vector
         WHERE 1=1#{filter_sql}
         LIMIT $#{next_param - 1}
         """, [vector_literal] ++ filter_params ++ [limit]}
      end

    case repo.query(sql, params) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        Enum.map(rows, fn [memory_id, similarity | _] ->
          %{
            memory_id: Acs.Org.public_memory_id(memory_id, org || Acs.Org.current()),
            similarity: Pgvector.to_float(similarity)
          }
        end)

      {:error, reason} ->
        Logger.warning("[VectorIndex] pg search failed: #{inspect(reason)}")
        []

      _ ->
        []
    end
  end

  defp search_similar_sqlite(embedding, org, limit, filters, repo) do
    {filter_sql, filter_params} = sqlite_filter_sql(filters)

    {query, params} =
      if org do
        {"SELECT memory_id, embedding FROM #{@table_name} WHERE org = ?#{filter_sql}",
         [org] ++ filter_params}
      else
        {"SELECT memory_id, embedding FROM #{@table_name} WHERE 1=1#{filter_sql}", filter_params}
      end

    case repo.query(query, params) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        rows
        |> Enum.map(fn [memory_id, embedding_json] ->
          case Jason.decode(embedding_json) do
            {:ok, emb} ->
              %{
                memory_id: Acs.Org.public_memory_id(memory_id, org || Acs.Org.current()),
                similarity: Embedding.cosine_similarity(embedding, emb)
              }

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.similarity, :desc)
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  defp vector_filters(options) do
    mode = Keyword.get(options, :repo_mode, :blended)
    target = Keyword.get(options, :repo) || Keyword.get(options, :current_repo)
    origin = Keyword.get(options, :origin)
    %{mode: mode, target: target, origin: origin}
  end

  defp pg_filter_sql(%{mode: mode, target: target, origin: origin}, start) do
    {parts, params, next} =
      if is_binary(target) and mode in [:exact, "exact"] do
        {[" AND repo = $#{start}"], [target], start + 1}
      else
        if is_binary(target) and mode in [:local, "local"] do
          {[" AND (repo = $#{start} OR repo IS NULL)"], [target], start + 1}
        else
          {[], [], start}
        end
      end

    if is_binary(origin),
      do: {parts ++ [" AND origin = $#{next}"], params ++ [origin], next + 1},
      else:
        {parts, params, next}
        |> then(fn {parts, params, next} -> {Enum.join(parts), params, next} end)
  end

  defp sqlite_filter_sql(%{mode: mode, target: target, origin: origin}) do
    {parts, params} =
      cond do
        is_binary(target) and mode in [:exact, "exact"] ->
          {[" AND repo = ?"], [target]}

        is_binary(target) and mode in [:local, "local"] ->
          {[" AND (repo = ? OR repo IS NULL)"], [target]}

        true ->
          {[], []}
      end

    if is_binary(origin),
      do: {Enum.join(parts ++ [" AND origin = ?"]), params ++ [origin]},
      else: {Enum.join(parts), params}
  end
end
