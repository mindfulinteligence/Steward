defmodule Acs.Memory.Indexer do
  @moduledoc """
  Synchronizes YAML memory files into the SQLite index.

  The YAML files are canonical. The indexer reads all YAML files
  and upserts their contents into the acs_memories SQLite table
  for fast querying and FTS5 search.
  """

  alias Acs.Memory.Retry
  alias Acs.Repo
  alias Acs.Memory.Schema

  require Logger

  @status_types Acs.Governance.Status.primary_statuses() ++ ~w(stale archived parse_error)

  @doc """
  Syncs all memory files into the SQLite index.
  Returns {:ok, count, quarantined} where count is number of synced
  memories and quarantined is list of error tuples.
  """
  def sync_all do
    if Acs.Org.multi_tenant?() do
      orgs = Acs.Orgs.list_all()

      {total, all_quarantined} =
        Enum.reduce(orgs, {0, []}, fn org, {acc_count, acc_q} ->
          case sync_org(org.slug) do
            {:ok, count, quarantined} -> {acc_count + count, acc_q ++ quarantined}
            _ -> {acc_count, acc_q}
          end
        end)

      Logger.info(
        "[Memory.Indexer] Synced #{total} memories across #{length(orgs)} orgs, #{length(all_quarantined)} quarantined"
      )

      broadcast_memory_updated()
      {:ok, total, all_quarantined}
    else
      do_sync_current_org()
    end
  end

  def sync_org(org) when is_binary(org) do
    vault_dir = Acs.Org.memory_dir(org)

    if File.dir?(vault_dir) do
      {:ok, memories, quarantined} = Acs.Memory.Loader.load_all_for_org(org)

      count =
        Enum.reduce(memories, 0, fn memory, acc ->
          case upsert_memory(memory, broadcast: false) do
            {:ok, _} ->
              acc + 1

            {:error, reason} ->
              Logger.warning(
                "[Memory.Indexer] Failed to index #{memory.id} org=#{org}: #{reason}"
              )

              acc
          end
        end)

      {:ok, count, quarantined}
    else
      {:ok, 0, []}
    end
  end

  defp do_sync_current_org do
    Acs.Memory.Loader.quarantine_invalid()

    {:ok, memories, quarantined} = Acs.Memory.Loader.load_all()

    count =
      Enum.reduce(memories, 0, fn memory, acc ->
        case upsert_memory(memory, broadcast: false) do
          {:ok, _} ->
            acc + 1

          {:error, reason} ->
            Logger.warning("[Memory.Indexer] Failed to index #{memory.id}: #{reason}")
            acc
        end
      end)

    Logger.info("[Memory.Indexer] Synced #{count} memories, #{length(quarantined)} quarantined")
    broadcast_memory_updated()
    {:ok, count, quarantined}
  end

  @doc """
  Upserts a single memory file on disk into the SQLite index.
  Used by the FileWatcher for incremental updates (instead of full sync_all).

  Returns:
  - `:skip` — file unchanged (sha256 match in future, or file doesn't exist)
  - `{:ok, memory}` — upserted successfully
  - `{:error, reason}` — failed to load or index
  """
  def upsert_memory_file(file_path, opts \\ []) do
    org = Keyword.get(opts, :org)

    case Acs.Memory.Loader.load_file(file_path) do
      {:ok, memory} ->
        memory = if org, do: %{memory | org: org}, else: memory

        case upsert_memory(memory) do
          {:ok, _} -> {:ok, memory}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[Memory.Indexer] Cannot index #{file_path}: #{reason}")
        {:error, reason}
    end
  end

  # VaultSweeper re-upserts every ~30s. :replace_all wiped DB-only auditor_flags
  # and reset created_at (cooling-off), so audits never stuck in multi-tenant.
  @upsert_preserve_fields [:id, :auditor_flags, :created_at, :parse_error]

  @doc """
  Upserts a single Acs.Memory into the index.

  On conflict, replaces file-backed fields only — preserves `auditor_flags`,
  `created_at`, and `parse_error`.
  """
  def upsert_memory(%Acs.Memory{} = memory, opts \\ []) do
    if Acs.Org.multi_tenant?() and is_nil(Keyword.get(opts, :head_revision_id)) do
      {:error, "Direct projection writes are disabled in multi-tenant mode"}
    else
      do_upsert_memory(memory, opts)
    end
  end

  defp do_upsert_memory(%Acs.Memory{} = memory, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    created_at = parse_datetime(memory.created_at) || now
    updated_at = parse_datetime(memory.updated_at) || now

    attrs = %{
      id: storage_id(memory.org, memory.id),
      kind: memory.kind,
      status: memory.status,
      title: memory.title,
      summary: memory.summary,
      content: memory.content,
      scope_path: memory.scope_path,
      importance: memory.importance,
      tags_json: Jason.encode!(memory.tags || []),
      triggers_json: Jason.encode!(memory.triggers || []),
      failure_modes_json: Jason.encode!(memory.failure_modes || []),
      related_memories_json: Jason.encode!(memory.related_memories || []),
      verification_json: Jason.encode!(memory.verification),
      revalidation_json: Jason.encode!(memory.revalidation),
      created_by_json: Jason.encode!(memory.created_by),
      created_by_agent: get_in(memory.created_by, ["id"]),
      audience: memory.audience,
      repo: memory.repo,
      origin: memory.origin,
      file_path:
        if(Acs.Org.multi_tenant?(), do: nil, else: Acs.Memory.Loader.memory_to_path(memory)),
      team: memory.team,
      project: memory.project,
      visibility: memory.visibility,
      org: memory.org,
      authority_sort_order: memory.authority_sort_order,
      company_memory_id: Keyword.get(opts, :company_memory_id),
      head_revision_id: Keyword.get(opts, :head_revision_id)
    }

    result =
      Retry.with_busy_retry(fn ->
        %Schema{}
        |> Schema.changeset(attrs)
        |> Ecto.Changeset.put_change(:created_at, created_at)
        |> Ecto.Changeset.put_change(:updated_at, updated_at)
        |> Repo.insert(
          on_conflict: {:replace_all_except, @upsert_preserve_fields},
          conflict_target: :id
        )
      end)

    case result do
      {:ok, _} ->
        if Keyword.get(opts, :broadcast, true), do: broadcast_memory_updated()
        {:ok, memory}

      {:error, changeset} ->
        {:error, inspect(changeset.errors)}
    end
  end

  @doc """
  Removes a memory from the index by id.
  """
  def remove_memory(memory_id, org \\ Acs.Org.current()) do
    if Acs.Org.multi_tenant?() do
      {:error, "Direct memory deletion is disabled in multi-tenant mode"}
    else
      do_remove_memory(memory_id, org)
    end
  end

  defp do_remove_memory(memory_id, org) do
    result =
      Retry.with_busy_retry(fn ->
        case get_memory(memory_id, org) do
          nil -> :ok
          schema -> Repo.delete(schema)
        end
      end)

    case result do
      {:ok, _} -> broadcast_memory_updated()
      _ -> :noop
    end

    result
  end

  @doc """
  Updates the status of a memory in the index.
  Optionally scoped to an org.
  """
  def update_status(memory_id, new_status, org \\ Acs.Org.current())
      when new_status in @status_types do
    if Acs.Org.multi_tenant?() do
      {:error, "Direct status updates are disabled in multi-tenant mode"}
    else
      do_update_status(memory_id, new_status, org)
    end
  end

  defp do_update_status(memory_id, new_status, org) do
    result =
      Retry.with_busy_retry(fn ->
        case get_memory(memory_id, org) do
          nil ->
            {:error, "Memory not found: #{memory_id}"}

          schema ->
            schema
            |> Ecto.Changeset.change(%{
              status: new_status,
              updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })
            |> Repo.update()
        end
      end)

    case result do
      {:ok, _} -> broadcast_memory_updated()
      _ -> :noop
    end

    result
  end

  @doc """
  Updates a specific field on a memory in the index.
  Returns {:ok, schema} or {:error, reason}.
  Optionally scoped to an org.
  """
  def update_field(memory_id, field, value, org \\ Acs.Org.current())
      when field in ~w(title content)a do
    if Acs.Org.multi_tenant?() do
      {:error, "Direct field updates are disabled in multi-tenant mode"}
    else
      do_update_field(memory_id, field, value, org)
    end
  end

  defp do_update_field(memory_id, field, value, org) do
    result =
      Retry.with_busy_retry(fn ->
        case get_memory(memory_id, org) do
          nil ->
            {:error, "Memory not found: #{memory_id}"}

          schema ->
            schema
            |> Ecto.Changeset.change(%{
              field => value,
              updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })
            |> Repo.update()
        end
      end)

    case result do
      {:ok, _} -> broadcast_memory_updated()
      _ -> :noop
    end

    result
  end

  @doc false
  def broadcast_memory_updated do
    Acs.broadcast(:memory_updated, %{})
  end

  @doc """
  Gets a memory from the index by id, optionally filtered by org.
  """
  def get_memory(memory_id, org \\ Acs.Org.current())

  def get_memory(memory_id, org) do
    import Ecto.Query

    Repo.one(
      from m in Schema,
        where: m.id == ^storage_id(org, memory_id) and m.org == ^org
    ) || Repo.one(from m in Schema, where: m.id == ^memory_id and m.org == ^org)
  end

  @doc """
  Fetches memories by a list of IDs and returns a map of %{id => schema}.
  Optionally filtered by org.
  """
  def get_memories_by_ids(ids, org \\ Acs.Org.current())

  def get_memories_by_ids(ids, org) when is_list(ids) do
    import Ecto.Query

    storage_ids = Enum.map(ids, &storage_id(org, &1))

    Repo.all(from m in Schema, where: m.id in ^(ids ++ storage_ids) and m.org == ^org)
    |> Enum.into(%{}, fn m -> {m.id, m} end)
  end

  @doc """
  Returns a map of status -> count for all memories in the index.
  Uses a single query with GROUP BY instead of N individual queries.
  """
  def count_by_status(org \\ Acs.Org.current()) do
    import Ecto.Query

    query =
      from m in Schema,
        where: m.org == ^org,
        group_by: m.status,
        select: %{status: m.status, count: count(m.id)}

    Repo.all(query)
    |> Enum.into(%{}, fn %{status: s, count: c} -> {s, c} end)
  end

  @doc """
  Lists memories from the index with optional filters.
  """
  def list_memories(opts \\ []) do
    import Ecto.Query

    order_by = opts[:order_by] || [desc: :updated_at]
    org = Keyword.get(opts, :org, Acs.Org.current())

    query =
      case org do
        :all -> from(m in Schema)
        org when is_binary(org) -> from(m in Schema, where: m.org == ^org)
      end

    query = apply_audience_order(query, opts[:audience])
    query = from m in query, order_by: ^order_by

    query = if opts[:kind], do: from(m in query, where: m.kind == ^opts[:kind]), else: query

    query =
      if opts[:status] do
        if is_list(opts[:status]) do
          from(m in query, where: m.status in ^opts[:status])
        else
          from(m in query, where: m.status == ^opts[:status])
        end
      else
        query
      end

    query = apply_scope_path_filter(query, opts[:scope_path])
    query = apply_repo_filter(query, opts)
    query = if opts[:limit], do: from(m in query, limit: ^opts[:limit]), else: query
    query = build_abac_filter(query, opts)

    Repo.all(query)
  end

  @doc """
  Lists memories that have audit error count > 0 (need human review).
  Fetches proposed memories and filters those with error counts in auditor_flags.
  """
  def list_memories_needing_review(opts \\ []) do
    limit = opts[:limit] || 100

    # Fetch proposed memories (the ones the auditor processes)
    proposed =
      opts
      |> Keyword.merge(status: "proposed", limit: limit * 2, org: opts[:org] || Acs.Org.current())
      |> list_memories()

    # Filter to only those with audit error flags
    proposed
    |> Enum.filter(fn m ->
      case m.auditor_flags do
        nil ->
          false

        json when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, flags} ->
              Map.get(flags, "audit_error_count", 0) > 0

            _ ->
              false
          end

        _ ->
          false
      end
    end)
    |> Enum.take(limit)
  end

  @doc """
  Count memories needing review (have audit error count > 0).
  """
  def count_memories_needing_review(org \\ Acs.Org.current(), opts \\ []) do
    proposed =
      opts |> Keyword.merge(status: "proposed", limit: 500, org: org) |> list_memories()

    proposed
    |> Enum.count(fn m ->
      case m.auditor_flags do
        nil ->
          false

        json when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, flags} ->
              Map.get(flags, "audit_error_count", 0) > 0

            _ ->
              false
          end

        _ ->
          false
      end
    end)
  end

  @doc """
  Searches memories using LIKE-based text search.
  Returns a list of matching Schema records.
  """
  def search(query_text, opts \\ []) do
    import Ecto.Query

    search_clause = build_token_search_clause(query_text)
    org = opts[:org] || Acs.Org.current()

    search_query =
      from m in Schema,
        where: m.org == ^org,
        where: ^search_clause

    search_query = apply_scope_path_filter(search_query, opts[:scope_path])
    search_query = apply_repo_filter(search_query, opts)
    search_query = apply_audience_order(search_query, opts[:audience])

    search_query =
      from m in search_query, order_by: [desc: m.importance, desc: m.updated_at]

    search_query =
      if opts[:kind] do
        from m in search_query, where: m.kind == ^opts[:kind]
      else
        search_query
      end

    search_query =
      if opts[:status] do
        if is_list(opts[:status]) do
          from(m in search_query, where: m.status in ^opts[:status])
        else
          from(m in search_query, where: m.status == ^opts[:status])
        end
      else
        search_query
      end

    search_query =
      if opts[:limit] do
        from m in search_query, limit: ^opts[:limit]
      else
        from m in search_query, limit: 50
      end

    search_query = build_abac_filter(search_query, opts)

    Repo.all(search_query)
  end

  # Tokenized LIKE matching: split the query into meaningful tokens and match
  # any token in title/content/summary, so multi-keyword queries (e.g. from
  # LLM-structured prompts) recall memories that contain some of the words.
  # Falls back to whole-phrase LIKE when tokenization yields nothing.
  defp build_token_search_clause(query_text) when is_binary(query_text) do
    import Ecto.Query

    tokens = Acs.ClaimContext.meaningful_tokens(query_text)
    patterns = if tokens == [], do: [query_text], else: Enum.map(tokens, &"%#{&1}%")

    Enum.reduce(patterns, false, fn pattern, acc ->
      pattern_clause =
        dynamic(
          [m],
          like(m.title, ^pattern) or like(m.content, ^pattern) or like(m.summary, ^pattern)
        )

      if acc == false, do: pattern_clause, else: dynamic([], ^acc or ^pattern_clause)
    end)
  end

  @doc """
  Converts an Acs.Memory.Schema Ecto struct to a string-keyed attrs map
  suitable for Acs.Memory.new/1. Handles JSON field decoding and type conversions.
  """
  def schema_to_memory_attrs(%Acs.Memory.Schema{} = schema) do
    %{
      "id" => public_id(schema.id, schema.org),
      "kind" => schema.kind,
      "status" => schema.status,
      "title" => schema.title,
      "summary" => schema.summary,
      "content" => schema.content,
      "scope_path" => schema.scope_path,
      "importance" => schema.importance,
      "audience" => schema.audience,
      "repo" => schema.repo,
      "origin" => schema.origin,
      "tags" => decode_json_field(schema.tags_json),
      "triggers" => decode_json_field(schema.triggers_json),
      "failure_modes" => decode_json_field(schema.failure_modes_json),
      "related_memories" => decode_json_field(schema.related_memories_json),
      "verification" => decode_json_field(schema.verification_json),
      "revalidation" => decode_json_field(schema.revalidation_json),
      "org" => schema.org,
      "created_by" => decode_json_field(schema.created_by_json),
      "team" => schema.team,
      "project" => schema.project,
      "visibility" => schema.visibility,
      "authority_sort_order" => schema.authority_sort_order,
      "created_at" => format_datetime(schema.created_at),
      "updated_at" => format_datetime(schema.updated_at)
    }
  end

  @doc false
  def storage_id(org, memory_id) when is_binary(memory_id) do
    org = org || Acs.Org.current()
    if org == Acs.Org.configured(), do: memory_id, else: org <> ":" <> memory_id
  end

  @doc false
  def public_id(storage_id, org) when is_binary(storage_id) do
    org = org || Acs.Org.current()

    if org == Acs.Org.configured(),
      do: storage_id,
      else: String.replace_prefix(storage_id, org <> ":", "")
  end

  defp decode_json_field(nil), do: nil

  defp decode_json_field(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp decode_json_field(_), do: nil

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: dt |> DateTime.to_iso8601()
  defp format_datetime(%NaiveDateTime{} = ndt), do: ndt |> NaiveDateTime.to_iso8601()

  defp parse_datetime(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp parse_datetime(dt) when is_struct(dt, DateTime), do: DateTime.truncate(dt, :second)

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp apply_scope_path_filter(query, nil), do: query

  defp apply_scope_path_filter(query, scope_path) when is_binary(scope_path) do
    import Ecto.Query

    if String.contains?(scope_path, ["%", "_"]) do
      from m in query, where: m.scope_path == ^scope_path
    else
      from m in query, where: like(m.scope_path, ^"#{scope_path}%")
    end
  end

  defp apply_audience_order(query, nil), do: query

  defp apply_audience_order(query, audience) when is_binary(audience) and audience != "" do
    import Ecto.Query

    from m in query,
      order_by: [desc: fragment("CASE WHEN ? = ? THEN 1 ELSE 0 END", m.audience, ^audience)]
  end

  defp apply_audience_order(query, _), do: query

  # Repo scoping. `repo` filters to exactly that repo. `repo_mode: :local`
  # narrows to the current repo + org-wide (repo IS NULL); `:exact` narrows to
  # the current repo only; org-wide (repo IS NULL) stays eligible unless `:exact`.
  # `:blended` (default) applies no repo filter — ranking down-ranks other repos
  # instead (see hybrid_search).
  defp apply_repo_filter(query, opts) do
    import Ecto.Query

    cond do
      repo = opts[:repo] ->
        from m in query, where: m.repo == ^repo

      opts[:repo_mode] == :exact and is_binary(opts[:current_repo]) ->
        from m in query, where: m.repo == ^opts[:current_repo]

      opts[:repo_mode] == :local and is_binary(opts[:current_repo]) ->
        from m in query, where: m.repo == ^opts[:current_repo] or is_nil(m.repo)

      true ->
        query
    end
  end

  # Personal = creator-only (no rank gate). Shared ranked memories require
  # viewer clearance (memory.authority_sort_order >= viewer order). Unranked stay open.
  # Role never bypasses clearance — admin/service keys use their authority_level_slug.
  defp build_abac_filter(query, opts) do
    import Ecto.Query

    # ponytail: background jobs (auditor, dedupe scans) act for no principal and must see
    # every memory to process it. Never set :system on a request/MCP path.
    if opts[:system] do
      query
    else
      apply_abac_filter(query, opts)
    end
  end

  defp apply_abac_filter(query, opts) do
    import Ecto.Query

    agent_id = agent_id_or_sentinel(opts[:agent_id])

    viewer_order =
      cond do
        is_integer(opts[:authority_sort_order]) ->
          opts[:authority_sort_order]

        true ->
          org = opts[:org] || Acs.Org.current()
          Acs.AuthorityLevels.viewer_sort_order(org, opts[:authority_level_slug])
      end

    # personal → owner only; shared → unranked OR M >= V
    from m in query,
      where:
        fragment(
          """
          (COALESCE(?, 'org') = 'personal' AND ? = ?)
          OR (
            COALESCE(?, 'org') != 'personal'
            AND (? IS NULL OR ? >= ?)
          )
          """,
          m.visibility,
          m.created_by_agent,
          ^agent_id,
          m.visibility,
          m.authority_sort_order,
          m.authority_sort_order,
          ^viewer_order
        )
  end

  # ponytail: sentinel never matches a real agent id when caller has no identity
  defp agent_id_or_sentinel(id) when is_binary(id) and id != "", do: id
  defp agent_id_or_sentinel(_), do: "__no_agent__"
end
