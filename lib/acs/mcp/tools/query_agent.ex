defmodule Acs.MCP.Tools.QueryAgent do
  @moduledoc """
  The `ask` tool — structured-param query interface for collaborators.

  Accepts filters and returns a formatted markdown summary of matched
  memories, documents, skills, and agent status. No server-side NL parsing —
  the client AI translates the human's natural language into these
  structured parameters.

  Documents: when search returns 1–2 hits each under ~5k tokens, the full body
  is inlined. Otherwise each hit includes a short excerpt plus a ready-to-run
  fetch call (`steward_ask` action `document`).

  Skills: never inlined in search — always excerpts plus a fetch call
  (`steward_ask` action `skill`). Agents must load matching skills before acting.

  ## Parameters

  - `kind` — memory kind filter (context, status, work_note, activity, ...)
  - `team` — team scope filter
  - `project` — project scope filter
  - `content_query` — free-text search string for memories, documents, and skills
  - `document_type` — document type filter (spec, knowledge, project, marketing, deliverable, policy, process, guideline, reference)
  - `status` — memory status filter (default: approved; use "all" for no filter)
  - `limit` — max results per category (default 10)
  - `include_documents` — whether to search documents too (default true)
  - `include_skills` — whether to search skills too (default true)
  - `include_agent_status` — whether to include agent presence (default true)
  """

  require Logger

  alias Acs.Skills.Store

  import Ecto.Query, only: [from: 2]

  @default_limit 10
  @max_limit 50
  @default_skill_min_score 0.45
  # ponytail: ~4 chars/token; upgrade if we adopt a real tokenizer
  @max_inline_tokens 5_000
  @max_inline_hits 2
  @chars_per_token 4
  @excerpt_chars 400

  @doc """
  Executes an `ask` query against memories, documents, skills, and agent status.

  Always scoped to `Acs.Org.current/0` (passed explicitly into Tasks and search opts).
  """
  def ask(args) do
    limit = clamp_limit(args["limit"])
    abac_opts = extract_abac(args)
    org = Acs.Org.current()
    embedding = maybe_embed_query(args["content_query"])

    search_opts =
      abac_opts
      |> Keyword.put(:org, org)
      |> Keyword.put(:current_repo, args["_auth_repo"])
      |> Keyword.put(:repo_mode, args["repo_mode"] || "blended")
      |> Keyword.put(:origin, args["origin"])
      |> maybe_put(:embedding, embedding)

    # Capture org for Task processes (Org.current/0 is process-local).
    mem_task =
      Task.async(fn ->
        Acs.Org.with_current(org, fn -> search_memories(args, search_opts, limit) end)
      end)

    doc_task =
      Task.async(fn ->
        Acs.Org.with_current(org, fn -> search_documents(args, search_opts, limit) end)
      end)

    skill_task =
      Task.async(fn ->
        Acs.Org.with_current(org, fn -> search_skills(args, search_opts, limit) end)
      end)

    agents = agent_status(args)

    results = [
      Task.await(mem_task, 35_000),
      Task.await(doc_task, 35_000),
      Task.await(skill_task, 35_000),
      agents
    ]

    {:ok, format_response(args, results)}
  end

  # One Ollama call shared by memory + document + skill hybrid search.
  # Retrieval queries are truncated (embed latency scales with input length);
  # storage indexing is never truncated.
  defp maybe_embed_query(query) when is_binary(query) and query != "" do
    case Acs.Memory.Embedding.embed_text(Acs.Memory.Embedding.retrieval_query(query)) do
      {:ok, embedding} -> embedding
      _ -> nil
    end
  end

  defp maybe_embed_query(_), do: nil

  defp search_memories(args, search_opts, limit) do
    query = args["content_query"]
    kind = args["kind"]
    status = Acs.Memory.Search.resolve_status_filter(args["status"])
    team = args["team"]
    project = args["project"]

    opts =
      search_opts
      |> Keyword.merge(limit: limit)
      |> maybe_put(:kind, kind)
      |> maybe_put(:status, status)

    case {query, team, project} do
      {q, nil, nil} when is_binary(q) and q != "" ->
        mems = Acs.Memory.Search.search(q, opts)
        {:memory_results, mems}

      {nil, nil, nil} ->
        mems = Acs.Memory.Search.list(opts)
        {:memory_results, mems}

      _ ->
        list_opts = opts
        list_opts = if team, do: Keyword.put(list_opts, :team, team), else: list_opts
        list_opts = if project, do: Keyword.put(list_opts, :project, project), else: list_opts
        mems = Acs.Memory.Indexer.list_memories(list_opts)
        {:memory_results, mems}
    end
  end

  defp search_documents(args, search_opts, limit) do
    if args["include_documents"] == false do
      {:document_results, []}
    else
      query = args["content_query"]
      doc_type = args["document_type"]
      # Specs search accepts :embedding / :org from the shared ask opts.
      spec_opts =
        Keyword.take(search_opts, [:embedding, :org, :repo, :current_repo, :repo_mode, :origin])

      entries =
        cond do
          is_binary(query) and query != "" ->
            case Acs.Specs.Search.search(query, spec_opts) do
              {:ok, results} -> results
              _ -> []
            end

          is_binary(doc_type) and doc_type != "" ->
            case Acs.Specs.Search.search("") do
              {:ok, results} ->
                results
                |> Enum.filter(fn e -> is_entry_match?(e, doc_type) end)
                |> Enum.take(limit)

              _ ->
                []
            end

          true ->
            case Acs.Specs.Search.search("") do
              {:ok, results} -> Enum.take(results, limit)
              _ -> []
            end
        end

      {:document_results, Acs.Abac.filter(entries, Acs.Abac.from_keyword(search_opts))}
    end
  end

  defp search_skills(args, search_opts, limit) do
    if args["include_skills"] == false do
      {:skill_results, []}
    else
      query = args["content_query"]

      skills =
        cond do
          is_binary(query) and query != "" ->
            related_skills(query, search_opts, limit)

          true ->
            []
        end

      {:skill_results, skills}
    end
  end

  # Prefer org-scoped vector hits with the shared embedding; fall back to lexical.
  defp related_skills(query, search_opts, limit) do
    vector_opts =
      search_opts
      |> Keyword.take([:embedding, :org, :repo, :current_repo, :repo_mode, :origin])
      |> Keyword.put(:limit, limit)

    case Acs.Skills.VectorSearch.search(query, vector_opts) do
      {:ok, scored} when is_list(scored) and scored != [] ->
        scored
        |> Enum.filter(&(&1.similarity >= @default_skill_min_score))
        |> Enum.take(limit)
        |> Enum.map(&enrich_skill/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        Store.search_skills(query)
        |> Enum.take(limit)
        |> Enum.map(&skill_summary/1)
    end
  end

  defp enrich_skill(%{skill_name: name, similarity: sim} = hit) do
    case Store.get_skill(name) do
      nil ->
        %{name: name, description: nil, tags: [], similarity: Float.round(sim, 4)}

      skill ->
        skill_summary(skill)
        |> Map.merge(Map.take(hit, [:repo, :origin]))
        |> Map.put(:similarity, Float.round(sim, 4))
    end
  end

  defp skill_summary(skill) do
    %{
      name: skill.name,
      description: skill.description,
      tags: skill.tags || [],
      when_to_use: Map.get(skill, :when_to_use) || Map.get(skill, "when_to_use")
    }
  end

  defp agent_status(args) do
    if args["include_agent_status"] == false do
      {:agent_status, []}
    else
      all_status = Acs.Acs.get_present_status()

      task_ids =
        all_status
        |> Enum.map(&Map.get(&1, :current_task_id))
        |> Enum.reject(&is_nil/1)

      slug_by_id =
        if task_ids == [] do
          %{}
        else
          Acs.Repo.all(
            from(t in Acs.Acs.Task,
              where: t.id in ^task_ids,
              select: {t.id, t.slug}
            )
          )
          |> Map.new()
        end

      agents =
        all_status
        |> Enum.map(fn s ->
          %{
            agent_id: Map.get(s, :agent_id),
            purpose: if(is_map(s), do: Map.get(s, :purpose), else: "unknown"),
            current_task: Map.get(slug_by_id, Map.get(s, :current_task_id))
          }
        end)

      {:agent_status, agents}
    end
  end

  defp format_response(_args, results) do
    mems = Keyword.get(results, :memory_results) || []
    docs = Keyword.get(results, :document_results) || []
    skills = Keyword.get(results, :skill_results) || []
    agents = Keyword.get(results, :agent_status) || []

    sections =
      []
      |> maybe_prepend(format_memories_section(mems))
      |> maybe_prepend(format_documents_section(docs))
      |> maybe_prepend(format_skills_section(skills))
      |> maybe_prepend(format_status_section(agents))

    %{
      response:
        if(sections == [],
          do: "No results found for your query.",
          else: Enum.join(sections, "\n")
        ),
      summary: %{
        memory_count: length(mems || []),
        document_count: length(docs || []),
        skill_count: length(skills || []),
        agent_count: length(agents || [])
      },
      relevant_skills: skills
    }
  end

  # Test seam for inline/catalog formatting.
  @doc false
  def render_documents(docs), do: format_documents_section(docs)

  @doc false
  def render_skills(skills), do: format_skills_section(skills)

  @doc false
  def under_inline_token_limit?(text), do: under_token_limit?(text)

  defp format_memories_section([]), do: nil
  defp format_memories_section(nil), do: nil

  defp format_memories_section(mems) do
    items =
      mems
      |> Enum.take(@max_limit)
      |> Enum.map(fn m ->
        id = if is_struct(m, Acs.Memory.Schema), do: m.id, else: Map.get(m, :id)
        title = if is_struct(m, Acs.Memory.Schema), do: m.title, else: Map.get(m, :title)
        kind = if is_struct(m, Acs.Memory.Schema), do: m.kind, else: Map.get(m, :kind)
        status = if is_struct(m, Acs.Memory.Schema), do: m.status, else: Map.get(m, :status)
        team_tag = if is_struct(m, Acs.Memory.Schema), do: m.team, else: Map.get(m, :team)
        content = if is_struct(m, Acs.Memory.Schema), do: m.content, else: Map.get(m, :content)

        meta = [kind, status]
        meta = if team_tag, do: meta ++ ["team:#{team_tag}"], else: meta

        body =
          if is_binary(content) and content != "" do
            "\n  #{String.replace(content, "\n", "\n  ")}"
          else
            ""
          end

        "- **#{title}** (`#{Enum.join(meta, ", ")}`) — #{id}#{body}"
      end)

    "## Memories (#{length(mems)})\n\n#{Enum.join(items, "\n")}"
  end

  defp format_documents_section([]), do: nil
  defp format_documents_section(nil), do: nil

  defp format_documents_section(docs) do
    resolved =
      docs
      |> Enum.take(@max_limit)
      |> Enum.map(&normalize_doc/1)
      |> Enum.reject(&is_nil/1)
      |> dedupe_docs()
      |> Enum.map(&resolve_full_document/1)

    if inline_bodies?(Enum.map(resolved, & &1.body)) do
      items =
        Enum.map(resolved, fn d ->
          title = d.title || d.path || "document"
          type_str = d.document_type || "document"

          """
          ### #{title} (`#{type_str}` · `#{d.app}/#{d.path}`)

          #{d.body}
          """
        end)

      "## Documents (#{length(resolved)}) — full content\n\n#{Enum.join(items, "\n")}"
    else
      items =
        Enum.map(resolved, fn d ->
          title = d.title || d.path || "document"
          type_str = d.document_type || "document"
          excerpt = excerpt(d.body)
          fetch = "steward_ask(action:\"document\", app:\"#{d.app}\", path:\"#{d.path}\")"

          """
          - **#{title}** (`#{type_str}`) — `#{d.app}/#{d.path}`
            Excerpt: #{excerpt}
            Full: `#{fetch}` (coding: `specs_get(app:, path:)`)
          """
        end)

      hint =
        "Excerpts only — not full bodies. If a hit is relevant, **fetch the full document** " <>
          "with the `steward_ask(action:\"document\", ...)` call above before acting. " <>
          "Never assume Steward cannot return document content."

      "## Documents (#{length(resolved)}) — excerpts\n\n#{Enum.join(items, "\n")}\n#{hint}"
    end
  end

  defp format_skills_section([]), do: nil
  defp format_skills_section(nil), do: nil

  # Skills are never inlined — agents must steward_ask(action:"skill") to load them.
  defp format_skills_section(skills) do
    skills
    |> Enum.take(@max_limit)
    |> Enum.map(&with_skill_body/1)
    |> format_skills_catalog()
  end

  defp format_skills_catalog(skills) do
    items =
      Enum.map(skills, fn s ->
        name = s[:name] || s["name"] || Map.get(s, :name)
        desc = s[:description] || s["description"] || Map.get(s, :description) || ""
        when_to = s[:when_to_use] || s["when_to_use"] || Map.get(s, :when_to_use) || ""
        tags = s[:tags] || s["tags"] || Map.get(s, :tags) || []
        body = s[:body] || Map.get(s, :body) || ""
        tag_str = if tags == [], do: "", else: " [#{Enum.join(tags, ", ")}]"
        excerpt_src = if is_binary(body) and body != "", do: body, else: desc
        excerpt = excerpt(excerpt_src)
        fetch = "steward_ask(action:\"skill\", name:\"#{name}\")"

        when_line =
          if is_binary(when_to) and when_to != "" do
            "\n          When to use: #{when_to}"
          else
            ""
          end

        """
        - **#{name}**#{tag_str}#{when_line}
          Excerpt: #{excerpt}
          Full: `#{fetch}` (coding: `skill_get(name:)`) — **required before following this procedure**
        """
      end)

    hint =
      "Skills are never fully inlined in search. If any skill fits what you are about to do, " <>
        "**fetch the procedure body** with `steward_ask(action:\"skill\", name:)` " <>
        "(coding: `skill_get(name:)`). Do not improvise a procedure when a matching skill is listed."

    "## Related Skills (#{length(skills)}) — excerpts (fetch required)\n\n#{Enum.join(items, "\n")}\n#{hint}"
  end

  defp excerpt(nil), do: "(no excerpt)"
  defp excerpt(""), do: "(no excerpt)"

  defp excerpt(text) when is_binary(text) do
    collapsed = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(collapsed) <= @excerpt_chars do
      collapsed
    else
      String.slice(collapsed, 0, @excerpt_chars) <> "…"
    end
  end

  defp excerpt(_), do: "(no excerpt)"

  defp normalize_doc(%Acs.Specs.Entry{} = e) do
    %{
      app: e.app,
      path: e.id,
      title: e.title,
      document_type: e.document_type || "spec",
      body: entry_body(e),
      chunk?: false
    }
  end

  defp normalize_doc(%{__rag_chunk: true} = c) do
    app = Map.get(c, :app)
    path = Map.get(c, :path)

    if is_binary(app) and is_binary(path) do
      %{
        app: app,
        path: path,
        title: nil,
        document_type: "chunk",
        body: Map.get(c, :content) || "",
        chunk?: true
      }
    end
  end

  defp normalize_doc(map) when is_map(map) do
    app = Map.get(map, :app) || Map.get(map, "app")
    path = Map.get(map, :path) || Map.get(map, "path") || Map.get(map, :id) || Map.get(map, "id")

    if is_binary(app) and is_binary(path) do
      %{
        app: app,
        path: path,
        title: Map.get(map, :title) || Map.get(map, "title"),
        document_type:
          Map.get(map, :document_type) || Map.get(map, "document_type") || "document",
        body:
          Map.get(map, :content) || Map.get(map, "content") || Map.get(map, :purpose) ||
            Map.get(map, "purpose") || "",
        chunk?: false
      }
    end
  end

  defp normalize_doc(_), do: nil

  defp dedupe_docs(docs) do
    docs
    |> Enum.reduce({[], MapSet.new()}, fn d, {acc, seen} ->
      key = "#{d.app}/#{d.path}"

      if MapSet.member?(seen, key) do
        {acc, seen}
      else
        {acc ++ [d], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
  end

  defp resolve_full_document(%{chunk?: true, app: app, path: path} = doc)
       when is_binary(app) and is_binary(path) do
    case Acs.Specs.Loader.load(app, path) do
      {:ok, entry} ->
        %{
          doc
          | body: entry_body(entry),
            title: entry.title || doc.title,
            document_type: entry.document_type || doc.document_type,
            chunk?: false
        }

      _ ->
        doc
    end
  end

  defp resolve_full_document(doc), do: doc

  defp entry_body(%Acs.Specs.Entry{content: c}) when is_binary(c) and c != "", do: c
  defp entry_body(%Acs.Specs.Entry{purpose: p}) when is_binary(p) and p != "", do: p
  defp entry_body(_), do: ""

  defp with_skill_body(s) do
    name = s[:name] || s["name"]
    desc = s[:description] || s["description"]
    tags = s[:tags] || s["tags"] || []
    when_to = s[:when_to_use] || s["when_to_use"]

    case Store.get_skill(name) do
      nil ->
        %{name: name, description: desc, tags: tags, when_to_use: when_to, body: ""}

      skill ->
        %{
          name: skill.name,
          description: skill.description || desc,
          tags: skill.tags || tags,
          when_to_use: Map.get(skill, :when_to_use) || Map.get(skill, "when_to_use") || when_to,
          body: skill.content || ""
        }
    end
  end

  defp inline_bodies?(bodies) when is_list(bodies) do
    length(bodies) in 1..@max_inline_hits and
      Enum.all?(bodies, fn body -> is_binary(body) and body != "" and under_token_limit?(body) end)
  end

  defp under_token_limit?(text) when is_binary(text) do
    div(String.length(text) + @chars_per_token - 1, @chars_per_token) <= @max_inline_tokens
  end

  defp under_token_limit?(_), do: false

  defp format_status_section([]), do: nil
  defp format_status_section(nil), do: nil

  defp format_status_section(agents) do
    items =
      agents
      |> Enum.map(fn a ->
        purpose = a[:purpose] || "unknown"
        task = a[:current_task]
        task_str = if task, do: " (task: #{task})", else: ""
        "- **#{a[:agent_id]}**: #{purpose}#{task_str}"
      end)

    "## Agent Status (#{length(agents)})\n\n#{Enum.join(items, "\n")}"
  end

  defp extract_abac(args) do
    []
    |> maybe_put(:allowed_teams, args["_auth_allowed_teams"])
    |> maybe_put(:allowed_projects, args["_auth_allowed_projects"])
    |> maybe_put(:agent_role, args["_auth_role"])
    |> maybe_put(:agent_id, args["_auth_agent_id"])
    |> maybe_put(:audience, args["_auth_audience"])
    |> maybe_put(:authority_sort_order, args["_auth_authority_sort_order"])
    |> maybe_put(:authority_level_slug, args["_auth_authority_level"])
  end

  defp clamp_limit(nil), do: @default_limit
  defp clamp_limit(n) when is_integer(n) and n > @max_limit, do: @max_limit
  defp clamp_limit(n) when is_integer(n) and n < 1, do: @default_limit
  defp clamp_limit(n) when is_integer(n), do: n
  defp clamp_limit(_), do: @default_limit

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp maybe_prepend(list, nil), do: list
  defp maybe_prepend(list, item), do: list ++ [item]

  defp is_entry_match?(%Acs.Specs.Entry{document_type: dt}, type), do: dt == type
  defp is_entry_match?(map, type) when is_map(map), do: Map.get(map, :document_type) == type
  defp is_entry_match?(_, _), do: false
end
