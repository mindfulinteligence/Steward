defmodule Acs.MCP.Tools.MemoryHandlers do
  @moduledoc """
  Handles knowledge memory MCP tools for the ACS memory system.

  ## Purpose

  Implements handler functions for the knowledge memory lifecycle:
  saving memories (with duplicate detection via exact ID, semantic
  similarity, and lexical title match), listing/searching memories,
  updating memory status, and generating guidance packets.

  ## Key Functions

  - `save_memory/1` — Creates a new memory with multi-layer duplicate
    detection (exact ID, semantic vector similarity, lexical title match)
  - `query_memories/1` — Unified query tool: if `query` is provided does
    hybrid search (semantic + FTS); otherwise lists memories with filters
  - `set_memory_status/1` — Updates memory status (approved, rejected,
    stale, deprecated)
  - `generate_guidance_packet/1` — Generates structured guidance for a
    scope path or task ID

  """
  require Logger

  def save_memory(args) do
    ctx = Acs.Abac.from_args(args)
    org = Acs.Org.current()

    creator_id = args["_auth_attribution"] || args["_auth_agent_id"] || Acs.Org.developer_name()

    creator_type =
      if is_binary(creator_id) and String.contains?(creator_id, "@"),
        do: "user",
        else: "developer_key"

    args = normalize_about_args(args)

    # Kick off the embedding BEFORE the intake LLM review so the two expensive
    # network calls (~4-6s LLM + ~1.5-2s embed) run concurrently instead of
    # serially. The task is awaited exactly once in the save path and its result
    # is reused for both duplicate detection and storage.
    embed_task = maybe_spawn_embed_task(args)

    {:ok, intake} = Acs.Memory.Intake.review(args)
    args = merge_intake_into_args(args, intake)

    person = resolve_about_person_record(args, org)

    cond do
      about_entity?(args) and not explicit_visibility?(args) ->
        shutdown_embed_task(embed_task)
        {:ok, scope_choice_payload(args, person, intake)}

      blocking_intake?(intake, args) ->
        shutdown_embed_task(embed_task)
        {:ok, intake_questions_payload(args, intake)}

      true ->
        do_save_memory(args, ctx, org, creator_id, creator_type, person, intake, embed_task)
    end
  end

  defp do_save_memory(args, ctx, org, creator_id, creator_type, person, intake, embed_task) do
    kind = args["kind"]
    title = args["title"]
    content = args["content"]
    scope_path = args["scope_path"]
    tags = coerce_string_list(args["tags"])
    triggers = coerce_string_list(args["triggers"])
    importance = args["importance"] || 3
    summary = args["summary"]
    failure_modes = args["failure_modes"] || []
    team = args["team"]
    project = args["project"]

    {visibility, tags} = resolve_visibility_and_tags(args, person, tags)

    # Stamp from the writer’s clearance, not the about-person’s directory rank.
    authority_sort_order = writer_authority_sort_order(args, org)

    # Repo context: prefer the agent's current task file paths (most precise),
    # fall back to the session repo declared in the coding system prompt.
    repo = current_repo(args)

    memory_map =
      %{
        "id" =>
          Acs.Memory.generate_id(%{
            "kind" => kind,
            "title" => title,
            "scope_path" => scope_path,
            "repo" => repo
          }),
        "kind" => kind,
        "title" => title,
        "summary" => summary,
        "content" => content,
        "scope_path" => scope_path,
        "repo" => repo,
        "importance" => importance,
        "audience" => args["_auth_audience"],
        "tags" => tags,
        "triggers" => triggers,
        "failure_modes" => failure_modes,
        "created_by" => %{
          "type" => creator_type,
          "id" => creator_id,
          "org" => org
        },
        "org" => org,
        "team" => team,
        "project" => project,
        "visibility" => visibility,
        "authority_sort_order" => authority_sort_order
      }
      |> Acs.MCP.MemoryProvenance.enrich_memory_map(args)

    memory_map =
      case Acs.Abac.memory_status_for_write(ctx, memory_map) do
        nil -> memory_map
        status -> Map.put(memory_map, "status", status)
      end

    with :ok <- Acs.Abac.validate_write(ctx, memory_map),
         :ok <- Acs.Memory.validate(memory_map) do
      memory = Acs.Memory.new(memory_map)

      case do_save_with_validation(memory, memory_map, embed_task,
             actor: %{type: creator_type, id: creator_id},
             source: "mcp",
             message: "Create memory #{memory.id}"
           ) do
        {:ok, result} ->
          {:ok, maybe_attach_sensitive_note(result, intake, visibility)}

        other ->
          other
      end
    else
      {:error, reasons} when is_list(reasons) ->
        {:error, "Validation failed: #{Enum.join(reasons, "; ")}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def query_memories(args) do
    query = args["query"]
    mode = args["mode"] || "auto"
    min_relevance = args["min_relevance"]
    current_repo = current_repo(args)

    base_opts = [
      scope_path: args["scope_path"] || args["scope"],
      kind: args["kind"],
      status: Acs.Memory.Search.resolve_status_filter(args["status"]),
      limit: args["limit"] || 50,
      org: Acs.Org.current(),
      allowed_teams: args["_auth_allowed_teams"],
      allowed_projects: args["_auth_allowed_projects"],
      agent_role: args["_auth_role"],
      agent_id: args["_auth_agent_id"],
      audience: args["_auth_audience"],
      authority_sort_order: args["_auth_authority_sort_order"],
      current_repo: current_repo,
      repo_mode: args["repo_mode"],
      repo: args["repo"],
      origin: args["origin"]
    ]

    if query && query != "" do
      search_opts = Keyword.put(base_opts, :mode, mode)

      {memories, scores} = Acs.Memory.Search.search_with_scores(query, search_opts)

      result =
        memories
        |> Enum.map(fn m ->
          %{
            id: m.id,
            kind: m.kind,
            status: m.status,
            title: m.title,
            summary: m.summary,
            scope_path: m.scope_path,
            importance: m.importance,
            content: String.slice(m.content || "", 0, 500),
            relevance: Map.get(scores, m.id),
            created_by: decode_created_by(m.created_by_json),
            visibility: m.visibility,
            repo: repo_label(m.repo, current_repo),
            origin: m.origin
          }
        end)
        |> maybe_filter_by_relevance(min_relevance)

      {:ok, %{memories: result, count: length(result), mode: mode}}
    else
      memories = Acs.Memory.Search.list(base_opts)

      result =
        Enum.map(memories, fn m ->
          %{
            id: m.id,
            kind: m.kind,
            status: m.status,
            title: m.title,
            scope_path: m.scope_path,
            importance: m.importance,
            created_at: m.created_at,
            updated_at: m.updated_at,
            created_by: decode_created_by(m.created_by_json),
            visibility: m.visibility,
            repo: repo_label(m.repo, current_repo),
            origin: m.origin
          }
        end)

      {:ok, %{memories: result, count: length(result)}}
    end
  end

  # Per product decision: the repo field appears ONLY when the result comes
  # from a repo different from the caller's current repo. Same-repo and
  # org-wide (repo nil) results stay unlabeled to avoid noise.
  defp repo_label(nil, _current_repo), do: nil
  defp repo_label(repo, current_repo) when repo == current_repo, do: nil
  defp repo_label(repo, _current_repo) when is_binary(repo), do: repo
  defp repo_label(_, _), do: nil

  defp maybe_filter_by_relevance(results, nil), do: results

  defp maybe_filter_by_relevance(results, min) when is_number(min) do
    Enum.filter(results, fn r -> r[:relevance] != nil && r[:relevance] >= min end)
  end

  defp maybe_filter_by_relevance(results, _), do: results

  def set_memory_status(args) do
    memory_id = args["memory_id"]
    status = args["status"]

    valid_statuses = ~w(approved rejected stale deprecated)
    chat? = Acs.MCP.Audience.normalize(args["_auth_audience"]) == :chat
    governor? = args["_auth_role"] == "admin"

    cond do
      status not in valid_statuses ->
        {:error, "Invalid status '#{status}'. Must be one of: #{Enum.join(valid_statuses, ", ")}"}

      chat? and status not in ~w(stale deprecated) ->
        {:error,
         "Chat can only mark memories stale or deprecated. Use status: \"stale\" (outdated) or \"deprecated\" (retired)."}

      status in ~w(approved rejected) and not governor? ->
        {:error, "Only organization admins can approve or reject company memories."}

      true ->
        ctx = Acs.Abac.from_args(args)

        case Acs.Memory.Indexer.get_memory(memory_id, Acs.Org.current()) do
          nil ->
            {:error, "Memory not found"}

          existing ->
            if Acs.Abac.can_edit?(ctx, existing) do
              actor_id = args["_auth_attribution"] || args["_auth_agent_id"] || "unknown"

              actor_type =
                if is_binary(actor_id) and String.contains?(actor_id, "@"),
                  do: "user",
                  else: "developer_key"

              transition_memory_status(
                args,
                memory_id,
                status,
                actor_type,
                actor_id
              )
            else
              {:error, "Access denied: cannot edit memories at or above your clearance"}
            end
        end
    end
  end

  defp transition_memory_status(args, memory_id, status, actor_type, actor_id) do
    case Acs.Memory.Store.transition(memory_id, status,
           org: Acs.Org.current(),
           actor: %{type: actor_type, id: actor_id},
           source: "mcp",
           reason: args["notes"],
           message: args["notes"] || "Transition memory #{memory_id} to #{status}"
         ) do
      {:ok, _result} ->
        {:ok, %{status: status, memory_id: memory_id, message: "Memory #{status}"}}

      {:error, reason} ->
        {:error, "Failed to update memory status: #{inspect(reason)}"}
    end
  end

  def generate_guidance_packet(args) do
    scope_path = args["scope_path"] || args["scope"]
    task_id = args["task_id"]
    allowed_teams = args["_auth_allowed_teams"]
    allowed_projects = args["_auth_allowed_projects"]
    agent_role = args["_auth_role"]
    agent_id = args["_auth_agent_id"]
    authority_sort_order = args["_auth_authority_sort_order"]

    with {:ok, mode} <- resolve_guidance_mode(args) do
      packet =
        cond do
          task_id && task_id != "" ->
            Acs.Memory.Guidance.for_task(task_id,
              tier: :full,
              mode: mode,
              allowed_teams: allowed_teams,
              allowed_projects: allowed_projects,
              agent_role: agent_role,
              agent_id: agent_id,
              authority_sort_order: authority_sort_order,
              authority_level_slug: args["_auth_authority_level"]
            )

          scope_path && scope_path != "" ->
            Acs.Memory.Guidance.generate(scope_path,
              tier: :full,
              mode: mode,
              allowed_teams: allowed_teams,
              allowed_projects: allowed_projects,
              agent_role: agent_role,
              agent_id: agent_id,
              authority_sort_order: authority_sort_order
            )

          true ->
            Acs.Memory.Guidance.generate("",
              tier: :full,
              mode: mode,
              allowed_teams: allowed_teams,
              allowed_projects: allowed_projects,
              agent_role: agent_role,
              agent_id: agent_id,
              authority_sort_order: authority_sort_order
            )
        end

      {:ok, packet}
    end
  end

  # --- entity / intake / visibility ---

  defp normalize_about_args(args) do
    # Legacy aliases → about_*
    type =
      blank_to_nil(args["about_type"]) ||
        if about_person_fields?(args), do: "person", else: nil

    name =
      blank_to_nil(args["about_name"]) ||
        blank_to_nil(args["about_person_name"] || args["source_person_name"])

    email =
      blank_to_nil(args["about_email"]) ||
        blank_to_nil(args["about_person_email"] || args["source_person_email"])

    args
    |> Map.put("about_type", type)
    |> Map.put("about_name", name)
    |> Map.put("about_email", email)
  end

  defp about_person_fields?(args) do
    not is_nil(blank_to_nil(args["about_person_email"] || args["source_person_email"])) or
      not is_nil(blank_to_nil(args["about_person_name"] || args["source_person_name"]))
  end

  defp merge_intake_into_args(args, intake) do
    args
    |> Map.put("about_type", args["about_type"] || intake.about_type)
    |> Map.put("about_name", args["about_name"] || intake.about_name)
    |> Map.put("about_email", args["about_email"] || intake.about_email)
  end

  defp resolve_about_person_record(args, org) do
    if args["about_type"] == "person" or not is_nil(args["about_email"]) or
         not is_nil(args["about_name"]) do
      Acs.PersonStatus.get(org, email: args["about_email"], name: args["about_name"])
    else
      nil
    end
  end

  defp about_entity?(args) do
    not is_nil(args["about_type"]) or not is_nil(args["about_name"]) or
      not is_nil(args["about_email"])
  end

  defp explicit_visibility?(args) do
    truthy?(args["confidential"]) or
      (is_binary(args["visibility"]) and args["visibility"] != "")
  end

  # Blocking: not an eternal truth, or intake quality questions (except sensitive —
  # sensitive saves with a note). Skip when intake_confirmed.
  defp blocking_intake?(intake, args) do
    if truthy?(args["intake_confirmed"]) do
      false
    else
      not intake.is_eternal_truth or
        Enum.any?(intake.questions, fn q -> q["id"] not in ["sensitive", "scope"] end)
    end
  end

  defp scope_choice_payload(args, person, intake) do
    who =
      cond do
        match?(%Acs.PersonStatus{}, person) ->
          [person.name, person.status, person.rank && "rank:#{person.rank}"]
          |> Enum.reject(&(is_nil(&1) or &1 == ""))
          |> Enum.join(" · ")

        args["about_type"] == "company" and is_binary(args["about_name"]) ->
          "company #{args["about_name"]}"

        is_binary(args["about_name"]) ->
          args["about_name"]

        is_binary(args["about_email"]) ->
          args["about_email"]

        true ->
          args["about_type"] || "this entity"
      end

    %{
      status: "needs_scope_choice",
      saved: false,
      question:
        "This memory is about #{who}. At what level should it be scoped? Ask the user, then retry with visibility (or confidential: true for personal).",
      allowed_teams: List.wrap(args["_auth_allowed_teams"]),
      options: [
        %{
          visibility: "org",
          label: "Org — organization-wide label (clearance still applies)"
        },
        %{
          visibility: "team",
          label: "Team — collaboration label for a team (also pass team:); not a hard wall"
        },
        %{
          visibility: "project",
          label:
            "Project — collaboration label for a project (also pass project:); not a hard wall"
        },
        %{visibility: "personal", label: "Personal — only the saver can see it"}
      ],
      about: %{
        type: args["about_type"],
        name: args["about_name"],
        email: args["about_email"],
        person: person && Acs.PersonStatus.to_map(person)
      },
      intake: intake_summary(intake),
      retry_hint:
        "Retry save_memory with visibility: org|team|project|personal (team/project require team/project fields)."
    }
  end

  defp intake_questions_payload(args, intake) do
    %{
      status: "needs_input",
      saved: false,
      question:
        intake.notes ||
          "Intake needs clarification before saving. Ask the user, then retry with intake_confirmed: true (and any fixes).",
      questions: intake.questions,
      suggested_title: intake.suggested_title,
      suggested_kind: intake.suggested_kind,
      suggested_sensitive: intake.suggested_sensitive,
      suggested_visibility: intake.suggested_visibility,
      about: %{
        type: args["about_type"],
        name: args["about_name"],
        email: args["about_email"]
      },
      intake: intake_summary(intake),
      retry_hint: "Retry save_memory with answers applied and intake_confirmed: true."
    }
  end

  defp maybe_attach_sensitive_note(result, intake, visibility) do
    if intake.suggested_sensitive and visibility in [nil, "org"] do
      result
      |> Map.put(:suggested_sensitive, true)
      |> Map.put(
        :note,
        "Saved, but this looks sensitive. Ask the user if it should be personal (visibility: personal / confidential: true)."
      )
      |> Map.put(:suggested_visibility, intake.suggested_visibility || "personal")
      |> Map.put(:intake, intake_summary(intake))
    else
      Map.put(result, :intake, intake_summary(intake))
    end
  end

  defp intake_summary(intake) do
    %{
      source: intake.source,
      suggested_sensitive: intake.suggested_sensitive,
      suggested_visibility: intake.suggested_visibility,
      suggested_title: intake.suggested_title,
      suggested_kind: intake.suggested_kind,
      notes: intake.notes
    }
  end

  defp writer_authority_sort_order(args, org) do
    cond do
      is_integer(args["_auth_authority_sort_order"]) ->
        args["_auth_authority_sort_order"]

      true ->
        Acs.AuthorityLevels.viewer_sort_order(org, args["_auth_authority_level"])
    end
  end

  defp resolve_visibility_and_tags(args, person, tags) do
    confidential? = truthy?(args["confidential"])

    visibility =
      cond do
        confidential? -> "personal"
        is_binary(args["visibility"]) and args["visibility"] != "" -> args["visibility"]
        true -> "org"
      end

    tags =
      tags
      |> maybe_put_tag(args["about_type"], "about-type:")
      |> maybe_put_tag(args["about_name"], "about-name:")
      |> maybe_put_tag(args["about_email"], "about-email:")
      |> maybe_put_tag(person && person.email, "person-email:")
      |> maybe_put_tag(person && person.name, "person-name:")
      |> maybe_put_tag(person && person.status, "person-status:")
      |> maybe_put_tag(person && person.rank, "person-rank:")

    tags =
      if confidential? or visibility == "personal",
        do: maybe_put_tag(tags, "confidential", ""),
        else: tags

    {visibility, tags}
  end

  defp maybe_put_tag(tags, nil, _prefix), do: tags
  defp maybe_put_tag(tags, "", _prefix), do: tags

  defp maybe_put_tag(tags, value, "") when is_binary(value) do
    if value in tags, do: tags, else: [value | tags]
  end

  defp maybe_put_tag(tags, value, prefix) when is_binary(value) and is_binary(prefix) do
    tag = prefix <> value
    if tag in tags, do: tags, else: [tag | tags]
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("yes"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    t = String.trim(s)
    if t == "", do: nil, else: t
  end

  defp blank_to_nil(_), do: nil

  defp resolve_guidance_mode(args) do
    case parse_guidance_mode(args["mode"] || args["audience"]) do
      {:ok, mode} ->
        {:ok, mode}

      {:error, _} = err ->
        err

      :default ->
        audience = Acs.MCP.Audience.from_args(args)
        {:ok, Acs.MCP.Audience.to_guidance_mode(audience)}
    end
  end

  defp parse_guidance_mode(nil), do: :default
  defp parse_guidance_mode("mcp"), do: {:ok, :mcp}
  defp parse_guidance_mode("coding"), do: {:ok, :mcp}
  defp parse_guidance_mode("knowledge"), do: {:ok, :knowledge}
  defp parse_guidance_mode("chat"), do: {:ok, :knowledge}

  defp parse_guidance_mode(mode) when is_binary(mode),
    do: {:error, "Invalid mode '#{mode}'. Use mcp|coding or knowledge|chat"}

  # Layer 1: Check for exact duplicate by ID (same kind + same normalized title)
  defp check_exact_memory_duplicate(id) do
    case Acs.Memory.Indexer.get_memory(id, Acs.Org.current()) do
      nil ->
        :ok

      %{title: existing_title} ->
        {:error,
         "A memory with the same ID already exists: '#{existing_title}'. Use a different title or kind to avoid duplication."}
    end
  end

  # Layer 2 & 3: Check for semantic/lexical duplicates.
  #
  # `embedding_result` is the pre-computed embedding from the background task:
  #   {:ok, embedding} | {:error, reason} | :skipped
  defp check_semantic_memory_duplicate(%Acs.Memory{} = memory, {:ok, embedding}) do
    # Layer 2: Vector similarity search with high threshold
    current_storage_id = Acs.Memory.Indexer.storage_id(memory.org, memory.id)

    similar =
      Acs.Memory.VectorIndex.search_threshold(embedding, 0.92)
      |> Enum.filter(&tenant_embedding?(&1.memory_id, memory.org))

    # Exclude the memory itself (in case of re-save) and find strongest match
    case Enum.reject(similar, fn s -> s.memory_id == current_storage_id end) do
      [most_similar | _] ->
        public_id = Acs.Memory.Indexer.public_id(most_similar.memory_id, memory.org)
        other = Acs.Memory.Indexer.get_memory(public_id, memory.org)
        other_title = if other, do: other.title, else: public_id

        {:error,
         "A similar memory already exists (cosine similarity: #{Float.round(most_similar.similarity, 4)}): '#{other_title}'. Please review existing memories before creating a new one."}

      [] ->
        # Layer 3 still applies when embeddings are up but nothing is near-duplicate.
        check_lexical_memory_duplicate(memory.title, memory.scope_path)
    end
  end

  # Layer 3 fallback when embedding is unavailable (Ollama down, timeout, or
  # non-embeddable kind): lexical comparison only.
  defp check_semantic_memory_duplicate(%Acs.Memory{} = memory, _embedding_result) do
    check_lexical_memory_duplicate(memory.title, memory.scope_path)
  end

  # Layer 3 fallback: Check for memory with same title at the same scope
  defp check_lexical_memory_duplicate(title, scope_path) do
    title_lower = String.downcase(title)

    existing = Acs.Memory.Indexer.list_memories(scope_path: scope_path, org: Acs.Org.current())

    case Enum.find(existing, fn m ->
           m.scope_path == scope_path && String.downcase(m.title) == title_lower
         end) do
      nil ->
        :ok

      match ->
        {:error,
         "A memory with the title '#{match.title}' already exists at scope '#{scope_path}'. Duplicate titles at the same scope are not allowed."}
    end
  end

  defp tenant_embedding?(memory_id, org) do
    org = org || Acs.Org.current()

    if org == Acs.Org.configured() do
      not String.contains?(memory_id, ":")
    else
      String.starts_with?(memory_id, org <> ":")
    end
  end

  # Stores the pre-computed embedding (computed once at the start of the save) so
  # the retrieval text is never re-embedded after the duplicate check.
  defp store_memory_embedding(%Acs.Memory{} = memory, embedding_result) do
    if memory.kind in Acs.Memory.embeddable_kinds() do
      case embedding_result do
        {:ok, embedding} ->
          storage_id = Acs.Memory.Indexer.storage_id(memory.org, memory.id)

          Acs.Memory.VectorIndex.upsert_embedding(
            storage_id,
            embedding,
            memory.org,
            Acs.Repo,
            repo: memory.repo,
            origin: memory.origin
          )

        {:error, reason} ->
          Logger.warning("[Tools] Could not store embedding for #{memory.id}: #{reason}")

        :skipped ->
          Logger.warning("[Tools] Skipping embedding for #{memory.id}: no embedding computed")
      end
    else
      Logger.debug("[Tools] Skipping embedding for non-embeddable kind: #{memory.kind}")
    end

    :ok
  end

  defp decode_created_by(nil), do: nil

  defp decode_created_by(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp decode_created_by(_), do: nil

  defp maybe_spawn_embed_task(args) do
    case build_preview_memory(args) do
      nil ->
        nil

      memory ->
        Task.async(fn ->
          retrieval_text = Acs.Memory.Embedding.memory_to_retrieval_text(memory)
          Acs.Memory.Embedding.embed_text(retrieval_text)
        end)
    end
  end

  # Builds a lightweight %Acs.Memory{} purely to derive the retrieval text that
  # will be embedded. Acs.Memory.new/1 is a passthrough (it does not rewrite
  # title/kind/content/scope_path), so this text matches the final saved memory.
  # Returns nil for non-embeddable kinds so no embedding work is started.
  defp build_preview_memory(args) do
    if args["kind"] in Acs.Memory.embeddable_kinds() do
      Acs.Memory.new(%{
        "kind" => args["kind"],
        "title" => args["title"],
        "summary" => args["summary"],
        "content" => args["content"],
        "scope_path" => args["scope_path"],
        "failure_modes" => args["failure_modes"] || []
      })
    end
  end

  defp shutdown_embed_task(nil), do: :ok
  defp shutdown_embed_task(task), do: Task.shutdown(task, :brutal_kill)

  # Awaits the pre-computed embedding task exactly once. Always returns
  # {:ok, embedding_result} so an embedding failure degrades to the lexical
  # duplicate check rather than failing the save.
  defp await_embedding(nil), do: {:ok, :skipped}

  defp await_embedding(task) do
    result =
      try do
        Task.await(task, 35_000)
      catch
        :exit, _reason -> {:error, :embedding_timed_out}
      end

    {:ok, result}
  end

  defp do_save_with_validation(memory, memory_map, embed_task, store_opts) do
    with :ok <- check_exact_memory_duplicate(memory.id),
         {:ok, embedding_result} <- await_embedding(embed_task),
         :ok <- check_semantic_memory_duplicate(memory, embedding_result),
         {:ok, conflict_flags} <- Acs.Memory.Conflict.check_before_save(memory_map),
         {:ok, _result} <- Acs.Memory.Store.save(memory, store_opts) do
      store_memory_embedding(memory, embedding_result)

      {:ok,
       %{
         id: memory.id,
         status: memory.status,
         conflict_flags: conflict_flags,
         message: "Memory saved with status: #{memory.status}"
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # MCP clients sometimes send JSON-encoded arrays as strings.
  defp coerce_string_list(nil), do: []
  defp coerce_string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)

  defp coerce_string_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp coerce_string_list(_), do: []

  # The first successful file lock establishes task/session scope. Never infer
  # a writer repo from a relative path or from the server's own checkout.
  defp current_repo(args) do
    repo_from_task(args) || args["_auth_repo"]
  end

  defp repo_from_task(args) do
    with agent_id when is_binary(agent_id) <- args["_auth_agent_id"],
         %{current_task_id: task_id} when is_binary(task_id) <-
           Acs.Acs.get_agent_status(agent_id),
         %{repo: repo} when is_binary(repo) <- Acs.Acs.get_task(task_id) do
      repo
    else
      _ -> nil
    end
  end
end
