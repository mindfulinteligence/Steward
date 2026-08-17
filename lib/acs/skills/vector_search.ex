defmodule Acs.Skills.VectorSearch do
  require Logger

  alias Acs.Repo.Pgvector

  @table_name "skill_embeddings"

  def create_table(repo \\ Acs.Repo) do
    if Pgvector.enabled?(repo) do
      repo.query("CREATE EXTENSION IF NOT EXISTS vector")

      repo.query("""
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          skill_name TEXT NOT NULL,
          org TEXT NOT NULL DEFAULT 'default',
          repo TEXT,
          origin TEXT,
          embedding vector(#{Pgvector.dimensions()}) NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT NOW(),
          PRIMARY KEY (skill_name, org)
        )
      """)

      repo.query("""
        CREATE INDEX IF NOT EXISTS skill_embeddings_embedding_hnsw_idx
          ON #{@table_name} USING hnsw (embedding vector_cosine_ops)
      """)
    else
      repo.query("""
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          skill_name TEXT NOT NULL,
          org TEXT NOT NULL DEFAULT 'default',
          repo TEXT,
          origin TEXT,
          embedding TEXT NOT NULL,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (skill_name, org)
        )
      """)
    end

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

  def upsert_embedding(
        skill_name,
        embedding,
        org \\ Acs.Org.current(),
        repo \\ Acs.Repo,
        options \\ []
      )
      when is_binary(skill_name) and is_list(embedding) and is_binary(org) do
    vector_literal = Pgvector.encode(embedding)

    if Pgvector.enabled?(repo) do
      repo.query(
        """
        INSERT INTO #{@table_name} (skill_name, org, repo, origin, embedding, updated_at)
        VALUES ($1, $2, $3, $4, ($5::text)::vector, NOW())
        ON CONFLICT (skill_name, org) DO UPDATE SET
          repo = EXCLUDED.repo,
          origin = EXCLUDED.origin,
          embedding = EXCLUDED.embedding,
          updated_at = EXCLUDED.updated_at
        """,
        [skill_name, org, options[:repo], options[:origin], vector_literal]
      )
    else
      repo.query(
        """
        INSERT INTO #{@table_name} (skill_name, org, repo, origin, embedding, updated_at)
        VALUES (?, ?, ?, ?, ?, datetime('now'))
        ON CONFLICT(skill_name, org) DO UPDATE SET
          repo = excluded.repo,
          origin = excluded.origin,
          embedding = excluded.embedding,
          updated_at = excluded.updated_at
        """,
        [skill_name, org, options[:repo], options[:origin], vector_literal]
      )
    end

    :ok
  end

  @batch_upsert_max_rows 50

  def upsert_embeddings(entries, repo \\ Acs.Repo) when is_list(entries) and entries != [] do
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
          p = (i - 1) * 5 + 1
          "($#{p}, $#{p + 1}, $#{p + 2}, $#{p + 3}, ($#{p + 4}::text)::vector, NOW())"
        end)

      params =
        Enum.flat_map(entries, fn {skill_name, embedding, org, entry_repo, origin} ->
          [skill_name, org, entry_repo, origin, Pgvector.encode(embedding)]
        end)

      {"""
       INSERT INTO #{@table_name} (skill_name, org, repo, origin, embedding, updated_at)
       VALUES #{values}
       ON CONFLICT (skill_name, org) DO UPDATE SET
         repo = EXCLUDED.repo,
         origin = EXCLUDED.origin,
         embedding = EXCLUDED.embedding,
         updated_at = EXCLUDED.updated_at
       """, params}
    else
      values =
        entries
        |> Enum.map_join(", ", fn _entry -> "(?, ?, ?, ?, ?, datetime('now'))" end)

      params =
        Enum.flat_map(entries, fn {skill_name, embedding, org, entry_repo, origin} ->
          [skill_name, org, entry_repo, origin, Pgvector.encode(embedding)]
        end)

      {"""
       INSERT INTO #{@table_name} (skill_name, org, repo, origin, embedding, updated_at)
       VALUES #{values}
       ON CONFLICT(skill_name, org) DO UPDATE SET
         repo = excluded.repo,
         origin = excluded.origin,
         embedding = excluded.embedding,
         updated_at = excluded.updated_at
       """, params}
    end
  end

  def remove_embedding(skill_name, org \\ Acs.Org.current(), repo \\ Acs.Repo)
      when is_binary(skill_name) and is_binary(org) do
    if Pgvector.enabled?(repo) do
      repo.query("DELETE FROM #{@table_name} WHERE skill_name = $1 AND org = $2", [
        skill_name,
        org
      ])
    else
      repo.query("DELETE FROM #{@table_name} WHERE skill_name = ? AND org = ?", [
        skill_name,
        org
      ])
    end

    :ok
  end

  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    org = Pgvector.org_filter(opts)
    {pg_repo_sql, pg_repo_params} = repo_filter(opts, :pg, if(org, do: 3, else: 2))
    {sqlite_repo_sql, sqlite_repo_params} = repo_filter(opts, :sqlite, 0)

    with {:ok, embedding} <- Pgvector.resolve_embedding(query, opts) do
      if Pgvector.enabled?() do
        search_pg(embedding, org, limit, pg_repo_sql, pg_repo_params)
      else
        search_sqlite(embedding, org, limit, sqlite_repo_sql, sqlite_repo_params)
      end
    else
      {:error, reason} ->
        Logger.warning("[Skills.VectorSearch] Embedding failed: #{reason}")
        {:error, reason}
    end
  end

  defp search_pg(embedding, org, limit, repo_sql, repo_params) do
    vector_literal = Pgvector.encode(embedding)

    {sql, params} =
      if org do
        {"""
         SELECT skill_name, repo, origin, 1 - (embedding <=> ($1::text)::vector) AS similarity
         FROM #{@table_name}
         WHERE org = $2#{repo_sql}
         ORDER BY embedding <=> ($1::text)::vector
         LIMIT $#{3 + length(repo_params)}
         """, [vector_literal, org] ++ repo_params ++ [limit]}
      else
        {"""
         SELECT skill_name, repo, origin, 1 - (embedding <=> ($1::text)::vector) AS similarity
         FROM #{@table_name}
         WHERE 1=1#{repo_sql}
         ORDER BY embedding <=> ($1::text)::vector
         LIMIT $#{2 + length(repo_params)}
         """, [vector_literal] ++ repo_params ++ [limit]}
      end

    case Acs.Repo.query(sql, params) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        scored =
          Enum.map(rows, fn [skill_name, repo, origin, similarity] ->
            %{
              skill_name: skill_name,
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

  defp search_sqlite(embedding, org, limit, repo_sql, repo_params) do
    {q, params} =
      if org do
        {"SELECT skill_name, repo, origin, embedding FROM #{@table_name} WHERE org = ?#{repo_sql}",
         [org] ++ repo_params}
      else
        {"SELECT skill_name, repo, origin, embedding FROM #{@table_name} WHERE 1=1#{repo_sql}",
         repo_params}
      end

    case Acs.Repo.query(q, params) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        scored =
          rows
          |> Enum.map(fn [skill_name, repo, origin, embedding_json] ->
            case Jason.decode(embedding_json) do
              {:ok, emb} ->
                %{
                  skill_name: skill_name,
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

  defp repo_filter(opts, dialect, start) do
    target = opts[:repo] || opts[:current_repo]
    mode = opts[:repo_mode] || :blended
    origin = opts[:origin]
    placeholder = fn n -> if dialect == :pg, do: "$#{n}", else: "?" end

    {parts, params, next} =
      cond do
        is_binary(target) and mode in [:exact, "exact"] ->
          {[" AND repo = #{placeholder.(start)}"], [target], start + 1}

        is_binary(target) and mode in [:local, "local"] ->
          {[" AND (repo = #{placeholder.(start)} OR repo IS NULL)"], [target], start + 1}

        true ->
          {[], [], start}
      end

    if is_binary(origin),
      do: {Enum.join(parts ++ [" AND origin = #{placeholder.(next)}"], ""), params ++ [origin]},
      else: {Enum.join(parts, ""), params}
  end

  def ensure_embeddings do
    unless Acs.Memory.Embedding.available?() do
      Logger.warning("[Skills.VectorSearch] Ollama not available, skipping")
      {:error, "Ollama unavailable"}
    else
      do_ensure_embeddings()
    end
  end

  defp do_ensure_embeddings do
    create_table()

    skills = Acs.Skills.Store.list_skills()
    existing = existing_embeddings()

    to_embed =
      Enum.reject(skills, fn skill ->
        MapSet.member?(existing, skill["name"])
      end)

    results = Acs.Memory.Embedding.embed_batch(Enum.map(to_embed, &retrieval_text/1))

    {embedded, failed, successes} =
      to_embed
      |> Enum.zip(results)
      |> Enum.reduce({0, 0, []}, fn
        {skill, {:ok, embedding}}, {emb_acc, fail_acc, ok} ->
          {emb_acc + 1, fail_acc, [{skill, embedding} | ok]}

        {skill, {:error, reason}}, {emb_acc, fail_acc, ok} ->
          Logger.warning("[Skills.VectorSearch] Failed to embed #{skill["name"]}: #{reason}")
          {emb_acc, fail_acc + 1, ok}
      end)

    if successes != [] do
      upsert_embeddings(
        Enum.map(successes, fn {skill, embedding} ->
          {skill["name"], embedding, Acs.Org.current(), skill["repo"], skill["origin"]}
        end)
      )
    end

    stats = %{
      total: length(skills),
      existing: MapSet.size(existing),
      embedded: embedded,
      failed: failed
    }

    Logger.info(
      "[Skills.VectorSearch] ensure_embeddings: #{stats.total} total, #{stats.existing} existing, #{stats.embedded} new, #{stats.failed} failed"
    )

    {:ok, stats}
  end

  defp retrieval_text(skill) do
    [
      "Title: #{skill["name"]}",
      "Description: #{skill["description"] || ""}",
      "Tags: #{Enum.join(skill["tags"] || [], ", ")}",
      "Content: #{String.slice(skill["content"] || "", 0, 2000)}"
    ]
    |> Enum.reject(&(&1 == "" or String.ends_with?(&1, ": ")))
    |> Enum.join("\n\n")
  end

  defp existing_embeddings do
    case Acs.Repo.query("SELECT skill_name FROM #{@table_name}") do
      {:ok, %{rows: rows}} ->
        rows |> Enum.map(fn [name] -> name end) |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end
end
