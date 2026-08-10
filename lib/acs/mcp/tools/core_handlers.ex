defmodule Acs.MCP.Tools.CoreHandlers do
  @moduledoc """
  Handles core ACS MCP tools for agent task and file lifecycle.

  ## Purpose

  Implements the handler functions for agent coordination tools:
  creating, claiming, and releasing tasks; locking and unlocking files;
  present status queries; and log retrieval.

  ## Key Functions

  - `acs_claim_work/1` — Claims a task for an agent
  - `acs_release_work/1` — Releases a task and returns feedback prompt
  - `acs_create_work/1` — Creates a new task with dedup warnings
  - `acs_lock_file/1` — Locks a file for exclusive editing
  - `acs_unlock_file/1` — Unlocks a file or all files for a task
  - `acs_get_present_status/1` — Returns agent status or assigns agent ID
  - `get_logs/1` — Retrieves application logs with filters
  - `acs_time/1` — Gets or sets ACS time offset
  """
  alias Acs.Acs.Cache
  alias Acs.MCP.LogStore
  alias Acs.MCP.Tools.ErrorHandlers
  require Logger
  import Ecto.Query, only: [from: 2]

  def acs_claim_work(%{"agent_id" => agent_id, "task_id" => task_id} = args) do
    scope_path = args["scope_path"]
    mode = Acs.MCP.Audience.to_guidance_mode(Acs.MCP.Audience.from_args(args))
    abac = claim_guidance_opts(args, mode)
    opts = abac ++ if(scope_path, do: [skip_guidance: true], else: [])

    case Acs.claim_task(task_id, agent_id, opts) do
      {:ok, task, guidance} ->
        application = args["application"]
        component = args["component"]

        if application || component do
          Acs.update_agent_context(agent_id, application, component)
        end

        final_guidance =
          if scope_path do
            Acs.Memory.Guidance.generate(
              scope_path,
              Keyword.merge([tier: :claim, mode: mode], abac)
            )
          else
            guidance
          end

        {:ok,
         %{
           status: "claimed",
           task_id: task.slug,
           agent_id: agent_id,
           audience: Acs.MCP.Audience.from_args(args),
           guidance: final_guidance
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acs_release_work(%{"agent_id" => agent_id, "task_id" => task_id}) do
    case Acs.release_task(task_id, agent_id) do
      {:ok, task} ->
        {:ok,
         %{
           status: "done",
           task_id: task.slug,
           agent_id: agent_id,
           message: "Task released. Now call submit_task_feedback to formally close it."
         }}

      {:error, :not_owner} ->
        {:ok, %{status: "not_owner", message: "Task locked by another agent"}}

      {:error, reason} when is_atom(reason) ->
        {:error, Atom.to_string(reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acs_close_work(%{"agent_id" => agent_id, "task_id" => task_id} = args) do
    case Acs.release_task(task_id, agent_id) do
      {:ok, task} ->
        spec = maybe_save_spec(args)
        feedback = maybe_submit_feedback(args)

        {:ok,
         %{
           status: "done",
           task_id: task.slug,
           agent_id: agent_id,
           spec: spec,
           feedback: feedback,
           message:
             "Task closed: released, info saved, and feedback submitted. Save skills/memories BEFORE calling close_work so they're captured first."
         }}

      {:error, :not_owner} ->
        {:ok, %{status: "not_owner", message: "Task locked by another agent"}}

      {:error, reason} when is_atom(reason) ->
        {:error, Atom.to_string(reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_save_spec(args) do
    if is_binary(args["app"]) && args["app"] != "" &&
         is_binary(args["path"]) && args["path"] != "" do
      case Acs.Specs.Tools.call_tool("specs_propose", args) do
        {:ok, %{"status" => status} = entry} ->
          %{
            saved: true,
            status: status,
            app: Map.get(entry, "app") || args["app"],
            path: Map.get(entry, "id") || args["path"]
          }

        {:ok, entry} when is_map(entry) ->
          %{saved: true, path: Map.get(entry, "id") || args["path"]}

        {:error, reason} ->
          %{saved: false, error: reason}
      end
    else
      %{saved: false, reason: "No app/path provided — skipped spec save"}
    end
  end

  defp maybe_submit_feedback(args) do
    case ErrorHandlers.acs_submit_task_feedback(args) do
      {:ok, %{message: message}} -> %{submitted: true, message: message}
      {:error, reason} -> %{submitted: false, error: reason}
    end
  end

  def acs_create_work(%{"agent_id" => agent_id, "title" => title} = args) do
    if Acs.UserTasks.user_task_args?(args) do
      create_user_task(args, agent_id, title)
    else
      create_coordination_task(args, agent_id, title)
    end
  end

  defp create_user_task(args, agent_id, title) do
    org = authenticated_org(args)
    viewer_order = args["_auth_authority_sort_order"]

    attrs = %{
      "title" => title,
      "description" => args["description"] || "",
      "assignee" => args["assignee"],
      "due_at" => args["due_at"],
      "remind_at" => args["remind_at"]
    }

    opts =
      [org: org]
      |> then(fn o ->
        if is_integer(viewer_order), do: Keyword.put(o, :viewer_sort_order, viewer_order), else: o
      end)

    case Acs.UserTasks.create(attrs, agent_id, opts) do
      {:ok, task} ->
        {:ok,
         %{
           status: "ok",
           kind: "user",
           task_id: task.slug,
           title: task.title,
           assignee: task.assignee,
           due_at: task.due_at,
           remind_at: task.remind_at,
           message:
             "User task created. It will appear in get_started.pending_reminders for the assignee once remind_at has passed."
         }}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp create_coordination_task(args, agent_id, title) do
    claim = args["claim"] || false
    mode = Acs.MCP.Audience.to_guidance_mode(Acs.MCP.Audience.from_args(args))

    attrs = %{
      "title" => title,
      "description" => args["description"] || "",
      "file_paths" => args["file_paths"] || []
    }

    case Acs.create_task(attrs, agent_id) do
      {:ok, task} ->
        if claim do
          case Acs.claim_task(task.id, agent_id, claim_guidance_opts(args, mode)) do
            {:ok, _task, guidance} ->
              {:ok,
               %{status: "claimed", task_id: task.slug, title: task.title, guidance: guidance}}

            {:error, reason} ->
              {:ok,
               %{status: "created", task_id: task.slug, title: task.title, claim_error: reason}}
          end
        else
          {:ok, %{status: "ok", task_id: task.slug, title: task.title}}
        end

      {:warn, task, similar} ->
        if claim do
          case Acs.claim_task(task.id, agent_id, claim_guidance_opts(args, mode)) do
            {:ok, _task, guidance} ->
              {:ok,
               %{
                 status: "claimed",
                 task_id: task.slug,
                 title: task.title,
                 guidance: guidance,
                 similar_tasks: similar
               }}

            {:error, reason} ->
              {:ok,
               %{
                 status: "created",
                 task_id: task.slug,
                 title: task.title,
                 similar_tasks: similar,
                 claim_error: reason
               }}
          end
        else
          {:ok,
           %{status: "warning", task_id: task.slug, title: task.title, similar_tasks: similar}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acs_resolve_user_task(%{"agent_id" => agent_id, "task_id" => task_id} = args) do
    case Map.get(args, "outcome") do
      outcome when is_binary(outcome) and outcome != "" ->
        org = authenticated_org(args)
        viewer_order = args["_auth_authority_sort_order"]

        opts =
          [org: org]
          |> then(fn o ->
            if is_integer(viewer_order),
              do: Keyword.put(o, :viewer_sort_order, viewer_order),
              else: o
          end)
          |> then(fn o ->
            case args["remind_at"] do
              nil -> o
              "" -> o
              remind_at -> Keyword.put(o, :remind_at, remind_at)
            end
          end)

        case Acs.UserTasks.resolve(task_id, agent_id, outcome, opts) do
          {:ok, task} ->
            {:ok,
             %{
               status: "ok",
               task_id: task.slug,
               outcome: outcome,
               task_status: task.status,
               remind_at: task.remind_at,
               message: resolve_outcome_message(outcome)
             }}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      _ ->
        {:error,
         "outcome is required: done, dismiss, or remind_later (remind_later also needs remind_at)"}
    end
  end

  defp resolve_outcome_message("done"), do: "User task marked done."
  defp resolve_outcome_message("dismiss"), do: "User task dismissed."

  defp resolve_outcome_message("remind_later"),
    do: "Reminder rescheduled. It will surface again after the new remind_at."

  defp resolve_outcome_message(_), do: "User task updated."

  def acs_lock_file(
        %{"agent_id" => agent_id, "task_id" => task_id, "file_path" => file_path} = args
      ) do
    repo = args["repo"] || args["_auth_repo"]

    task_repo =
      case Acs.Acs.get_task(task_id) do
        %{repo: task_repo} when is_binary(task_repo) -> task_repo
        _ -> nil
      end

    repo_confirmed = args["repo_confirmed"] in [true, "true"]

    lock_result =
      cond do
        is_nil(repo) and is_nil(task_repo) -> {:error, :repo_context_required}
        is_nil(task_repo) and not repo_confirmed -> {:error, :repo_confirmation_required}
        true -> Acs.lock_file(file_path, agent_id, task_id, repo || task_repo)
      end

    case lock_result do
      {:ok, result} ->
        Acs.MCP.ClientSession.set_working_repo(
          result[:repo],
          args["workspace_id"] || args["_auth_workspace_id"],
          args["_auth_agent_id"] || agent_id
        )

        # Add file locking protocol guidance to the response
        guidance = Map.get(result, :guidance, %{})

        file_locking_protocol = """
        ## File Locking Protocol

        - **AFTER editing**: `acs_unlock_file(agent_id, file_path: "#{file_path}")` when done
        - **10-minute auto-release** if agent goes silent
        - Call `acs_get_locked_files()` to see all locked files
        """

        final_guidance =
          if guidance == %{},
            do: %{},
            else: Map.put(guidance, :file_locking_protocol, file_locking_protocol)

        {:ok, Map.put(result, :guidance, final_guidance)}

      {:error, :file_locked_by_other} ->
        {:error,
         "File already locked by another agent. Wait and retry, or use `get_locked_files()` to check current locks."}

      {:error, :task_not_locked_by_agent} ->
        {:error,
         "Task not locked by this agent. Claim the task first with `claim_work(\"<agent_id>\", task_id: \"#{task_id}\")` before locking files."}

      {:error, :task_not_found} ->
        {:error,
         "Task not found. The task may have been released or never existed. Create and claim a new task: `create_work(\"<agent_id>\", \"<title>\", claim: true)`"}

      {:error, :repo_context_required} ->
        {:error,
         "Repository context is required on the first lock. Pass `repo` (the repository name) with this lock_file call."}

      {:error, :repo_confirmation_required} ->
        {:error,
         "Confirm the repository before the first lock. Verify the local checkout with `git rev-parse --show-toplevel`, read its AGENTS_STEWARD.md Repo: declaration, then pass `repo` and `repo_confirmed: true`."}

      {:error, :repo_mismatch} ->
        {:error, "Repository does not match the task's established repository scope."}

      {:error, :already_locked} ->
        {:ok, %{status: "already_locked", message: "File already locked"}}

      {:error, reason} when is_atom(reason) ->
        {:error, Atom.to_string(reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acs_lock_file(%{"agent_id" => agent_id, "task_id" => task_id, "filePath" => file_path}) do
    acs_lock_file(%{"agent_id" => agent_id, "task_id" => task_id, "file_path" => file_path})
  end

  def acs_unlock_file(%{"agent_id" => agent_id, "task_id" => task_id}) when is_binary(task_id) do
    Acs.unlock_files_for_task(task_id, agent_id)
    {:ok, %{status: "ok", message: "All files unlocked for task: #{task_id}"}}
  end

  def acs_unlock_file(%{"agent_id" => agent_id, "file_path" => file_path}) do
    case Acs.unlock_file(file_path, agent_id) do
      :ok -> {:ok, %{status: "ok", message: "File unlocked: #{file_path}"}}
      {:error, reason} -> {:error, reason}
    end
  end

  def acs_unlock_file(%{"agent_id" => agent_id, "filePath" => file_path}) do
    acs_unlock_file(%{"agent_id" => agent_id, "file_path" => file_path})
  end

  def acs_unlock_file(%{"agent_id" => _agent_id}) do
    {:error, "Either file_path or task_id is required"}
  end

  def acs_get_started(args) do
    case Acs.MCP.Audience.from_args(args) do
      :chat -> {:ok, chat_get_started(args)}
      _ -> {:ok, coding_get_started(args)}
    end
  end

  defp coding_get_started(args) when is_map(args) do
    you = connected_user_from_args(args) || Acs.Org.usable_developer_name()
    raw_agent = agent_name_from_args(args)
    agent_name = resolve_coding_agent_name(raw_agent || you)
    identity = coding_identity_guidance(you, agent_name)

    %{
      audience: :coding,
      connected_user: you,
      authenticated_as: you,
      your_agent_id: agent_name,
      repo: Acs.Repos.repo(),
      repo_guidance: Acs.Repos.guidance(),
      general:
        "ACS coordinates agent work. First identify the local checkout with `git rev-parse --show-toplevel`, read its `AGENTS_STEWARD.md` Repo: declaration, and confirm with the human or coordinating agent that it is the intended repository. Create and claim a task, then make the first lock_file call with that repo and `repo_confirmed: true`; the first successful lock establishes task/session scope and later repo mismatches fail. Edit, save learnings (skills / documents / specs / memories), then release. Scopes may be code paths or business domains (org/domain/topic). Every response includes `_next` with suggested next tools.",
      get_started: coding_get_started_steps(you, agent_name),
      agent_identity: identity,
      org_knowledge_conventions:
        "Structure knowledge with scope_path = org/domain/topic (business) or path/to/module (code). memories=short truths, specs=code module docs via specs_propose, documents=long non-code via specs_propose(document_type,title,content) under documents/<type>/<slug>, skills=procedures via skill_save. End of task pick one primary store.",
      memory_protocol: Acs.Memory.Guidance.memory_protocol(:coding),
      tools: [
        %{
          tool: "get_present_status",
          description: "Register and see all active agents",
          params: %{agent_id: ""}
        },
        %{
          tool: "create_work",
          description: "Create and self-claim a task (default flow)",
          params: %{agent_id: "your_name", title: "...", claim: true}
        },
        %{
          tool: "list_tasks",
          description: "Find existing tasks to claim",
          params: %{status_filter: "todo"}
        },
        %{
          tool: "claim_work",
          description: "Claim an existing task",
          params: %{agent_id: "your_name", task_id: "<slug>"}
        },
        %{
          tool: "generate_guidance_packet",
          description: "Get guidance for a code or business scope",
          params: %{scope_path: "org/domain/topic"}
        },
        %{
          tool: "help",
          description: "List all tools with full descriptions",
          params: %{level: 1}
        },
        %{
          tool: "skill_get",
          description: "Find or list reusable workflow guides (how-tos)",
          params: %{search: "...", tag: "..."}
        },
        %{
          tool: "skill_save",
          description: "Save a reusable step-by-step procedure (before release_work)",
          params: %{name: "...", content: "...", tags: ["..."], scope_paths: ["org/domain"]}
        },
        %{
          tool: "specs_propose",
          description:
            "Save a code SPEC (purpose/invariants) or DOCUMENT (document_type + title + content)",
          params: %{
            app: "<app>",
            path: "documents/<type>/<slug>",
            document_type: "knowledge",
            title: "...",
            content: "..."
          }
        },
        %{
          tool: "save_memory",
          description: "Save a short eternal truth (see memory_protocol)",
          params: %{kind: "decision", title: "...", content: "...", scope_path: "org/domain"}
        },
        %{
          tool: "skill_audit_status",
          description: "Audit all skills for quality and completeness",
          params: %{}
        }
      ]
    }
  end

  defp coding_identity_guidance(you, agent_name) when is_binary(you) do
    if is_binary(agent_name) and agent_name != you do
      "Connected as \"#{you}\" (OAuth display name or acs_dev_ developer_name on the MCP token). Your agent name this session is \"#{agent_name}\" (user + pool). Use \"#{you}\" in ask/content_query when retrieving that person's memories. Pass agent_id exactly \"#{agent_name}\" on task tools."
    else
      "Connected as \"#{you}\" (OAuth display name or acs_dev_ developer_name on the MCP token). Use this name in ask/content_query when retrieving that person's memories. Omit agent_id or pass exactly \"#{you}\"."
    end
  end

  defp coding_identity_guidance(_nil, _agent_name) do
    if Acs.Org.multi_tenant?() do
      case Acs.Org.usable_developer_name() do
        name when is_binary(name) ->
          "Using developer name \"#{name}\" (from ACS_DEVELOPER_NAME / signup / Settings). Prod equivalent: acs_dev_ key with that developer_name."

        nil ->
          """
          No named coding identity yet. Do NOT invent or reuse one — \"unknown\" is rejected. Ask the human their name, then tell them to set it and restart: (1) set ACS_DEVELOPER_NAME=TheirName in their .env (or bin/setup.sh) and restart the server, or (2) use the web UI Settings → Coding identity → enter their name → Save name. Prod/remote path: mint an acs_dev_ key with that developer_name (generate_developer_key(name:, role: \"admin\")) and put it in Cursor mcp.json as x-api-key. Until they set one, get_present_status assigns a pool name (Alice/Yara/…).
          """
          |> String.trim()
      end
    else
      owner =
        case Acs.Org.usable_developer_name() do
          name when is_binary(name) -> name
          _ -> "not set"
        end

      "Local mode: agents self-identify — there is no default agent identity. Register with get_present_status(agent_id: your_name) and pass that agent_id to every task tool. Workspace owner: \"#{owner}\" — include it in ask()/content_query when retrieving that person's memories (saved learnings attribute to the workspace owner)."
    end
  end

  defp coding_get_started_steps(you, agent_name) when is_binary(you) do
    id = if is_binary(agent_name) and agent_name != "", do: agent_name, else: you

    "Connected user: \"#{you}\". 1) find the local checkout with `git rev-parse --show-toplevel`, read its `AGENTS_STEWARD.md` Repo: line, and confirm it is the intended repository 2) ask(content_query: \"... #{you} ...\") when you need this person's memories  3) create_work(title, claim: true) — omit agent_id (ACS uses \"#{id}\")  4) skill_get / query_specs  5) first lock_file(..., repo: \"<Repo value>\", repo_confirmed: true) → work → save → unlock  6) release_work → submit_task_feedback last"
  end

  defp coding_get_started_steps(_nil, _agent_name) do
    "1) `get_present_status(agent_id: \"your_name\")` — register under your own agent name (or \"\" for a pool-assigned name; returns assigned_agent_id)  2) find the local checkout with `git rev-parse --show-toplevel`, read its `AGENTS_STEWARD.md` Repo: line, and confirm it is intended 3) `create_work(agent_id, title, claim: true)` — create + claim  4) `skill_get(search: title)` — find workflow guides  5) `query_specs(query: title)` — check specs/documents  6) first `lock_file(..., repo: \"<Repo value>\", repo_confirmed: true)`  7) do work  8) pick one save: `skill_save` (how-to) | `specs_propose` document_type+content (long doc) | `specs_propose` purpose/invariants (code spec) | `save_memory` (short truth)  9) `unlock_file`  10) `release_work`  11) `submit_task_feedback(learned_for_agents:..., had_issues:..., improvements:..., info_needed:...)` last"
  end

  defp connected_user_from_args(args) when is_map(args) do
    agent_id = agent_name_from_args(args)

    if is_nil(agent_id) do
      nil
    else
      case Map.get(args, "_auth_attribution") do
        id when is_binary(id) ->
          trimmed = String.trim(id)
          if trimmed != "" and trimmed != "unknown", do: trimmed, else: agent_id

        _ ->
          agent_id
      end
    end
  end

  defp agent_name_from_args(args) when is_map(args) do
    case Map.get(args, "_auth_agent_id") do
      id when is_binary(id) ->
        trimmed = String.trim(id)
        if trimmed != "" and trimmed != "unknown", do: trimmed, else: nil

      _ ->
        nil
    end
  end

  defp resolve_coding_agent_name(name) when is_binary(name) do
    Acs.MCP.ClientSession.get_or_assign_qualified_agent_name(name) || name
  end

  defp resolve_coding_agent_name(_), do: nil

  defp chat_get_started(args) when is_map(args) do
    you = connected_user_from_args(args)
    org = authenticated_org(args)

    pending =
      if is_binary(you), do: Acs.UserTasks.pending_reminders(you, org), else: []

    identity_line =
      if you do
        "Connected ACS user: \"#{you}\". Start with steward_ask() and include this name in personal searches. Omit agent_id; never invent a nickname."
      else
        "Connected user unknown on this session. steward_ask() still returns the startup packet; do not invent an identity."
      end

    reminder_step =
      if pending == [] do
        ""
      else
        " Pending reminders are due: surface them and offer steward_work(action:\"resolve_reminder\", outcome: done|dismiss|remind_later)."
      end

    %{
      audience: :chat,
      connected_user: you,
      authenticated_as: you,
      your_agent_id: you,
      pending_reminders: pending,
      pending_reminders_guidance:
        "If non-empty, tell the user about each reminder. Resolve with steward_work(action:\"resolve_reminder\"). remind_later requires a new remind_at. Do not list tasks for reminders already present here.",
      general:
        "ACS chat has exactly three always-loaded tools: steward_ask (bootstrap/retrieve), steward_write (persist/status/feedback), and steward_work (reminders/coordination). Never use tool_search.",
      get_started:
        "1) steward_ask(action:\"search\", content_query:) and/or action:\"skill\" / action:\"document\"  2) read bodies before acting  3) steward_write as needed  4) reminders/coordination via steward_work.#{reminder_step}",
      agent_identity: identity_line,
      org_knowledge_conventions:
        "Business scopes use org/domain/topic. steward_write kind=memory stores short truths, kind=document stores long artifacts, kind=skill stores procedures. Save before release; feedback is last for tracked work.",
      memory_protocol: Acs.Memory.Guidance.memory_protocol(:chat),
      user_task_protocol: user_task_protocol(),
      tools: [
        %{
          tool: "steward_ask",
          description: "Bootstrap and retrieve",
          params: %{action: "search", content_query: you || "..."}
        },
        %{
          tool: "steward_write",
          description: "Persist knowledge, status, or feedback",
          params: %{
            kind: "memory",
            memory_kind: "decision",
            title: "...",
            content: "...",
            scope_path: "org/domain/topic"
          }
        },
        %{
          tool: "steward_work",
          description: "Create reminders or coordinate tracked work",
          params: %{action: "create", kind: "user", title: "...", due_at: "...", remind_at: "..."}
        }
      ]
    }
  end

  defp user_task_protocol do
    """
    ## User reminders (chat)

    USE WHEN the human wants a timed todo/reminder (meeting prep, follow-up, deadline).
    Do NOT use claim_work / release_work / file locks for these.

    Create: steward_work(action: "create", kind: "user", title, due_at, remind_at) — both times required (ISO-8601).
    Assignee defaults to connected_user. Assigning someone else requires strictly higher clearance.
    After remind_at, every steward_ask() startup packet includes the task until resolved.

    Resolve: steward_work(action: "resolve_reminder", task_id, outcome):
    - done — completed
    - dismiss — cancelled
    - remind_later — MUST pass remind_at; if the user gave no time, ask them before calling

    List: steward_ask(action: "list_tasks", kind: "user") only when the user asks. Optional for_user requires clearance. Never dump tasks unprompted.
    """
    |> String.trim()
  end

  def acs_get_present_status(%{"agent_id" => agent_id})
      when is_binary(agent_id) and agent_id != "" and agent_id != "unknown" do
    statuses = with_task_slugs(Acs.Acs.get_present_status())
    my_status = Enum.find(statuses, %{}, fn s -> s.agent_id == agent_id end)
    {:ok, %{agents: statuses, agent: my_status, agent_id: agent_id}}
  end

  def acs_get_present_status(%{"status_filter" => _filter}) do
    {:ok, with_task_slugs(Acs.Acs.get_present_status())}
  end

  def acs_get_present_status(args) do
    agent_name =
      case Map.get(args, "_auth_agent_id") do
        id when id in [nil, "", "unknown"] -> Cache.get_and_increment_agent_index()
        auth_id -> auth_id
      end

    case Acs.Acs.get_agent_status(agent_name) do
      nil -> Acs.Acs.put_agent_status(agent_name, %{current_task_id: nil, purpose: "active"})
      _ -> :ok
    end

    {:ok, %{agents: with_task_slugs(Acs.Acs.get_present_status()), assigned_agent_id: agent_name}}
  end

  def acs_get_locked_files(_) do
    locks = Acs.Acs.get_locked_files()

    task_ids = Enum.map(locks, & &1.task_id) |> Enum.reject(&is_nil/1)

    slug_by_id =
      if task_ids == [] do
        %{}
      else
        Acs.Repo.all(
          from t in Acs.Acs.Task,
            where: t.id in ^task_ids and t.org == ^Acs.Org.current(),
            select: {t.id, t.slug}
        )
        |> Map.new()
      end

    {:ok,
     Enum.map(locks, fn l ->
       %{
         file_path: l.file_path,
         locked_by_agent: l.locked_by_agent,
         locked_at: l.locked_at,
         auto_release_at: l.auto_release_at,
         task_id: Map.get(slug_by_id, l.task_id)
       }
     end)}
  end

  defp with_task_slugs(statuses) when is_list(statuses) do
    task_ids = Enum.map(statuses, & &1.current_task_id) |> Enum.reject(&is_nil/1)

    slug_by_id =
      if task_ids == [] do
        %{}
      else
        Acs.Repo.all(
          from t in Acs.Acs.Task,
            where: t.id in ^task_ids and t.org == ^Acs.Org.current(),
            select: {t.id, t.slug}
        )
        |> Map.new()
      end

    Enum.map(statuses, fn s ->
      s
      |> Map.put(:current_task_slug, Map.get(slug_by_id, s.current_task_id))
      |> Map.drop([:current_task_id])
    end)
  end

  def acs_list_tasks(args) when is_map(args) do
    kind = args["kind"]

    if kind == "user" do
      list_user_tasks(args)
    else
      status_filter = Map.get(args, "status_filter")
      status_filter = if status_filter == "all", do: nil, else: status_filter
      org = authenticated_org(args)
      tasks = Acs.Acs.list_tasks(status_filter, org)

      formatted =
        Enum.map(tasks, fn t ->
          %{
            slug: t.slug,
            title: t.title,
            description: t.description,
            status: t.status,
            kind: Map.get(t, :kind) || "coordination",
            created_by_agent: t.created_by_agent,
            locked_by_agent: t.locked_by_agent
          }
        end)

      {:ok, %{tasks: formatted, count: length(formatted), kind: "coordination"}}
    end
  end

  defp list_user_tasks(args) do
    org = authenticated_org(args)
    viewer = connected_user_from_args(args) || args["agent_id"]
    viewer_order = args["_auth_authority_sort_order"]

    if is_binary(viewer) and viewer != "" do
      opts =
        [org: org, for_user: args["for_user"], status: args["status_filter"]]
        |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
        |> then(fn o ->
          if is_integer(viewer_order),
            do: Keyword.put(o, :viewer_sort_order, viewer_order),
            else: o
        end)

      case Acs.UserTasks.list(viewer, opts) do
        {:ok, tasks} ->
          formatted =
            Enum.map(tasks, fn t ->
              %{
                slug: t.slug,
                title: t.title,
                description: t.description,
                status: t.status,
                kind: "user",
                assignee: t.assignee,
                due_at: t.due_at,
                remind_at: t.remind_at
              }
            end)

          {:ok, %{tasks: formatted, count: length(formatted), kind: "user"}}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      {:error, "connected user / agent_id required to list user tasks"}
    end
  end

  defp authenticated_org(args) do
    case Map.get(args, "_auth_org_id") do
      org when is_binary(org) and org != "" -> org
      _ -> Acs.Org.current()
    end
  end

  def get_logs(args) do
    mode = Map.get(args, "mode", "list")

    opts = [
      org: authenticated_org(args),
      level: Map.get(args, "level"),
      component: Map.get(args, "component"),
      module: Map.get(args, "module"),
      search: Map.get(args, "search"),
      action: Map.get(args, "action"),
      tags: Map.get(args, "tags"),
      service: Map.get(args, "service"),
      workflow_id: Map.get(args, "workflow_id"),
      execution_id: Map.get(args, "execution_id"),
      since: Map.get(args, "since"),
      until: Map.get(args, "until"),
      limit: Map.get(args, "limit") || 100,
      offset: Map.get(args, "offset") || 0,
      compact: Map.get(args, "compact") || false,
      before_id: Map.get(args, "before_id"),
      after_id: Map.get(args, "after_id"),
      context_size: Map.get(args, "context_size") || 5
    ]

    result = LogStore.get_logs(opts, mode)

    case mode do
      "summary" ->
        {:ok, result}

      "errors_with_context" ->
        {:ok,
         %{
           logs: result.logs,
           count: result.count,
           filtered_total: result.filtered_total,
           note: "Context entries are from the full log timeline (filters not applied to context)"
         }}

      _ ->
        {:ok,
         %{
           logs: result.logs,
           count: result.count,
           filtered_total: result.filtered_total,
           total: result.total
         }}
    end
  end

  def list_orgs(args) do
    app_name = Map.get(args, "app_name")
    orgs = Acs.Acs.list_orgs(app_name)

    records =
      Enum.map(orgs, fn o ->
        %{id: o["id"], name: o["name"], settings: o["settings"], inserted_at: o["inserted_at"]}
      end)

    {:ok, %{orgs: records, count: length(records)}}
  end

  def app_list(args) do
    apps = Acs.Apps.Config.list_apps(args["_auth_org_id"] || Acs.Org.current())

    entries =
      Enum.map(apps, fn {name, config} ->
        %{
          name: name,
          base_url: Keyword.get(config, :base_url),
          has_api_key: not is_nil(Keyword.get(config, :api_key)),
          auth_endpoint: Keyword.get(config, :auth_endpoint),
          auth_header_name: Keyword.get(config, :auth_header_name) || "authorization",
          auth_header_scheme: Keyword.get(config, :auth_header_scheme) || "Bearer",
          timeout_ms: Keyword.get(config, :timeout_ms) || 30_000
        }
      end)

    {:ok, %{apps: entries, count: length(entries)}}
  end

  def app_configure(args) do
    name = Map.get(args, "name")
    base_url = Map.get(args, "base_url")
    api_key = Map.get(args, "api_key")
    auth_endpoint = Map.get(args, "auth_endpoint")
    auth_header_name = Map.get(args, "auth_header_name")
    auth_header_scheme = Map.get(args, "auth_header_scheme")
    timeout_ms = Map.get(args, "timeout_ms")

    config =
      []
      |> then(fn c -> if base_url, do: Keyword.put(c, :base_url, base_url), else: c end)
      |> then(fn c -> if api_key, do: Keyword.put(c, :api_key, api_key), else: c end)
      |> then(fn c ->
        if auth_endpoint, do: Keyword.put(c, :auth_endpoint, auth_endpoint), else: c
      end)
      |> then(fn c ->
        if auth_header_name, do: Keyword.put(c, :auth_header_name, auth_header_name), else: c
      end)
      |> then(fn c ->
        if auth_header_scheme,
          do: Keyword.put(c, :auth_header_scheme, auth_header_scheme),
          else: c
      end)
      |> then(fn c -> if timeout_ms, do: Keyword.put(c, :timeout_ms, timeout_ms), else: c end)

    org = args["_auth_org_id"] || Acs.Org.current()
    Acs.Apps.Config.configure_app(name, config, org)
    {:ok, %{status: "ok", app: name}}
  end

  def app_remove(args) do
    name = Map.get(args, "name")
    org = args["_auth_org_id"] || Acs.Org.current()
    Acs.Apps.Config.remove_app(name, org)
    {:ok, %{status: "ok", app: name}}
  end

  def acs_time(%{"action" => "get"} = args) do
    with :ok <- authorize_time_read(args) do
      offset = Acs.Acs.get_time_offset()
      system_time = DateTime.utc_now()
      adjusted_time = Acs.Acs.get_time_offset()

      {:ok,
       %{
         time_offset: offset,
         system_time: system_time,
         adjusted_time: adjusted_time
       }}
    end
  end

  def acs_time(%{"action" => "set", "seconds" => seconds} = args) when is_integer(seconds) do
    with :ok <- authorize_time_write(args) do
      Acs.Acs.set_time_offset(seconds)
      {:ok, %{status: "ok", message: "Time offset set to #{seconds} seconds"}}
    end
  end

  def acs_time(%{"action" => "set"} = args) do
    seconds = args["seconds"]

    if is_nil(seconds) do
      {:error, "Missing required parameter: seconds"}
    else
      {:error, "seconds must be an integer"}
    end
  end

  def acs_time(%{"action" => action}) do
    {:error, "Unknown action '#{action}'. Use 'get' or 'set'."}
  end

  defp authorize_time_read(args) do
    role = Map.get(args, "_auth_role", "admin")

    if role in ["admin", "service", "collaborator"] do
      :ok
    else
      {:error, "Role '#{role}' is not authorized to read ACS time"}
    end
  end

  defp authorize_time_write(args) do
    role = Map.get(args, "_auth_role", "admin")

    if role in ["admin", "service"] do
      :ok
    else
      {:error, "Only admin or service roles may set ACS time offset"}
    end
  end

  defp claim_guidance_opts(args, mode) when is_map(args) do
    [
      mode: mode,
      agent_role: args["_auth_role"],
      authority_sort_order: args["_auth_authority_sort_order"],
      authority_level_slug: args["_auth_authority_level"],
      allowed_teams: args["_auth_allowed_teams"],
      allowed_projects: args["_auth_allowed_projects"]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  def list_plugins(_args) do
    Acs.MCP.ToolRegistry.list_plugins()
  end
end
