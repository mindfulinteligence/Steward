defmodule Acs.Memory.Embedding do
  @moduledoc """
  Generates embeddings for memory content using Ollama.

  Provides:
  - Single and batch embedding generation
  - Vector normalization (L2)
  - Cosine similarity calculation
  - Assumes Docker-managed always-on Ollama — gracefully skips if unavailable

  The embedding model used is `nomic-embed-text` as specified in the ACS architecture.
  """

  require Logger

  # Ollama base URL
  @default_ollama_url "http://localhost:11434"
  @default_model "nomic-embed-text"
  # nomic-embed-text output size; must match pgvector column on Neon.
  @default_dimensions 768
  # Bounded parallelism for batch embedding; avoids hammering CPU-only Ollama on
  # backfills (prod host has 2 cores).
  @default_batch_concurrency 2
  # Texts per `/api/embed` request. Batching cuts HTTP round-trips and lets
  # Ollama process the array in a single model forward pass.
  @default_batch_chunk_size 8

  @doc """
  Returns the configured Ollama URL.
  """
  def ollama_url do
    Application.get_env(:steward_acs, __MODULE__, [])
    |> Keyword.get(:ollama_url, @default_ollama_url)
  end

  @doc """
  Returns the configured embedding model.
  """
  def model do
    Application.get_env(:steward_acs, __MODULE__, [])
    |> Keyword.get(:model, @default_model)
  end

  @doc """
  Embedding vector length (nomic-embed-text = 768).
  """
  def dimensions do
    Application.get_env(:steward_acs, __MODULE__, [])
    |> Keyword.get(:dimensions, @default_dimensions)
  end

  # Retrieval queries embedded against the corpus don't need the full text —
  # Ollama embedding cost scales ~linearly with input length, and claim-time
  # queries are long (title + full task description). Truncating the retrieval
  # prompt cuts embed latency without meaningfully hurting recall.
  @retrieval_query_chars 200

  @doc """
  Truncates a retrieval query to the length that gets embedded.

  Storage indexing embeds full content (via `embed_text/1`); only *retrieval*
  queries should pass through this, since recall is driven by the query's key
  terms, which live in the head of the text.
  """
  def retrieval_query(query) when is_binary(query) do
    if String.length(query) > @retrieval_query_chars do
      String.slice(query, 0, @retrieval_query_chars)
    else
      query
    end
  end

  @doc """
  Generates an embedding vector for a single text string.

  Returns:
  - `{:ok, embedding}` on success where embedding is a list of floats
  - `{:error, reason}` on failure

  ## Example

      iex> {:ok, embedding} = Acs.Memory.Embedding.embed_text("cache release ordering")
      iex> length(embedding)
      768
  """
  @spec embed_text(String.t()) :: {:ok, [float()]} | {:error, String.t()}
  def embed_text(text) when is_binary(text) do
    url = ollama_url()
    model_name = model()
    prompt_chars = byte_size(text)
    started = System.monotonic_time(:millisecond)

    body = %{
      "model" => model_name,
      "prompt" => text
    }

    result =
      case Req.post("#{url}/api/embeddings", json: body, receive_timeout: 30_000, retry: false) do
        {:ok, %{status: 200, body: %{"embedding" => embedding}}} when is_list(embedding) ->
          {:ok, embedding}

        {:ok, %{status: 200, body: %{"embedding" => []}}} ->
          {:error, "Empty embedding returned"}

        {:ok, %{status: status, body: body}} ->
          {:error, "Ollama returned status #{status}: #{inspect(body)}"}

        {:error, %{reason: :econnrefused}} ->
          Logger.warning("[Embedding] Ollama connection refused at #{url}")
          {:error, "Ollama unavailable at #{url}"}

        {:error, %{reason: reason}} ->
          Logger.warning("[Embedding] Ollama request failed: #{inspect(reason)}")
          {:error, "Embedding request failed: #{inspect(reason)}"}
      end

    latency_ms = System.monotonic_time(:millisecond) - started
    log_embedding_call(result, model_name, latency_ms, prompt_chars)
    result
  rescue
    e ->
      Logger.error("[Embedding] Exception during embed_text: #{inspect(e)}")
      {:error, "Embedding failed: #{inspect(e)}"}
  end

  defp log_embedding_call(result, model_name, latency_ms, prompt_chars) do
    {status, error_type} =
      case result do
        {:ok, _} -> {"ok", nil}
        {:error, reason} -> {"error", embedding_error_type(reason)}
      end

    Acs.Observability.AgentOps.log_embedding(
      status: status,
      latency_ms: latency_ms,
      model: model_name,
      prompt_chars: prompt_chars,
      error_type: error_type
    )
  rescue
    _ -> :ok
  end

  defp embedding_error_type(reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "unavailable") or String.contains?(reason, "connection refused") ->
        "unavailable"

      String.contains?(reason, "Empty embedding") ->
        "empty"

      true ->
        "request_failed"
    end
  end

  defp embedding_error_type(_), do: "request_failed"

  @doc """
  Generates embeddings for multiple texts in a single batch request.

  Returns:
  - `{:ok, embeddings}` on success where embeddings is a list of embedding vectors
  - `{:error, reason}` on failure

  ## Example

      iex> {:ok, embeddings} = Acs.Memory.Embedding.embed_texts(["text1", "text2"])
      iex> length(embeddings)
      2
  """
  @spec embed_texts([String.t()]) :: {:ok, [[float()]]} | {:error, String.t()}
  def embed_texts(texts) when is_list(texts) do
    results = embed_batch(texts)

    errors =
      Enum.filter(results, fn
        {:ok, _} -> false
        {:error, _} -> true
      end)

    case errors do
      [] ->
        {:ok, Enum.map(results, fn {:ok, embedding} -> embedding end)}

      [first_error | _] ->
        {:error, elem(first_error, 1)}
    end
  end

  @doc """
  Embeds a list of texts in bounded-size batches via the Ollama `/api/embed`
  endpoint.

  Texts are split into chunks (default `#{@default_batch_chunk_size}`, tunable
  via the `:embed_batch_chunk_size` config key or the `:chunk_size` option),
  each sent as one batch request with bounded parallel concurrency (default
  `#{@default_batch_concurrency}`, overridable via the
  `:embed_batch_concurrency` config key or the `:max_concurrency` option) so
  large backfills don't hammer CPU-only Ollama.

  Returns a per-text result list in input order: `[{:ok, embedding} |
  {:error, reason}]`.
  """
  @spec embed_batch([String.t()], keyword()) :: [{:ok, [float()]} | {:error, String.t()}]
  def embed_batch(texts, opts \\ []) do
    chunk_size =
      opts[:chunk_size] ||
        Application.get_env(:steward_acs, __MODULE__, [])
        |> Keyword.get(:embed_batch_chunk_size, @default_batch_chunk_size)

    max_concurrency =
      opts[:max_concurrency] ||
        Application.get_env(:steward_acs, __MODULE__, [])
        |> Keyword.get(:embed_batch_concurrency, @default_batch_concurrency)

    chunks = Enum.chunk_every(texts, chunk_size)

    chunk_results =
      chunks
      |> Task.async_stream(
        &embed_chunk/1,
        max_concurrency: max_concurrency,
        timeout: 60_000,
        ordered: true,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _reason} -> {:error, "embedding timed out"}
      end)

    Enum.zip(chunks, chunk_results)
    |> Enum.flat_map(fn
      {_chunk, {:ok, embeddings}} when is_list(embeddings) ->
        Enum.map(embeddings, &{:ok, &1})

      {chunk, {:error, reason}} ->
        Enum.map(chunk, fn _ -> {:error, reason} end)
    end)
  end

  @doc false
  def embed_chunk(texts) when is_list(texts) and texts != [] do
    url = ollama_url()
    model_name = model()
    prompt_chars = texts |> Enum.map(&byte_size/1) |> Enum.sum()
    started = System.monotonic_time(:millisecond)

    body = %{
      "model" => model_name,
      "input" => texts
    }

    result =
      case Req.post("#{url}/api/embed", json: body, receive_timeout: 30_000, retry: false) do
        {:ok, %{status: 200, body: %{"embeddings" => embeddings}}} when is_list(embeddings) ->
          if length(embeddings) == length(texts) do
            {:ok, embeddings}
          else
            {:error,
             "Ollama returned #{length(embeddings)} embeddings for #{length(texts)} inputs"}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, "Ollama returned status #{status}: #{inspect(body)}"}

        {:error, %{reason: :econnrefused}} ->
          Logger.warning("[Embedding] Ollama connection refused at #{url}")
          {:error, "Ollama unavailable at #{url}"}

        {:error, %{reason: reason}} ->
          Logger.warning("[Embedding] Ollama request failed: #{inspect(reason)}")
          {:error, "Embedding request failed: #{inspect(reason)}"}
      end

    latency_ms = System.monotonic_time(:millisecond) - started
    log_embedding_call(result, model_name, latency_ms, prompt_chars)
    result
  rescue
    e ->
      Logger.error("[Embedding] Exception during embed_chunk: #{inspect(e)}")
      {:error, "Embedding failed: #{inspect(e)}"}
  end

  @doc """
  L2-normalizes a vector to unit length.

  Useful for cosine similarity calculations where vectors should be unit length.

  ## Example

      iex> vec = [3.0, 4.0]
      iex> normalized = Acs.Memory.Embedding.normalize(vec)
      iex> magnitude = :math.sqrt(Enum.reduce(normalized, 0, fn x, acc -> x * x + acc end))
      iex> abs(magnitude - 1.0) < 0.0001
      true
  """
  @spec normalize([number()]) :: [float()]
  def normalize(vector) when is_list(vector) do
    magnitude = :math.sqrt(Enum.reduce(vector, 0.0, fn x, acc -> x * x + acc end))

    if magnitude > 0 do
      Enum.map(vector, fn x -> x / magnitude end)
    else
      # Zero vector remains zero
      vector
    end
  end

  @doc """
  Calculates cosine similarity between two vectors.

  Returns a value between -1.0 and 1.0:
  - 1.0: identical direction
  - 0.0: orthogonal
  - -1.0: opposite direction

  Both vectors should be normalized for true cosine similarity.
  If not normalized, this computes the cosine of the angle between them.

  ## Example

      iex> v1 = [1.0, 0.0, 0.0]
      iex> v2 = [1.0, 0.0, 0.0]
      iex> Acs.Memory.Embedding.cosine_similarity(v1, v2)
      1.0
  """
  @spec cosine_similarity([number()], [number()]) :: float()
  def cosine_similarity(vector1, vector2) when is_list(vector1) and is_list(vector2) do
    len1 = length(vector1)
    len2 = length(vector2)

    cond do
      len1 == 0 or len2 == 0 ->
        0.0

      true ->
        dot_product =
          Enum.zip(vector1, vector2) |> Enum.reduce(0.0, fn {a, b}, acc -> a * b + acc end)

        magnitude1 = :math.sqrt(Enum.reduce(vector1, 0.0, fn x, acc -> x * x + acc end))
        magnitude2 = :math.sqrt(Enum.reduce(vector2, 0.0, fn x, acc -> x * x + acc end))

        if magnitude1 > 0 and magnitude2 > 0 do
          dot_product / (magnitude1 * magnitude2)
        else
          0.0
        end
    end
  end

  @doc """
  Converts a memory struct to normalized retrieval text for embedding.

  The retrieval text format follows the ACS specification:
  ```
  Scope: {scope_path}

  Type: {kind}

  Title: {title}

  Summary: {summary}

  Constraints: {key constraints from content}

  Failure: {failure_modes joined}
  ```

  This normalized format ensures consistent embedding quality across memories.
  """
  @spec memory_to_retrieval_text(Acs.Memory.t()) :: String.t()
  def memory_to_retrieval_text(%Acs.Memory{} = memory) do
    [
      "Scope: #{memory.scope_path}",
      "",
      "Type: #{memory.kind}",
      "",
      about_line(memory),
      "Title: #{memory.title}",
      "",
      "Summary: #{memory.summary || ""}",
      "",
      "Constraints: #{extract_constraints(memory.content)}",
      "",
      "Failure: #{Enum.join(memory.failure_modes || [], ", ")}"
    ]
    |> Enum.join("\n")
  end

  defp about_line(%Acs.Memory{} = memory) do
    case {about_tag(memory.tags, "about-name:"), about_tag(memory.tags, "about-type:")} do
      {nil, nil} -> "About: (none)"
      {nil, type} -> "About: type #{type}"
      {name, nil} -> "About: #{name}"
      {name, type} -> "About: #{type} #{name}"
    end
  end

  defp about_tag(tags, prefix) when is_list(tags) do
    Enum.find_value(tags, fn
      tag when is_binary(tag) and tag != "" ->
        if String.starts_with?(tag, prefix),
          do: String.trim_leading(tag, prefix),
          else: nil

      _ ->
        nil
    end)
  end

  defp about_tag(_tags, _prefix), do: nil

  @doc """
  Checks if Ollama is reachable via health endpoint.

  Assumes Docker-managed always-on Ollama — no auto-start.

  Returns:
  - `true` if Ollama is reachable
  - `false` otherwise
  """
  @spec available?() :: boolean()
  def available? do
    check_ollama()
  end

  # Pings Ollama /api/tags to check availability.
  # Returns true on 200, false on any error with diagnostic logging.
  defp check_ollama do
    url = ollama_url()

    # ponytail: no connect_timeout — Req 0.6 rejects it (ArgumentError → always "unavailable")
    case Req.get("#{url}/api/tags", receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200}} ->
        true

      {:ok, %{status: status}} ->
        Logger.debug("[Embedding] Ollama returned status #{status}")
        false

      {:error, %{reason: reason}} ->
        Logger.debug("[Embedding] Ollama check failed: #{inspect(reason)}")
        false
    end
  rescue
    e ->
      Logger.warning("[Embedding] Ollama check exception: #{inspect(e)}")
      false
  end

  # Private helpers

  defp extract_constraints(content) when is_binary(content) do
    # Extract lines that look like constraints/rules from content
    content
    |> String.split("\n")
    |> Enum.reject(fn line ->
      String.length(String.trim(line)) < 10 or
        String.starts_with?(String.trim(line), "#")
    end)
    |> Enum.take(3)
    |> Enum.join(" ")
  end

  defp extract_constraints(_), do: ""

  @doc """
  Generates embeddings for all memories that don't yet have one.

  Queries acs_memories for all memory IDs, queries memory_embeddings for
  existing IDs, computes the difference, and generates embeddings for each
  missing memory. Skips memories with status "parse_error" or "rejected".

  Returns `{:ok, stats}` where stats is a map:
  `%{total: N, existing: N, embedded: N, failed: N}`

  Returns `{:error, reason}` if Ollama is unavailable or the tables don't exist.
  """
  @spec ensure_embeddings() :: {:ok, map()} | {:error, String.t()}
  def ensure_embeddings do
    # Retry with backoff to handle startup ordering (e.g., Docker depends_on timing)
    unless retry_available?() do
      Logger.warning("[Embedding] Ollama not available after retries, skipping ensure_embeddings")
      {:error, "Ollama unavailable"}
    else
      do_ensure_embeddings()
    end
  end

  # Retry ollama check up to 10 times (11 total checks) with 1s delay between retries
  # Provides ~10s window for Docker container startup ordering
  defp retry_available? do
    retry_available?(10, 1000)
  end

  defp retry_available?(0, _delay), do: available?()

  defp retry_available?(n, delay) do
    if available?() do
      true
    else
      Process.sleep(delay)
      retry_available?(n - 1, delay)
    end
  end

  defp embeddable_kinds, do: Acs.Memory.embeddable_kinds()

  defp do_ensure_embeddings do
    import Ecto.Query
    alias Acs.Repo
    alias Acs.Memory.Schema
    alias Acs.Memory.VectorIndex

    # Ensure embeddings table exists before querying it
    VectorIndex.create_embeddings_table()

    # 1. Get all memory IDs from acs_memories
    all_memory_ids =
      Repo.all(from m in Schema, select: m.id)
      |> MapSet.new()

    total = MapSet.size(all_memory_ids)

    # 2. Get all memory IDs from memory_embeddings
    embedded_ids =
      case Repo.query("SELECT memory_id FROM memory_embeddings") do
        {:ok, %{rows: rows}} ->
          rows |> Enum.map(fn [id] -> id end) |> MapSet.new()

        {:error, _} ->
          # Table might not exist yet — treat as empty
          MapSet.new()
      end

    existing = MapSet.size(embedded_ids)

    # 3. Find memories without embeddings
    missing_ids = MapSet.difference(all_memory_ids, embedded_ids)

    # 4. Load full memories and filter out parse_error/rejected
    memories_to_embed =
      missing_ids
      |> MapSet.to_list()
      |> then(fn ids ->
        case ids do
          [] -> []
          _ -> Repo.all(from m in Schema, where: m.id in ^ids)
        end
      end)
      |> Enum.reject(fn m -> m.status in ~w(parse_error rejected) end)
      |> Enum.reject(fn m -> !(m.kind in embeddable_kinds()) end)

    batch_size = 10
    {embedded_count, failed_count} = embed_in_batches(memories_to_embed, batch_size, 0, 0)

    stats = %{
      total: total,
      existing: existing,
      embedded: embedded_count,
      failed: failed_count
    }

    Logger.info(
      "[Embedding] ensure_embeddings: #{total} total, #{existing} existing, #{embedded_count} new, #{failed_count} failed"
    )

    {:ok, stats}
  end

  defp embed_in_batches([], _batch_size, embedded, failed), do: {embedded, failed}

  defp embed_in_batches(memories, batch_size, embedded, failed) do
    {batch, rest} = Enum.split(memories, batch_size)

    {batch_embedded, batch_failed, successes} =
      Enum.reduce(batch, {0, 0, []}, fn schema, {emb_acc, fail_acc, ok} ->
        case embed_single_memory(schema) do
          {:ok, embedding} -> {emb_acc + 1, fail_acc, [{schema, embedding} | ok]}
          :error -> {emb_acc, fail_acc + 1, ok}
        end
      end)

    alias Acs.Memory.VectorIndex

    if successes != [] do
      VectorIndex.upsert_embeddings(
        Enum.map(successes, fn {schema, embedding} ->
          {schema.id, embedding, schema.org, schema.repo, schema.origin}
        end)
      )
    end

    # Sleep between batches to avoid overwhelming Ollama
    if rest != [] do
      Process.sleep(500)
    end

    embed_in_batches(rest, batch_size, embedded + batch_embedded, failed + batch_failed)
  end

  defp embed_single_memory(schema) do
    alias Acs.Memory.Indexer

    # Convert schema to Memory struct
    attrs = Indexer.schema_to_memory_attrs(schema)
    memory = Acs.Memory.new(attrs)

    # Generate retrieval text
    retrieval_text = memory_to_retrieval_text(memory)

    # Generate embedding
    case embed_text(retrieval_text) do
      {:ok, embedding} ->
        {:ok, embedding}

      {:error, reason} ->
        Logger.warning("[Embedding] Failed to embed memory #{memory.id}: #{reason}")
        :error
    end
  end
end
