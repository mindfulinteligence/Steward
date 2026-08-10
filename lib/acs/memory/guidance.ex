defmodule Acs.Memory.Guidance do
  @moduledoc """
  Generates audience-specific guidance packets.

  Two **completely different** packet shapes (not the same map with empty fields):

  - **`:coding` / `:mcp`** — task workflow, file locks, tool refs, code specs
  - **`:chat` / `:knowledge`** — retrieve/answer/save org knowledge; no locks or coding protocols

  ## Token Budget (shared memory slices)
  - critical_axioms: max 5
  - warnings: max 3
  - relevant_patterns: max 5 (full tier)
  - compressed_knowledge: max ~2000 chars (full tier)
  """

  @critical_axioms_max 5
  @warnings_max 3
  @patterns_max 5
  @knowledge_max_chars 2000

  # ── Coding packet copy ──────────────────────────────────────────────

  @coding_workflow """
  Start: create or claim a task. Before the first lock, identify the local checkout: run `git rev-parse --show-toplevel`, read that checkout's `AGENTS_STEWARD.md`, and use its `Repo: <name>` value. Confirm with the human or coordinating agent that this is the intended repository, then call `lock_file(..., repo: "<name>", repo_confirmed: true)` for the first file. That first successful lock establishes the task/session repository; every later lock must use the same repo. Then: work → unlock_file → save (skill_save / specs_propose for specs or documents / save_memory) → release_work → submit_task_feedback last.
  No tasks? list_tasks or wait for the next user request. Scopes: code paths OR business domains (org/domain/topic).
  """

  @coding_file_locking """
  Before editing, lock every file. On the first lock for a task, pass the repo read from the current checkout's `AGENTS_STEWARD.md` (`Repo: <name>`) and `repo_confirmed: true` only after confirming it is the intended checkout. If that declaration is missing or the repository is not confirmed, ask the human; do not use the ACS server checkout or invent a repo. The first successful lock records the repo. A later repo mismatch is rejected. unlock_file when done (by path or task_id). 10-min auto-release. get_locked_files() to check.
  """

  @coding_memory """
  save_memory(kind, title, content, scope_path) — eternal truths only. Kinds: observation, learning, warning, pattern, bug, decision, invariant, axiom.

  Entity vs scope:
  - about_type person|company + about_name/about_email = who the fact is ABOUT, not who may read it
  - visibility org|team|project/personal = collaboration label / personal wall (confidential: true ⇒ personal)
  - data clearance: memories are stamped with the **writer's** authority level; readers see their level and lower (list_authority_levels). Unranked memories stay open. MCP role (admin/service) does not bypass clearance.

  Intake (LLM + heuristics) runs on every save:
  - about entity without visibility → needs_scope_choice (ask user, retry with visibility)
  - quality issues → needs_input (ask user, retry with intake_confirmed: true)
  - looks sensitive → still saves, returns suggested_sensitive note (ask if personal)

  Person directory: get_person_status / set_person_status for job title (optional directory rank). Member clearance is set on Members / set_member_authority_level.
  """

  @chat_memory """
  steward_write(kind:"memory") saves short eternal truths; memory_kind is the truth classification.

  Entity vs scope:
  - about_type person|company + about_name/about_email = who the fact is ABOUT
  - visibility = who may read it (confidential: true ⇒ personal)

  Intake asks before save when scope is missing or quality is unclear. needs_scope_choice includes allowed_teams; retry team visibility with one of those names.
  Person status: steward_ask(action:"person_status") → ask once → steward_write(kind:"person_status").
  Outdated? steward_write(kind:"memory_status", status:"stale") → save a corrected memory.
  """

  @coding_error """
  1) list_error_traces()  2) ack_error_trace(id)  3) fix → resolve_error_trace(id)  4) get_logs(level:"error") → connection_diagnostic()
  """

  @coding_tools """
  All tools callable by name. help(category, level) to list. get_logs(level: "error") when stuck.
  """

  @coding_specs_mismatch """
  Code differs from its module spec? Pause → identify diff → ask user which to update. Never assume one is wrong.
  """

  @coding_finish """
  Before release_work: pick one — skill_save (how-to) | specs_propose document_type+content (long doc) | specs_propose purpose/invariants (code spec) | save_memory (short truth). Then release_work → submit_task_feedback last. Feedback is a system review: (1) report stale/noisy memories/specs, (2) suggest improvements, (3) flag missing guidance.
  """

  @coding_store_choice """
  When a task is done, save to the store the first trigger that applies:
  1. Worked out a plan with the user (implementation, improvement, migration, remediation) → specs_propose a document under documents/plans/<slug>.
  2. Changed a code module's intent/contract → specs_propose a spec (purpose/invariants/workflows). Check query_specs(undocumented: true) first.
  3. Followed a repeatable multi-step procedure (deploy, secrets rotation, ingest, debug playbook, review) → skill_save.
  4. Produced a long shareable artifact (policy, brief, research, marketing) → specs_propose a document.
  5. Discovered a short eternal truth → save_memory.
  6. Otherwise → save nothing; do not force a save.
  """

  @coding_save_plan """
  If you and the user worked out a plan this session (implementation, improvement, migration, remediation), save it via specs_propose (document_type, title, content) under documents/plans/<kebab-slug> before release_work.
  """

  @coding_maintenance """
  Outdated? set_memory_status(id, "stale", notes) → save_memory corrected version → specs_propose for outdated specs/documents.
  """

  @coding_identity """
  get_present_status(agent_id: "") → assigned_agent_id. Use that name in all tool calls.
  """

  @coding_conventions """
  ## Knowledge structure (coding)
  Scopes: code paths OR org/domain/topic.
  - memories — short eternal truths (save_memory)
  - specs — code module docs via specs_propose (purpose, invariants, workflows)
  - documents — long non-code artifacts via specs_propose(document_type, title, content) under documents/<type>/<slug>
  - skills — step-by-step procedures (skill_get / skill_save)
  End of task pick one primary store (how-to / long doc / code spec / short truth).
  """

  @scope_hint """
  No scope_path was provided, so relevant_skills/relevant_specs only show org-wide top skills.
  For scope-relevant skills, specs, and knowledge, request guidance for a specific scope:
  pass scope_path when claiming work, or re-fetch guidance with scope_path: "org/domain/topic"
  (or a code path like "lib/acs/memory").
  """

  @scope_hint_chat """
  No scope was provided, so this packet only shows org-wide top skills.
  For scope-relevant skills, specs, and knowledge, ask again with a scope such as "org/domain/topic".
  """

  @repo_hint """
  The startup packet cannot reliably identify the agent's local checkout. Before the first lock,
  run `git rev-parse --show-toplevel`, read `<repo-root>/AGENTS_STEWARD.md`, and use its
  `Repo: <name>` declaration as `lock_file(repo: "<name>")`. If the file or declaration is
  missing, ask the human to add it; never use the ACS server checkout or invent a repo.
  Until the first successful lock, repository-specific saves are blocked; org-wide retrieval remains available.
  """

  @specs_instructions_short """
  specs_propose: code SPEC (purpose/invariants) when module intent changed; DOCUMENT (document_type+title+content) for policy/brief/research/marketing. Not truths or how-tos. query_specs finds both.
  """

  @specs_instructions """
  specs_propose saves specs (code) and documents (non-code). Spec: purpose, invariants, workflows. Document: document_type + title + content. query_specs searches both. query_specs(undocumented: true) finds code modules missing specs only.
  """

  @skills_instructions_short """
  Skills = step-by-step how-tos. skill_get before procedural work; skill_save for repeatable workflows (deploy, MCP/debug playbook, ingest, review) — not one-off notes. Else use specs_propose or save_memory.
  """

  @specs_instructions_chat """
  steward_write(kind:"document") saves long non-code artifacts via document_type + title + content. Not for short truths or how-to skills. Load the ingest-document skill first.
  """

  @skills_instructions_chat """
  Skills are step-by-step playbooks. Load with steward_ask(action:"skill"); save with steward_write(kind:"skill"). Include prerequisites, numbered steps, verification, and recovery.
  """

  # ── Chat packet copy ────────────────────────────────────────────────

  @chat_workflow """
  Retrieve with steward_ask(action:"search"); load procedures with action:"skill"; load document bodies with action:"document" (app + path from search).
  Documents: inline for 1–2 small hits; otherwise excerpts + fetch. Skills: never inlined — always fetch with action:"skill" when a listed skill fits the task. Never claim titles-only means content is unavailable.
  Follow surfaced process docs/skills (e.g. ask clarifying questions before filing tickets). Optionally use steward_work(action:"create", claim:true) for tracked work.
  Answer from ACS; if nothing matches, say so. Save truths/documents/skills and status changes with the matching steward_write kind.
  Feedback is steward_write(kind:"feedback"): report stale/wrong knowledge, improvements, and information gaps. task_id is optional for standalone feedback.
  """

  @chat_store """
  steward_ask = bootstrap/retrieve · steward_write = persist/status/feedback · steward_work = reminders/coordination.
  Prefer business scopes: org/domain/topic (e.g. acme/support/refunds).
  """

  @chat_honesty """
  Never invent org policy. If ACS has no match, say so and offer to save after the user confirms.
  """

  @chat_identity """
  OAuth / MCP token chat: ACS already knows who is connected.
  steward_ask() returns connected_user / authenticated_as / your_agent_id.
  Include that name in steward_ask(action:"search", content_query:) for personal context.
  Omit agent_id on tool calls. Never invent a nickname; present_status is not needed for identity.
  """

  @chat_conventions """
  ## Knowledge structure (chat)
  Business scopes: acme/sales/pricing, acme/support/refunds, acme/policy/privacy.
  - steward_write kind=memory — short eternal truths
  - steward_write kind=document — policies, briefs, marketing
  - steward_write kind=skill — step-by-step playbooks
  Chat tools are exactly steward_ask, steward_write, steward_work; all are always loaded and called by name. Never use tool_search.
  After search: steward_ask(action:"document", app, path) for document bodies; action:"skill" is **required** when a listed skill fits the task (skills are never fully inlined).
  Ingest: steward_ask(action:\"skill\", name:\"ingest-document\") before saving a pasted/uploaded document.
  """

  @doc """
  Memory save protocol for guidance packets / `_next` hints.

  Includes person-status and sensitive/confidential consent rules so agents
  see them before `save_memory` without needing them in the system prompt.
  """
  def memory_protocol(audience \\ :coding)

  def memory_protocol(audience) when audience in [:chat, :knowledge, "chat", "knowledge"],
    do: @chat_memory

  def memory_protocol(_), do: @coding_memory

  @doc """
  Generates a guidance packet for a given scope_path.

  ## Options
  - `tier`: `:full` (default) | `:claim`
  - `mode`: `:mcp` / `:coding` | `:knowledge` / `:chat`
  - `skip_scope_context`: when `true`, skips the ClaimContext.for_scope
    enrichment (relevant_skills/relevant_specs). Used by `for_task/2`,
    which already fetches claim context and overwrites those fields.
  """
  def generate(scope_path, opts \\ []) do
    tier = Keyword.get(opts, :tier, :full)
    audience = audience_from_mode(Keyword.get(opts, :mode, :mcp))
    allowed_teams = Keyword.get(opts, :allowed_teams)
    allowed_projects = Keyword.get(opts, :allowed_projects)
    agent_role = Keyword.get(opts, :agent_role)
    agent_id = Keyword.get(opts, :agent_id)
    authority_sort_order = Keyword.get(opts, :authority_sort_order)

    search_opts = [{:scope_path, scope_path}, {:status, "approved"}, {:org, Acs.Org.current()}]

    search_opts =
      if allowed_teams, do: search_opts ++ [allowed_teams: allowed_teams], else: search_opts

    search_opts =
      if allowed_projects,
        do: search_opts ++ [allowed_projects: allowed_projects],
        else: search_opts

    search_opts = if agent_role, do: search_opts ++ [agent_role: agent_role], else: search_opts
    search_opts = if agent_id, do: search_opts ++ [agent_id: agent_id], else: search_opts

    search_opts =
      if authority_sort_order,
        do: search_opts ++ [authority_sort_order: authority_sort_order],
        else: search_opts

    search_opts =
      case Keyword.get(opts, :authority_level_slug) do
        slug when is_binary(slug) and slug != "" ->
          search_opts ++ [authority_level_slug: slug]

        _ ->
          search_opts
      end

    # Coding guidance blends by repo: current repo first, org-wide second,
    # other repos down-ranked (see Acs.Memory.HybridSearch).
    search_opts =
      if audience == :coding do
        search_opts ++ [current_repo: Acs.Repos.repo(), repo_mode: Keyword.get(opts, :repo_mode)]
      else
        search_opts
      end

    sorted =
      search_opts
      |> Acs.Memory.Search.list()
      |> Enum.sort_by(& &1.importance, :desc)

    # Chat skips ToolGuidance — it's coding-tool noise
    tool_guidance =
      if audience == :chat, do: nil, else: Acs.Memory.ToolGuidance.for_scope(scope_path)

    packet =
      case audience do
        :chat -> build_chat_packet(scope_path, sorted, tier)
        :coding -> build_coding_packet(scope_path, sorted, tool_guidance, tier)
      end

    if Keyword.get(opts, :skip_scope_context, false) do
      packet
    else
      merge_scope_context(packet, scope_path)
    end
  end

  @doc """
  Generates a guidance packet for a specific task.
  """
  def for_task(task_id, opts \\ []) do
    tier = Keyword.get(opts, :tier, :full)
    mode = Keyword.get(opts, :mode, :mcp)
    audience = audience_from_mode(mode)
    allowed_teams = Keyword.get(opts, :allowed_teams)
    allowed_projects = Keyword.get(opts, :allowed_projects)
    agent_role = Keyword.get(opts, :agent_role)
    agent_id = Keyword.get(opts, :agent_id)
    authority_sort_order = Keyword.get(opts, :authority_sort_order)
    authority_level_slug = Keyword.get(opts, :authority_level_slug)

    case Acs.Acs.get_task(task_id) do
      nil ->
        empty_packet(tier, audience)

      task when is_map(task) ->
        task_map = if is_struct(task), do: Map.from_struct(task), else: task

        scope_path =
          (task_map[:file_paths] || [])
          |> List.first()
          |> scope_from_path()

        abac_opts =
          []
          |> then(fn o -> if allowed_teams, do: o ++ [allowed_teams: allowed_teams], else: o end)
          |> then(fn o ->
            if allowed_projects, do: o ++ [allowed_projects: allowed_projects], else: o
          end)
          |> then(fn o -> if agent_role, do: o ++ [agent_role: agent_role], else: o end)
          |> then(fn o -> if agent_id, do: o ++ [agent_id: agent_id], else: o end)
          |> then(fn o ->
            if is_integer(authority_sort_order),
              do: o ++ [authority_sort_order: authority_sort_order],
              else: o
          end)
          |> then(fn o ->
            if is_binary(authority_level_slug),
              do: o ++ [authority_level_slug: authority_level_slug],
              else: o
          end)

        guidance =
          generate(
            scope_path,
            Keyword.merge([tier: tier, mode: mode, skip_scope_context: true], abac_opts)
          )

        claim_context = Acs.ClaimContext.for_task(task_map)
        title = (task_map[:title] || "") |> String.downcase()
        repos = repos_from_task(task_map)

        guidance
        |> Map.put(:task_context, build_task_context(title))
        |> Map.put(:relevant_skills, claim_context.relevant_skills)
        |> Map.put(:relevant_specs, claim_context.relevant_specs)
        |> maybe_put_multi_repo_warning(repos)
        |> filter_claim_memories(title)
        |> maybe_put_coding_finish(audience, tier)
        |> maybe_put_missing_spec_nudge()
    end
  end

  # A task whose file_paths span multiple repos must not silently weaken the
  # first-lock repository boundary.
  defp maybe_put_multi_repo_warning(packet, []), do: packet
  defp maybe_put_multi_repo_warning(packet, [_single]), do: packet

  defp maybe_put_multi_repo_warning(packet, repos) do
    warning = """
    ⚠️  WARNING: this task references multiple repository paths (#{Enum.join(repos, ", ")}).

    The first successful lock establishes one repository for the task. Locking a file
    from another repository later will fail with `repo_mismatch`; split the task if
    work must proceed in more than one repository.
    """

    packet
    |> Map.put(:multi_repo_warning, warning)
    |> Map.put(:multi_repo_warning_repeat, warning)
    |> Map.put(:multi_repo_warning_again, warning)
  end

  defp repos_from_task(task_map) do
    (task_map[:file_paths] || [])
    |> Enum.map(&Acs.Repos.repo_for_file_path/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Claim: only keep axioms/warnings that share a token with the task title.
  # Otherwise agents get org-wide noise unrelated to this work.
  defp filter_claim_memories(%{tier: :claim} = packet, title) do
    tokens = Acs.ClaimContext.meaningful_tokens(title)

    packet
    |> Map.update(:critical_axioms, [], &keep_token_matches(&1, tokens))
    |> Map.update(:warnings, [], &keep_token_matches(&1, tokens))
  end

  defp filter_claim_memories(packet, _title), do: packet

  defp keep_token_matches(_items, []), do: []

  defp keep_token_matches(items, tokens) when is_list(items) do
    Enum.filter(items, fn item ->
      text =
        [
          Map.get(item, :title) || Map.get(item, "title"),
          Map.get(item, :summary) || Map.get(item, "summary")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
        |> String.downcase()

      Enum.any?(tokens, &String.contains?(text, &1))
    end)
  end

  defp keep_token_matches(_, _), do: []

  defp audience_from_mode(mode) when mode in [:knowledge, :chat, "knowledge", "chat"], do: :chat
  defp audience_from_mode(_), do: :coding

  defp empty_packet(tier, :chat) do
    build_chat_packet(nil, [], tier)
  end

  defp empty_packet(tier, :coding) do
    build_coding_packet(nil, [], nil, tier)
  end

  defp build_coding_packet(scope_path, sorted, tool_guidance, :claim) do
    # Claim stays task-focused. Protocols (memory, locking, store choice) live on
    # get_started — repeating them here is noise. Relevance comes from ClaimContext.
    %{
      audience: :coding,
      mode: :mcp,
      scope: scope_path,
      tier: :claim,
      repo: Acs.Repos.repo(),
      repo_hint: repo_hint(),
      critical_axioms:
        merge_items(
          extract_axioms(sorted, min_importance: 4),
          tool_guidance,
          :critical_axioms,
          @critical_axioms_max
        ),
      warnings:
        merge_items(
          extract_warnings(sorted, min_importance: 4),
          tool_guidance,
          :warnings,
          @warnings_max
        ),
      relevant_skills: [],
      relevant_specs: [],
      hint:
        "Protocols are in get_started. Load relevant_skills / relevant_specs, then work → save → release_work → submit_task_feedback."
    }
  end

  defp build_coding_packet(scope_path, sorted, tool_guidance, :full) do
    %{
      audience: :coding,
      mode: :mcp,
      scope: scope_path,
      scope_category: scope_path,
      tier: :full,
      repo: Acs.Repos.repo(),
      repo_hint: repo_hint(),
      critical_axioms:
        merge_items(extract_axioms(sorted), tool_guidance, :critical_axioms, @critical_axioms_max),
      warnings: merge_items(extract_warnings(sorted), tool_guidance, :warnings, @warnings_max),
      relevant_patterns:
        merge_items(extract_patterns(sorted), tool_guidance, :relevant_patterns, @patterns_max),
      compressed_knowledge: merge_knowledge(compress_knowledge(sorted), tool_guidance),
      workflow: @coding_workflow,
      file_locking: @coding_file_locking,
      memory: @coding_memory,
      error_response: @coding_error,
      tool_reference: @coding_tools,
      specs_mismatch: @coding_specs_mismatch,
      skills_finish: @coding_finish,
      maintenance: @coding_maintenance,
      agent_identity: @coding_identity,
      org_knowledge_conventions: @coding_conventions,
      specs_instructions: specs_instructions_for_tier(:full),
      skills_instructions: skills_instructions_for_tier(:full),
      store_choice: @coding_store_choice,
      save_plan: @coding_save_plan,
      relevant_skills: [],
      relevant_specs: [],
      workflow_basics: @coding_workflow,
      file_locking_protocol: @coding_file_locking,
      memory_protocol: @coding_memory,
      error_response_protocol: @coding_error,
      maintenance_instructions: @coding_maintenance,
      specs_mismatch_protocol: @coding_specs_mismatch,
      skills_finish_protocol: @coding_finish
    }
  end

  defp build_chat_packet(scope_path, sorted, :claim) do
    %{
      audience: :chat,
      mode: :knowledge,
      scope: scope_path,
      tier: :claim,
      critical_axioms: extract_axioms(sorted, min_importance: 4),
      warnings: extract_warnings(sorted, min_importance: 4),
      relevant_skills: [],
      relevant_specs: [],
      hint:
        "Protocols are in get_started / steward_ask start. Load relevant skills/docs, then act → save → release."
    }
  end

  defp build_chat_packet(scope_path, sorted, :full) do
    %{
      audience: :chat,
      mode: :knowledge,
      scope: scope_path,
      scope_category: scope_path,
      tier: :full,
      critical_axioms: extract_axioms(sorted),
      warnings: extract_warnings(sorted),
      relevant_patterns: extract_patterns(sorted),
      compressed_knowledge: compress_knowledge(sorted),
      workflow: @chat_workflow,
      store: @chat_store,
      honesty: @chat_honesty,
      memory: @chat_memory,
      memory_protocol: @chat_memory,
      agent_identity: @chat_identity,
      org_knowledge_conventions: @chat_conventions,
      specs_instructions: specs_instructions_chat_for_tier(:full),
      skills_instructions: skills_instructions_chat_for_tier(:full),
      relevant_skills: [],
      relevant_specs: [],
      workflow_basics: @chat_workflow
    }
  end

  defp maybe_put_coding_finish(packet, :coding, :full) do
    Map.put(packet, :skills_finish_protocol, @coding_finish)
  end

  defp maybe_put_coding_finish(packet, _audience, _tier), do: packet

  defp maybe_put_missing_spec_nudge(%{audience: :coding} = packet) do
    missing =
      (packet[:relevant_specs] || [])
      |> Enum.filter(fn s -> (s[:status] || s["status"]) == "missing" end)
      |> Enum.map(fn s -> s[:path] || s["path"] end)
      |> Enum.reject(&is_nil/1)

    case missing do
      [] ->
        packet

      paths ->
        nudge =
          "Modules you'll touch have no spec: " <>
            Enum.join(paths, ", ") <>
            ". If you change them, propose a spec (specs_propose purpose/invariants/workflows) before release_work."

        Map.put(packet, :missing_spec_nudge, nudge)
    end
  end

  defp maybe_put_missing_spec_nudge(packet), do: packet

  defp extract_axioms(memories, opts \\ []) do
    min_importance = Keyword.get(opts, :min_importance, 1)

    memories
    |> Enum.filter(fn m -> m.kind in ["axiom", "invariant", "decision"] end)
    |> Enum.filter(fn m -> m.importance >= min_importance end)
    |> Enum.take(@critical_axioms_max)
    |> Enum.map(fn m ->
      %{id: m.id, title: m.title, summary: m.summary, importance: m.importance}
    end)
  end

  defp extract_warnings(memories, opts \\ []) do
    min_importance = Keyword.get(opts, :min_importance, 1)

    memories
    |> Enum.filter(fn m -> m.kind == "warning" end)
    |> Enum.filter(fn m -> m.importance >= min_importance end)
    |> Enum.take(@warnings_max)
    |> Enum.map(fn m ->
      %{id: m.id, title: m.title, summary: m.summary, importance: m.importance}
    end)
  end

  defp extract_patterns(memories) do
    memories
    |> Enum.filter(fn m -> m.kind in ["pattern", "learning", "observation"] end)
    |> Enum.take(@patterns_max)
    |> Enum.map(fn m ->
      %{id: m.id, title: m.title, summary: m.summary, importance: m.importance}
    end)
  end

  defp compress_knowledge(memories) do
    axioms = memories |> Enum.filter(fn m -> m.kind in ["axiom", "invariant", "decision"] end)
    warnings = memories |> Enum.filter(fn m -> m.kind == "warning" end)

    patterns =
      memories |> Enum.filter(fn m -> m.kind in ["pattern", "learning", "observation"] end)

    [
      maybe_section("Axioms", axioms),
      maybe_section("Warnings", warnings),
      maybe_section("Patterns & Learnings", patterns)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> String.slice(0, @knowledge_max_chars)
  end

  defp maybe_section(_title, []), do: nil

  defp maybe_section(title, items) do
    body =
      items
      |> Enum.map(fn m -> "**#{m.title}**: #{m.summary}" end)
      |> Enum.join("\n")

    "## #{title}\n\n#{body}"
  end

  defp build_task_context(title) do
    cond do
      title =~ ~r/pricing|price|discount|quote|rate.?card|sku/i ->
        """
        ## Pricing / Commercial Context

        Prefer business scopes like `org/sales/pricing`. Before answering or changing policy:
        - `query_memories` / `query_specs` for approved pricing rules
        - Do not invent discounts or list prices — save confirmed decisions with `save_memory`
        - Long pricing sheets or rate cards → `specs_propose` as a **document** (document_type: policy/reference)
        """

      title =~ ~r/refund|support|ticket|escalat|customer.?care|help.?desk/i ->
        """
        ## Support Context

        Prefer scopes like `org/support/<topic>`. Retrieve playbooks first (`skill_get` / `query_specs`).
        Capture recurring resolutions as skills; one-off truths as memories. Never invent refund policy.
        """

      title =~ ~r/sales|pipeline|crm|lead|prospect|outbound|deal/i ->
        """
        ## Sales Context

        Prefer scopes like `org/sales/<topic>`. Check CRM tools if available, then org memories for process.
        Save durable sales rules (qualification, handoff) as memories; playbooks as skills.
        """

      title =~ ~r/onboard|offboard|hiring|recruit|hr\\b|people.?ops|interview/i ->
        """
        ## People / Onboarding Context

        Prefer scopes like `org/ops/onboarding` or `org/hr/<topic>`. Treat process docs as specs;
        checklists as skills; invariants (who approves what) as memories.
        """

      title =~ ~r/policy|compliance|legal|privacy|gdpr|security.?policy|terms/i ->
        """
        ## Policy / Compliance Context

        Prefer scopes like `org/policy/<topic>`. Never paraphrase policy as fact unless retrieved from ACS.
        Long policy text → `specs_propose` as a **document**; short must-follow rules → `save_memory` (kind: invariant/axiom).
        """

      title =~ ~r/billing|invoice|finance|accounting|payroll|expense|budget/i ->
        """
        ## Finance / Billing Context

        Prefer scopes like `org/finance/<topic>` or `org/billing/<topic>`. Confirm numbers from ACS or source systems.
        Save approved rules as memories; runbooks (how to invoice) as skills.
        """

      title =~ ~r/marketing|campaign|promot|content|seo|social|blog|advert/i ->
        """
        ## Marketing Context

        Prefer scopes like `org/marketing/<campaign>`. Considerations:
        - Ensure analytics/UTM tracking is set up if the product requires it
        - Store long copy via `specs_propose` as a **document** (document_type: marketing)
        - Capture brand invariants as memories
        """

      title =~ ~r/test|spec|coverage|testing|rspec|exunit|assert/i ->
        """
        ## Testing Context

        This task involves tests or specs. Before releasing, ensure:
        - New tests pass with `mix test`
        - Existing tests are not broken
        - Consider both unit and integration test coverage
        """

      title =~ ~r/bug|fix|error|crash|issue|fault|broken|fail/i ->
        """
        ## Bug Fix Context

        This task fixes a bug. Before releasing, ensure:
        - The root cause is identified and fixed (not just symptoms)
        - Add a regression test that would catch this if reintroduced
        - Check for the same pattern elsewhere in the codebase
        """

      title =~ ~r/deploy|release|ci|cd|publish|rollout|build/i ->
        """
        ## Deployment Context

        This task involves deployment. Before releasing, ensure:
        - All changes are committed and pushed
        - The build pipeline passes
        - Review guides/deployment.md for the deployment workflow
        """

      title =~ ~r/migrat|schema|database|db|sql|ecto/i ->
        """
        ## Database Context

        This task involves database changes. Before releasing, ensure:
        - Run `mix ecto.migrate` to apply new migrations
        - Verify rollback works: `mix ecto.rollback`
        - Consider data migration for existing records
        """

      title =~ ~r/secur|auth|permission|oauth|api.?key|encrypt/i ->
        """
        ## Security Context

        This task involves security-sensitive changes. Before releasing, ensure:
        - No secrets or keys are committed or logged
        - Follow guides/secrets.md for managing secrets
        - Authentication and authorization paths are tested
        """

      title =~ ~r/refactor|clean.?up|optimize|performance|technical.?debt|rewrite/i ->
        """
        ## Refactoring Context

        This task involves refactoring. Before releasing, ensure:
        - Existing behaviour is preserved — don't change the API contract
        - Tests still pass (refactoring should not break tests)
        - Consider incremental changes rather than a big rewrite
        """

      title =~ ~r/document|docs?|readme|comment|guide|wiki|changelog/i ->
        """
        ## Documentation Context

        This task involves documentation. Considerations:
        - Keep docs close to the code or business domain they describe
        - Code module docs → **specs**; org/policy/marketing → **documents** (same `specs_*` tools)
        - Update specs/documents alongside the work they describe
        """

      title =~ ~r/feature|add|new|implement|support|integrat/i ->
        """
        ## Feature Context

        This task adds a new feature. Before releasing, ensure:
        - Write tests for the new functionality
        - Update or add specs for any new modules
        - Consider backward compatibility
        - Update any relevant documentation
        """

      title =~ ~r/api|endpoint|route|controller|graphql|rest/i ->
        """
        ## API Context

        This task involves API changes. Before releasing, ensure:
        - API changes are backward compatible or versioned
        - Request/response formats are documented
        - Error responses follow existing conventions
        """

      title =~ ~r/ui|ux|view|template|frontend|component|layout|style|css/i ->
        """
        ## UI/Frontend Context

        This task involves UI changes. Before releasing, ensure:
        - Works across target viewport sizes (responsive)
        - Follows existing design patterns and conventions
        - Check for accessibility basics (keyboard nav, screen readers)
        """

      title =~ ~r/docker|container|k8s|kubernetes|compose|image/i ->
        """
        ## Container Context

        This task involves container/Docker changes. Before releasing, ensure:
        - Test the build locally with `docker compose build`
        - Keep image sizes small — prefer slim/alpine bases
        - Don't bake secrets into images
        """

      title =~ ~r/config|configure|setup|env|setting|option/i ->
        """
        ## Configuration Context

        This task involves configuration changes. Considerations:
        - Default values should be safe for local development
        - Document new config options in relevant guides
        - Use env vars for environment-specific values
        """

      true ->
        nil
    end
  end

  defp scope_from_path(nil), do: ""

  defp scope_from_path(path) when is_binary(path) do
    # Strip project root so scope_path is always relative
    project_root =
      Application.app_dir(:steward_acs) |> Path.dirname() |> Path.dirname()

    relative_path =
      if String.starts_with?(path, project_root) do
        String.replace_prefix(path, project_root <> "/", "")
      else
        path
      end

    relative_path
    |> String.split("/")
    |> Enum.slice(0..-2//1)
    |> Enum.join("/")
  end

  defp scope_from_path(_), do: ""

  # Merges hardcoded tool guidance items with memory-based items
  # Priority: 1) memory items (highest importance first), 2) hardcoded items fill remaining slots
  defp merge_items(memory_items, nil, _key, _max), do: memory_items

  defp merge_items(memory_items, tool_guidance, key, max) do
    hardcoded_items = Map.get(tool_guidance, key, [])
    merged = memory_items ++ hardcoded_items
    Enum.take(merged, max)
  end

  # Merges compressed knowledge with hardcoded knowledge
  defp merge_knowledge(memory_knowledge, nil), do: memory_knowledge

  defp merge_knowledge("", tool_guidance) do
    Map.get(tool_guidance, :compressed_knowledge, "")
  end

  defp merge_knowledge(memory_knowledge, tool_guidance) do
    hardcoded = Map.get(tool_guidance, :compressed_knowledge, "")
    merged = memory_knowledge <> "\n\n" <> hardcoded
    String.slice(merged, 0, @knowledge_max_chars)
  end

  defp merge_scope_context(%{audience: :chat} = packet, scope_path)
       when scope_path in [nil, ""] do
    ctx = Acs.ClaimContext.for_scope(scope_path)

    packet
    |> Map.put(:relevant_skills, ctx.relevant_skills)
    |> Map.put(:relevant_specs, ctx.relevant_specs)
    |> Map.put(:scope_hint, @scope_hint_chat)
  end

  defp merge_scope_context(packet, scope_path) when scope_path in [nil, ""] do
    ctx = Acs.ClaimContext.for_scope(scope_path)

    packet
    |> Map.put(:relevant_skills, ctx.relevant_skills)
    |> Map.put(:relevant_specs, ctx.relevant_specs)
    |> Map.put(:scope_hint, @scope_hint)
    |> maybe_put_missing_spec_nudge()
  end

  defp merge_scope_context(%{audience: :chat} = packet, scope_path) do
    ctx = Acs.ClaimContext.for_scope(scope_path)

    packet
    |> Map.put(:relevant_skills, ctx.relevant_skills)
    |> Map.put(:relevant_specs, ctx.relevant_specs)
  end

  defp merge_scope_context(packet, scope_path) do
    ctx = Acs.ClaimContext.for_scope(scope_path)

    packet
    |> Map.put(:relevant_skills, ctx.relevant_skills)
    |> Map.put(:relevant_specs, ctx.relevant_specs)
    |> maybe_put_coding_finish(Map.get(packet, :audience), Map.get(packet, :tier))
    |> maybe_put_missing_spec_nudge()
  end

  def specs_instructions_for_tier(:claim) do
    claim = Acs.Prompts.instructions_claim("specs")

    cond do
      claim != "" -> claim
      true -> @specs_instructions_short
    end
  end

  def specs_instructions_for_tier(_tier) do
    full = Acs.Prompts.instructions("specs")
    if full != "", do: full, else: @specs_instructions
  end

  def skills_instructions_for_tier(:claim) do
    claim = Acs.Prompts.instructions_claim("skills")

    cond do
      claim != "" -> claim
      true -> @skills_instructions_short
    end
  end

  def skills_instructions_for_tier(_tier) do
    full = Acs.Prompts.instructions("skills")
    if full != "", do: full, else: @skills_instructions_short
  end

  def specs_instructions_chat_for_tier(:claim) do
    claim = Acs.Prompts.instructions_chat_claim("specs")

    cond do
      claim != "" -> claim
      true -> @specs_instructions_chat
    end
  end

  def specs_instructions_chat_for_tier(_tier) do
    full = Acs.Prompts.instructions_chat("specs")
    if full != "", do: full, else: @specs_instructions_chat
  end

  def skills_instructions_chat_for_tier(:claim) do
    claim = Acs.Prompts.instructions_chat_claim("skills")

    cond do
      claim != "" -> claim
      true -> @skills_instructions_chat
    end
  end

  def skills_instructions_chat_for_tier(_tier) do
    full = Acs.Prompts.instructions_chat("skills")
    if full != "", do: full, else: @skills_instructions_chat
  end

  # Repo hint: present guidance only when no repo is declared for the session.
  defp repo_hint do
    if Acs.Repos.repo(), do: nil, else: @repo_hint
  end
end
