defmodule Acs.MCP.Tools do
  @moduledoc "MCP Tool definitions and implementations for Acs."
  alias Acs.MCP.Tools.ChatSurface
  alias Acs.MCP.Tools.CoreHandlers
  alias Acs.MCP.Tools.DynamicTools
  alias Acs.MCP.Tools.MemoryHandlers
  alias Acs.MCP.Tools.ErrorHandlers
  alias Acs.MCP.Tools.DiagnosticHandlers
  alias Acs.MCP.Tools.SkillHandlers
  alias Acs.MCP.Tools.AdminHandlers
  alias Acs.MCP.Tools.AuthorityHandlers
  alias Acs.MCP.Tools.QueryAgent
  alias Acs.MCP.Tools.PersonHandlers
  require Logger

  @tool_categories %{
    # Consolidated chat-only façade tools
    "steward_ask" => "knowledge",
    "steward_write" => "knowledge",
    "steward_work" => "acs_core",
    # ACS Core (workflow) tools
    "claim_work" => "acs_core",
    "release_work" => "acs_core",
    "close_work" => "acs_core",
    "create_work" => "acs_core",
    "resolve_user_task" => "acs_core",
    "lock_file" => "acs_core",
    "unlock_file" => "acs_core",
    "get_present_status" => "acs_core",
    "get_locked_files" => "acs_core",
    "list_tasks" => "acs_core",
    "time" => "acs_core",
    "get_logs" => "acs_core",
    "list_orgs" => "acs_core",
    "list_plugins" => "acs_core",
    "app_list" => "acs_core",
    "app_configure" => "acs_core",
    "app_remove" => "acs_core",
    "write_tool" => "acs_core",
    # Knowledge (memory) tools
    "save_memory" => "knowledge",
    "query_memories" => "knowledge",
    "get_person_status" => "knowledge",
    "set_person_status" => "knowledge",
    "list_authority_levels" => "knowledge",
    "set_memory_status" => "knowledge",
    "update_memory" => "knowledge",
    "generate_guidance_packet" => "knowledge",
    "ask" => "knowledge",
    # Specs tools
    "specs_get" => "specs",
    "query_specs" => "specs",
    "specs_propose" => "specs",
    "documents_propose" => "specs",
    "specs_approve" => "specs",
    "specs_reject" => "specs",
    # Diagnostic tools
    "help" => "diagnostic",
    "query" => "diagnostic",
    "config_lookup" => "diagnostic",
    "connection_diagnostic" => "diagnostic",
    "memory_health_check" => "diagnostic",
    # Error tools
    "list_error_traces" => "error",
    "ack_error_trace" => "error",
    "resolve_error_trace" => "error",
    "create_task_from_error_trace" => "error",
    "submit_task_feedback" => "error",
    # Skill tools
    "skill_get" => "skills",
    "skill_save" => "skills",
    "skill_audit_status" => "skills",
    "get_started" => "acs_core",
    # Admin tools
    "generate_developer_key" => "acs_core",
    "list_developer_keys" => "acs_core",
    "revoke_developer_key" => "acs_core",
    "create_org" => "acs_core",
    "upsert_authority_level" => "acs_core",
    "delete_authority_level" => "acs_core",
    "set_member_authority_level" => "acs_core"
  }

  def tool_category(name) do
    Map.get(@tool_categories, name)
  end

  def list_tools do
    [
      ChatSurface.steward_ask_def(),
      ChatSurface.steward_write_def(),
      ChatSurface.steward_work_def(),
      tool_def(
        "get_started",
        "Steward startup packet. Call first — returns connected_user (OAuth display name or acs_dev_ developer_name). Include that name in ask when fetching their memories. Omit agent_id on tool calls; never invent a nickname.",
        %{
          "agent_id" => %{
            "type" => "string",
            "description" =>
              "Optional. Prefer omit — ACS uses the signed-in user / MCP token name."
          },
          "audience" => %{
            "type" => "string",
            "description" =>
              "Optional override: coding (IDE agents) or chat (Claude/ChatGPT assistants)",
            "enum" => ["coding", "chat"]
          }
        },
        []
      ),
      tool_def(
        "claim_work",
        "Claim a task for an agent. Returns task status, task_id, and a guidance packet with relevant knowledge memories, relevant_skills, and relevant_specs (code specs and/or non-code documents). Review relevant_skills (skill_get) and relevant_specs (specs_get) before starting. Optionally pass scope_path for targeted guidance.",
        %{
          "agent_id" => %{
            "type" => "string",
            "description" =>
              "Your team member name (e.g., 'alice'). Used as your identity in the ACS."
          },
          "task_id" => %{
            "type" => "string",
            "description" => "Task slug (kebab-case from title, e.g. fix-login-bug)"
          },
          "scope_path" => %{
            "type" => "string",
            "description" =>
              "Optional scope: business domain (acme/support/refunds) or code path (lib/acs/memory). Returns targeted guidance for this scope."
          },
          "application" => %{"type" => "string"},
          "component" => %{"type" => "string"}
        },
        ["agent_id", "task_id"]
      ),
      tool_def(
        "release_work",
        "Release a task lock. Save skills/memories/specs (or documents) BEFORE calling this, then submit_task_feedback last to formally close. Do not tell the user you're done until feedback is submitted.",
        %{
          "agent_id" => %{"type" => "string", "description" => "Your team member name."},
          "task_id" => %{
            "type" => "string",
            "description" => "Task slug (kebab-case from title, e.g. fix-login-bug)"
          }
        },
        ["agent_id", "task_id"]
      ),
      tool_def(
        "close_work",
        "Single-call task close-out: optionally save a module spec/plan revision (pass app + path and spec fields), release the task and its file locks, then submit completion feedback. Returns combined results for spec save, release, and feedback. Prefer this over the manual specs_propose → release_work → submit_task_feedback sequence.",
        %{
          "agent_id" => %{"type" => "string", "description" => "Your team member name."},
          "task_id" => %{
            "type" => "string",
            "description" => "Task slug (kebab-case from title, e.g. fix-login-bug)"
          },
          "app" => %{
            "type" => "string",
            "description" =>
              "App or project name (e.g. steward_acs, acme-corp). Optional — omit to skip spec save."
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Entry path — module path (acs/memory/guidance) or document path (documents/marketing/campaign). Optional — omit to skip spec save."
          },
          "title" => %{"type" => "string", "description" => "Human-readable title"},
          "document_type" => %{
            "type" => "string",
            "description" =>
              "Kind of entry: \"spec\" for code module docs; knowledge|project|marketing|deliverable|policy|process|guideline|reference for non-code documents.",
            "enum" => [
              "spec",
              "knowledge",
              "project",
              "marketing",
              "deliverable",
              "policy",
              "process",
              "guideline",
              "reference"
            ]
          },
          "purpose" => %{
            "type" => "string",
            "description" => "For module specs: why this module exists"
          },
          "invariants" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Truths that must always hold"
          },
          "workflows" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Expected call sequences / protocols"
          },
          "failure_modes" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Known failure scenarios and handling"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Search tags"
          },
          "content" => %{
            "type" => "string",
            "description" => "Full markdown body for documents"
          },
          "learned_for_agents" => %{
            "type" => "string",
            "description" =>
              "What did you learn that will help agents in the future? This creates a memory visible to all agents."
          },
          "had_issues" => %{
            "type" => "string",
            "description" =>
              "What issues or obstacles did you encounter? Bugs, confusing guidance, time wasters."
          },
          "improvements" => %{
            "type" => "string",
            "description" =>
              "What could Steward do better? Feature requests, workflow improvements, missing capabilities."
          },
          "info_needed" => %{
            "type" => "string",
            "description" =>
              "What information was hard to find? Missing docs, poor search results, knowledge gaps."
          },
          "guidance_useful" => %{
            "type" => "boolean",
            "description" => "Was the guidance packet useful for this task/interaction?"
          }
        },
        ["agent_id", "task_id"]
      ),
      tool_def(
        "create_work",
        "Create a task. USE kind=user + due_at + remind_at (ISO-8601) for timed personal reminders (chat). USE claim=true without times for multi-step agent coordination work. User reminders do not use claim/lock. Assigning another person requires strictly higher clearance.",
        %{
          "agent_id" => %{
            "type" => "string",
            "description" => "Your team member name who creates this task."
          },
          "title" => %{"type" => "string"},
          "claim" => %{
            "type" => "boolean",
            "description" =>
              "Coordination only: set true to immediately claim (returns guidance). Ignored for kind=user."
          },
          "kind" => %{
            "type" => "string",
            "description" =>
              "\"user\" for timed reminders, or omit/\"coordination\" for agent work"
          },
          "assignee" => %{
            "type" => "string",
            "description" =>
              "User-task assignee (defaults to you). Other people only if you have higher clearance."
          },
          "due_at" => %{
            "type" => "string",
            "description" =>
              "User tasks: when the work is for (ISO-8601). Required with kind=user."
          },
          "remind_at" => %{
            "type" => "string",
            "description" =>
              "User tasks: when to start surfacing in get_started (ISO-8601, <= due_at). Required with kind=user."
          },
          "description" => %{"type" => "string"},
          "file_paths" => %{"type" => "array", "items" => %{"type" => "string"}},
          "application" => %{"type" => "string"},
          "component" => %{"type" => "string"}
        },
        ["agent_id", "title"]
      ),
      tool_def(
        "resolve_user_task",
        "Resolve a timed user reminder. USE WHEN pending_reminders from get_started need action, or the user completes/cancels/snoozes a reminder. outcome: done | dismiss | remind_later. remind_later REQUIRES remind_at — if the user gave no time, ask them before calling.",
        %{
          "agent_id" => %{"type" => "string"},
          "task_id" => %{
            "type" => "string",
            "description" => "Task slug (kebab-case from title, e.g. fix-login-bug)"
          },
          "outcome" => %{
            "type" => "string",
            "description" => "done | dismiss | remind_later"
          },
          "remind_at" => %{
            "type" => "string",
            "description" => "Required for remind_later: new ISO-8601 time to surface again"
          }
        },
        ["agent_id", "task_id", "outcome"]
      ),
      tool_def(
        "lock_file",
        "Lock a single file. Before the first lock, identify the current local checkout with `git rev-parse --show-toplevel`, read its AGENTS_STEWARD.md Repo: declaration, and confirm it is the repository you intend to work in. Pass that value as repo with repo_confirmed: true. The first successful lock establishes task/session repository scope; later repo mismatches fail.",
        %{
          "agent_id" => %{"type" => "string"},
          "task_id" => %{
            "type" => "string",
            "description" => "Task slug (e.g. fix-login-bug)"
          },
          "file_path" => %{"type" => "string"},
          "repo" => %{
            "type" => "string",
            "description" => "Required on the first lock; repository scope for this task"
          },
          "repo_confirmed" => %{
            "type" => "boolean",
            "description" =>
              "Required true on the first lock after verifying this is the intended local checkout"
          },
          "workspace_id" => %{
            "type" => "string",
            "description" => "Optional workspace or checkout identifier"
          }
        },
        ["agent_id", "task_id", "file_path"]
      ),
      tool_def(
        "unlock_file",
        "Unlock a file. Provide file_path to unlock a single file, or task_id to unlock all files for a task.",
        %{
          "agent_id" => %{"type" => "string"},
          "task_id" => %{
            "type" => "string",
            "description" => "Task slug to unlock all files for (alternative to file_path)"
          },
          "file_path" => %{"type" => "string"}
        },
        ["agent_id"]
      ),
      tool_def(
        "get_present_status",
        "Get current status of all agents.",
        %{
          "agent_id" => %{"type" => "string"},
          "status_filter" => %{
            "type" => "string",
            "description" => "Optional status filter"
          }
        },
        []
      ),
      tool_def(
        "get_locked_files",
        "Get all currently locked files",
        %{},
        []
      ),
      tool_def(
        "list_tasks",
        "List tasks. USE ONLY when the user explicitly asks about tasks. Default = coordination todos. Pass kind=\"user\" for personal reminders (defaults to connected user; optional for_user for managers with same/higher clearance). Do NOT call for pending_reminders — those come from get_started.",
        %{
          "status_filter" => %{
            "type" => "string",
            "description" =>
              "Optional: filter by status (todo, in_progress, in_review, done, blocked, dismissed, all). For kind=user: todo/done/dismissed/open."
          },
          "kind" => %{
            "type" => "string",
            "description" => "\"user\" for reminders; omit for coordination agent tasks"
          },
          "for_user" => %{
            "type" => "string",
            "description" =>
              "With kind=user: list another person's reminders (requires same or higher clearance)"
          }
        },
        []
      ),
      tool_def(
        "get_logs",
        "Retrieve application logs with optional filtering. Supports mode='list' (default, paginated results with filtered_total and total), mode='summary' (aggregated stats by level + top components + recent errors), or mode='errors_with_context' (error entries with surrounding context from full log timeline). Use compact=true for abbreviated output.",
        %{
          "level" => %{
            "type" => "string",
            "description" => "Minimum level: debug, info, warning, error"
          },
          "component" => %{
            "type" => "string",
            "description" => "Exact component (e.g. Acs::Acs::Cache)"
          },
          "module" => %{
            "type" => "string",
            "description" => "Partial match on module path (e.g. Acs, Cache)"
          },
          "search" => %{
            "type" => "string",
            "description" => "Substring match in message text (case-insensitive)"
          },
          "action" => %{
            "type" => "string",
            "description" => "Exact match on structured action field"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Filter by tags (AND logic)"
          },
          "workflow_id" => %{"type" => "string"},
          "execution_id" => %{"type" => "string"},
          "since" => %{"type" => "string", "description" => "ISO8601 start time"},
          "until" => %{"type" => "string", "description" => "ISO8601 end time"},
          "limit" => %{"type" => "integer", "description" => "Max results (default: 100)"},
          "offset" => %{
            "type" => "integer",
            "description" => "Number of matching entries to skip (default: 0)"
          },
          "compact" => %{
            "type" => "boolean",
            "description" => "Return compact format (fewer tokens)"
          },
          "before_id" => %{
            "type" => "integer",
            "description" => "Cursor: get entries before this ID"
          },
          "after_id" => %{
            "type" => "integer",
            "description" => "Cursor: get entries after this ID"
          },
          "mode" => %{"type" => "string", "enum" => ["list", "summary", "errors_with_context"]},
          "context_size" => %{
            "type" => "integer",
            "description" => "Context lines before error (mode: errors_with_context)"
          }
        },
        []
      ),
      tool_def(
        "list_orgs",
        "List organizations from a configured app. Specify app_name to target a specific app, or omit for the default.",
        %{
          "app_name" => %{
            "type" => "string",
            "description" => "Optional: target a specific app (e.g. 'my_app')"
          }
        },
        []
      ),
      tool_def(
        "time",
        "Get or set ACS time offset. Use action='get' to view current time info, action='set' with seconds to adjust the time offset.",
        %{
          "action" => %{
            "type" => "string",
            "description" => "Action: 'get' (view time info) or 'set' (set time offset)"
          },
          "seconds" => %{
            "type" => "integer",
            "description" => "Time offset in seconds (required when action='set')"
          }
        },
        ["action"]
      ),
      # Memory System Tools
      tool_def(
        "save_memory",
        "Create a new proposed memory entry. Memories are stored in the database (append-only ledger); no filesystem directory setup is needed. Memories are ETERNAL TRUTHS — principles, invariants, or axioms that remain true and useful indefinitely. NOT events, not historical facts, not one-time occurrences. USE WHEN: you discover something that will stay relevant — a reusable learning, decision, pattern, invariant, or truth that other agents should know about forever. After completing significant work, save key insights so the collective knowledge grows. Returns proposed memory id and any conflict flags.\n\nTitle quality is critical: use a complete, specific statement that is self-explanatory without reading the content. Bad: \"Key learning from task abc123\" (tells you nothing). Good: \"HubSpot search API page_size = 200\" (tells you exactly what).\n\nContent must explain WHY, not just WHAT. A good memory reveals a non-obvious truth — something an agent would waste time discovering on their own. Content that just restates obvious code structure is noise.\n\nScope should match where the knowledge applies. Prefer specific code paths (lib/anantha_os/crm) over generic ones. One memory = one fact. Do not batch multiple unrelated learnings into one entry.\n\nExamples of GOOD memory topics:\n- \"LiveViews subscribing to PubSub must have catch-all handle_info to avoid crashes from unhandled messages\" — specific, actionable, explains why\n- \"The ACS loader extracts and indexes semantic content; it does NOT parse structural relationships\" — non-obvious, defines boundary\n- \"DynamicSupervisor children must have unique names or identical child specs will conflict\" — root cause pattern\n- \"HubSpot search API page_size = 200\" — exact number, saves debugging time\n- \"CRM error tuples must be propagated, not pattern-matched with _\" — concrete rule with rationale\n\nExamples of BAD memory topics (these are EVENTS, not eternal truths):\n- \"Fixed GenServer crashes in 3 ACS LiveViews\" (this is what you DID, not what you LEARNED)\n- \"Updated the memory schema on 2024-01-15\" (historical fact, will become stale)\n- \"Added new save_memory endpoint\" (one-time event, not a reusable principle)\n- \"Key learning from task abc123\" (vague — what was learned?)\n- \"ACS memory cleanup 2026-06-20\" (one-time event, not an eternal truth)\n\nWhat NOT to write:\n- Task feedback artifacts: \"Guidance rated as useful\" or \"Information gap identified\" — these belong in submit_task_feedback, not as eternal truths\n- Event logs: \"Fixed bug in X\", \"Added Y feature\", \"Cleanup on date Z\" — these are what happened, not what was learned\n- Obvious-from-code statements: restating what the code already makes clear (e.g., \"The function returns a tuple\") adds no value\n- Content too short to be useful: a single sentence with no why or context\n- Trivial or test-only content: patterns from test harnesses that don't apply to production code\n- Batch dumps: multiple unrelated learnings crammed into one entry — split them\n\nThe 'kind' field (e.g., observation, learning, warning, pattern, bug, decision, invariant, axiom) describes the TYPE of learning, but the CONTENT must always be an eternal truth or principle. Use `learning` for facts, `bug` for root cause patterns (not one-time fix notes), `pattern` for reusable approaches, `warning` for pitfalls, `decision` for tradeoffs, `axiom` only for truly foundational truths (rare).",
        %{
          "kind" => %{
            "type" => "string",
            "description" =>
              "Memory kind: observation, learning, warning, pattern, bug, decision, invariant, axiom"
          },
          "title" => %{"type" => "string", "description" => "Title of the memory"},
          "content" => %{
            "type" => "string",
            "description" => "Full markdown content of the memory"
          },
          "scope_path" => %{
            "type" => "string",
            "description" =>
              "Hierarchical scope label — business domain (acme/sales/pricing) or code path (lib/acs/memory). Prefer business scopes for org knowledge."
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags for categorization"
          },
          "triggers" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Trigger events"
          },
          "importance" => %{
            "type" => "integer",
            "description" => "Importance 1-5"
          },
          "summary" => %{"type" => "string", "description" => "Brief summary"},
          "failure_modes" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Potential failure modes"
          },
          "visibility" => %{
            "type" => "string",
            "description" =>
              "org (default) | team | project | personal. personal = only the creator can read it."
          },
          "team" => %{"type" => "string", "description" => "Required when visibility=team"},
          "project" => %{
            "type" => "string",
            "description" => "Required when visibility=project"
          },
          "confidential" => %{
            "type" => "boolean",
            "description" => "Shortcut for visibility=personal (creator-only)."
          },
          "about_type" => %{
            "type" => "string",
            "description" =>
              "Entity this fact is about: person | company (not who may read it — that is visibility)."
          },
          "about_name" => %{
            "type" => "string",
            "description" => "Display name of the about entity"
          },
          "about_email" => %{
            "type" => "string",
            "description" => "Email when about_type is person"
          },
          "intake_confirmed" => %{
            "type" => "boolean",
            "description" =>
              "Set true after answering intake needs_input questions to proceed with save."
          },
          "about_person_email" => %{
            "type" => "string",
            "description" => "Legacy alias of about_email"
          },
          "about_person_name" => %{
            "type" => "string",
            "description" => "Legacy alias of about_name (implies about_type=person)"
          }
        },
        ["kind", "title", "content", "scope_path"]
      ),
      tool_def(
        "get_person_status",
        "Look up a person's job status/title and data authority level (org-defined label/slug). USE WHEN: first encounter with a person for authority attribution. If not found, ask once and call set_person_status. Call list_authority_levels for allowed ranks.",
        %{
          "email" => %{"type" => "string", "description" => "Person email (preferred)"},
          "name" => %{"type" => "string", "description" => "Person display name"}
        },
        []
      ),
      tool_def(
        "set_person_status",
        "Save or update a person's job status/title and data authority level. Rank may be an org level slug or exact label from list_authority_levels.",
        %{
          "email" => %{"type" => "string", "description" => "Person email (preferred)"},
          "name" => %{"type" => "string", "description" => "Person display name"},
          "status" => %{
            "type" => "string",
            "description" => "Job title / role label, e.g. CEO, VP Sales, Engineer"
          },
          "rank" => %{
            "type" => "string",
            "description" =>
              "Org authority level slug or label (default standard). Call list_authority_levels."
          }
        },
        ["status"]
      ),
      tool_def(
        "list_authority_levels",
        "List this org's data authority levels (slug, label, sort_order). 1 = highest clearance. Use when assigning person ranks or explaining access.",
        %{},
        []
      ),
      tool_def(
        "upsert_authority_level",
        "Create or update an org data authority level (admin only). Pass label (required); slug auto-derived if omitted. sort_order: 1 = highest.",
        %{
          "label" => %{"type" => "string", "description" => "Human-readable name"},
          "slug" => %{"type" => "string", "description" => "Stable id (optional)"},
          "sort_order" => %{
            "type" => "integer",
            "description" => "1 = highest clearance"
          }
        },
        ["label"]
      ),
      tool_def(
        "delete_authority_level",
        "Delete an org data authority level by slug (admin only). If in use, returns needs_remap — retry with remap: promote|demote|<slug>. Org must keep at least one level.",
        %{
          "slug" => %{"type" => "string", "description" => "Level slug to delete"},
          "remap" => %{
            "type" => "string",
            "description" =>
              "Required when the level is in use: promote (nearest higher), demote (nearest lower), or a remaining level slug/label"
          }
        },
        ["slug"]
      ),
      tool_def(
        "set_member_authority_level",
        "Set a Steward member's data authority clearance (admin OAuth user only). They can read memories at this level and lower.",
        %{
          "email" => %{"type" => "string", "description" => "Member email"},
          "user_id" => %{"type" => "integer", "description" => "Member user id"},
          "authority_level" => %{
            "type" => "string",
            "description" => "Level slug or label from list_authority_levels"
          }
        },
        ["authority_level"]
      ),
      tool_def(
        "query_memories",
        "Query memories with optional filters. If `query` is provided, performs hybrid search (semantic + FTS) across titles, summaries, and content. If `query` is omitted, lists memories by filters. USE WHEN: starting a task that might have prior art, browsing what knowledge exists for a component, or checking status of proposed memories.",
        %{
          "query" => %{
            "type" => "string",
            "description" =>
              "Search query text (optional — if provided, does hybrid search; if omitted, lists by filters)"
          },
          "mode" => %{
            "type" => "string",
            "description" =>
              "Search mode: 'auto' (default, hybrid), 'keyword' (FTS only), 'semantic' (vector only). Only used when query is provided."
          },
          "min_relevance" => %{
            "type" => "number",
            "description" =>
              "Minimum relevance score (0.0-1.0) to filter results. Only used when query is provided."
          },
          "scope_path" => %{
            "type" => "string",
            "description" => "Filter by scope path prefix"
          },
          "kind" => %{"type" => "string", "description" => "Filter by memory kind"},
          "status" => %{
            "type" => "string",
            "description" =>
              "Filter by status (default: approved). Use 'all' for no filter. Values: proposed, approved, rejected, stale, deprecated, archived"
          },
          "limit" => %{"type" => "integer", "description" => "Max results"},
          "repo" => %{
            "type" => "string",
            "description" => "Repository filter; the first lock establishes this scope"
          },
          "repo_mode" => %{
            "type" => "string",
            "description" => "Repository mode: exact, local, or blended"
          },
          "origin" => %{"type" => "string", "description" => "Memory origin: agent or chat"}
        },
        []
      ),
      tool_def(
        "set_memory_status",
        "Update a memory's status (approved/rejected/stale/deprecated). Approving makes it visible to agents. Rejecting prevents it from being used. Marking stale flags it for review. Marking deprecated retires obsolete entries. Chat connectors may only set stale or deprecated.",
        %{
          "memory_id" => %{"type" => "string", "description" => "Memory ID to update"},
          "status" => %{
            "type" => "string",
            "description" =>
              "New status: approved, rejected, stale, or deprecated (chat: stale or deprecated only)"
          },
          "notes" => %{
            "type" => "string",
            "description" => "Optional notes or reason for the status change"
          }
        },
        ["memory_id", "status"]
      ),
      tool_def(
        "update_memory",
        "Replace fields on an existing memory (database-backed, append-only ledger — no filesystem setup needed). Resolve the memory by `memory_id` (from a save_memory/query_memories result) or by `title` (optionally plus `scope_path`). Only the provided fields are replaced; content and provenance (create/revise revision history, actor) are preserved. Requires edit permission for the memory. No create fallback — if the memory does not exist, the call errors.",
        %{
          "memory_id" => %{
            "type" => "string",
            "description" =>
              "Memory ID to update (preferred). Safe public handle from save_memory/query_memories."
          },
          "title" => %{
            "type" => "string",
            "description" =>
              "Resolve by exact title (optionally with scope_path) when memory_id is omitted. Also updatable when memory_id is given."
          },
          "scope_path" => %{
            "type" => "string",
            "description" => "Scope for title resolution, e.g. acme/sales/pricing or lib/acs"
          },
          "content" => %{
            "type" => "string",
            "description" => "New full markdown content (replaces existing content)"
          },
          "summary" => %{
            "type" => "string",
            "description" => "New brief summary"
          },
          "importance" => %{
            "type" => "integer",
            "description" => "New importance 1-5"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "New tags"
          },
          "triggers" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "New trigger events"
          },
          "failure_modes" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "New known failure scenarios and handling"
          },
          "related_memories" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "New related memory IDs"
          }
        },
        []
      ),
      tool_def(
        "generate_guidance_packet",
        "Generate an audience-specific guidance packet for a scope.\n\nTwo completely different shapes (not the same map with blanks):\n- coding/mcp — workflow, file locks, tool refs, code specs\n- chat/knowledge — retrieve/answer/save; store + honesty; no locks\n\nScopes: business domains (acme/support/refunds) OR code paths. Defaults from MCP session audience (clientInfo).",
        %{
          "scope_path" => %{
            "type" => "string",
            "description" =>
              "Business scope (org/domain/topic) or code scope (path/to/module), e.g. acme/sales/pricing or lib/acs"
          },
          "task_id" => %{
            "type" => "string",
            "description" => "Optional task ID/slug to derive scope from"
          },
          "mode" => %{
            "type" => "string",
            "description" =>
              "Output mode: mcp|coding (file locks, tool refs) or knowledge|chat (retrieve/save knowledge, no file locks). Defaults from session audience.",
            "enum" => ["mcp", "knowledge", "coding", "chat"]
          },
          "audience" => %{
            "type" => "string",
            "description" => "Alias for mode: coding or chat",
            "enum" => ["coding", "chat"]
          }
        },
        []
      ),
      tool_def(
        "ask",
        "Steward primary retrieve — search org memories, documents, related skills, and agent status in one call. USE WHEN answering questions about org knowledge, status, procedures, or prior decisions. Include the connected ACS user name (from get_started.connected_user — OAuth display name or acs_dev_ developer_name) in content_query when fetching that person's memories. (Chat connectors do not expose separate query_memories / query_specs.)",
        %{
          "kind" => %{
            "type" => "string",
            "description" =>
              "Memory kind filter: context, status, work_note, activity, observation, learning, warning, pattern, bug, decision, invariant, axiom"
          },
          "team" => %{"type" => "string", "description" => "Team scope filter"},
          "project" => %{"type" => "string", "description" => "Project scope filter"},
          "content_query" => %{
            "type" => "string",
            "description" =>
              "Full-text search for memories, documents, and skills. Include connected_user name when asking for that person's memories."
          },
          "document_type" => %{
            "type" => "string",
            "description" =>
              "Document type: spec, knowledge, project, marketing, deliverable, policy, process, guideline, reference"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max results per category (default 10, max 50)"
          },
          "include_documents" => %{
            "type" => "boolean",
            "description" => "Include documents in results (default true)"
          },
          "include_skills" => %{
            "type" => "boolean",
            "description" => "Include related skills in results (default true)"
          },
          "include_agent_status" => %{
            "type" => "boolean",
            "description" => "Include agent presence (default true)"
          },
          "status" => %{
            "type" => "string",
            "description" =>
              "Memory status filter (default: approved). Use 'all' for no filter. Values: proposed, approved, rejected, stale, deprecated, archived"
          }
        },
        []
      ),
      # Specs Tools
      tool_def(
        "specs_get",
        "Load a **spec** or **document** body by app + path (default). Returns content only — documents: app/path/title/content; module specs: purpose/invariants/workflows/failure_modes (plus other body fields if set). No tags, status, audit, or governance fields. List/search with query_specs first to discover paths.",
        %{
          "app" => %{"type" => "string", "description" => "App name (e.g., 'my_app')"},
          "path" => %{
            "type" => "string",
            "description" =>
              "Entry path (e.g. 'acs/memory/guidance' or 'documents/marketing/q3-launch')"
          }
        },
        ["app", "path"]
      ),
      tool_def(
        "query_specs",
        "Search **specs** and **documents** — returns discovery cards (app, path, title, purpose) without bodies. Use specs_get(app:, path:) to load content. Hybrid search by default. Use `undocumented: true` only for code modules missing specs.",
        %{
          "query" => %{"type" => "string", "description" => "Search query text (optional)"},
          "app" => %{"type" => "string", "description" => "Optional app filter"},
          "status" => %{"type" => "string", "description" => "Optional status filter"},
          "undocumented" => %{
            "type" => "boolean",
            "description" => "Set to true to find modules without spec entries"
          },
          "limit" => %{"type" => "integer", "description" => "Max results"},
          "mode" => %{
            "type" => "string",
            "description" =>
              "Search mode: 'hybrid' (keyword+vector/RAG, default), 'keyword' (substring), or 'semantic' (vector/RAG with source)",
            "enum" => ["hybrid", "keyword", "semantic"]
          }
        },
        []
      ),
      tool_def(
        "specs_propose",
        specs_propose_description(),
        propose_entry_properties(),
        ["app", "path"]
      ),
      tool_def(
        "documents_propose",
        documents_propose_description(),
        propose_entry_properties(),
        ["app", "path"]
      ),
      tool_def(
        "specs_approve",
        "Approve a proposed spec entry. Sets status to 'approved'.",
        %{
          "app" => %{"type" => "string", "description" => "App name"},
          "path" => %{"type" => "string", "description" => "Spec path"},
          "reviewer" => %{"type" => "string", "description" => "Reviewer identifier"}
        },
        ["app", "path", "reviewer"]
      ),
      tool_def(
        "specs_reject",
        "Soft-reject a spec entry. Reverts status to 'under_review'.",
        %{
          "app" => %{"type" => "string", "description" => "App name"},
          "path" => %{"type" => "string", "description" => "Spec path"}
        },
        ["app", "path"]
      ),
      # Error Trace Tools
      tool_def(
        "list_error_traces",
        "Find recurring errors that have been logged by the system. Each trace shows an error pattern, how many times it occurred, and when it was last seen.",
        %{
          "status" => %{
            "type" => "string",
            "description" => "Filter by status: new, acknowledged, resolved, tasked, failed"
          },
          "service" => %{"type" => "string", "description" => "Filter by service name"},
          "component" => %{"type" => "string", "description" => "Filter by component name"},
          "min_count" => %{"type" => "integer", "description" => "Minimum occurrence count"},
          "limit" => %{"type" => "integer", "description" => "Max results (default: 50)"}
        },
        []
      ),
      tool_def(
        "ack_error_trace",
        "Mark an error as 'in progress' so other agents know someone is already looking into it.",
        %{
          "trace_id" => %{"type" => "string", "description" => "Error trace ID to acknowledge"}
        },
        ["trace_id"]
      ),
      tool_def(
        "resolve_error_trace",
        "Mark an error as fixed/closed after the issue has been investigated and resolved.",
        %{
          "trace_id" => %{"type" => "string", "description" => "Error trace ID to resolve"}
        },
        ["trace_id"]
      ),
      tool_def(
        "create_task_from_error_trace",
        "Turn an error trace into a task that an agent can claim and fix. The error is marked as 'tasked' to avoid duplicate work.",
        %{
          "trace_id" => %{"type" => "string", "description" => "Error trace ID"},
          "agent_id" => %{
            "type" => "string",
            "description" => "Agent to assign the task to (default: error_trace_system)"
          }
        },
        ["trace_id"]
      ),
      # Task Completion Feedback
      tool_def(
        "submit_task_feedback",
        "Submit feedback to help improve Steward. Feedback is a system review — tell us what worked, what didn't, and what's missing so we can clean up noisy memories/documents/skills and improve guidance. Auto-generates knowledge memories from your learnings. Two modes: (1) tracked task feedback — pass task_id after release_work; (2) standalone feedback — omit task_id whenever ask/skill_get returned empty or wrong knowledge, or a tool/workflow was painful. Chat agents: prefer standalone feedback on knowledge gaps; do not wait for a tracked task.",
        %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Optional task slug (e.g. fix-login-bug). Omit for standalone feedback without a task."
          },
          "agent_id" => %{
            "type" => "string",
            "description" =>
              "Your team member name (e.g., 'alice'). Used as your identity in the ACS."
          },
          "learned_for_agents" => %{
            "type" => "string",
            "description" =>
              "What did you learn that will help agents in the future? This creates a memory visible to all agents. Use this for: new insights, workarounds, patterns discovered."
          },
          "had_issues" => %{
            "type" => "string",
            "description" =>
              "What issues or obstacles did you encounter? Use this for: bugs, confusing guidance, things that wasted your time."
          },
          "improvements" => %{
            "type" => "string",
            "description" =>
              "What could Steward do better? Use this for: feature requests, workflow improvements, missing capabilities."
          },
          "tools_wish_list" => %{
            "type" => "string",
            "description" => "What tools or capabilities would make future work easier?"
          },
          "info_needed" => %{
            "type" => "string",
            "description" =>
              "What information was hard to find? Use this for: missing docs, poor search results, knowledge gaps."
          },
          "guidance_useful" => %{
            "type" => "boolean",
            "description" => "Was the guidance packet useful for this task/interaction?"
          },
          "guidance_items_helpful" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Memory IDs from the guidance packet that were helpful"
          },
          "guidance_items_confusing" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Memory IDs from the guidance packet that were confusing or unhelpful"
          },
          "guidance_missing" => %{
            "type" => "string",
            "description" => "What guidance was needed but missing from the packet?"
          }
        },
        ["agent_id"]
      ),
      tool_def(
        "help",
        "Returns a comprehensive reference of all available MCP tools with their levels, categories, and descriptions. Use this to discover what tools exist and how to access them. Unlike the default tool listing (which only shows level 1), this queries all tools directly and shows their true access levels.",
        %{
          "category" => %{
            "type" => "string",
            "description" => "Filter tools by category (e.g., 'acs_core', 'knowledge', 'specs')"
          },
          "level" => %{
            "type" => "integer",
            "description" =>
              "Filter: show tools at this level and below (progressive disclosure). Default: shows all levels."
          }
        },
        []
      ),
      tool_def(
        "query",
        "Query ACS telemetry data with read-only SQL (SELECT, WITH, EXPLAIN). Aggregates allowed. No writes.",
        %{
          "sql" => %{
            "type" => "string",
            "description" => "Read-only SQL query (SELECT/WITH/EXPLAIN only)"
          },
          "purpose" => %{"type" => "string", "description" => "What you're trying to find"}
        },
        ["sql"]
      ),
      tool_def(
        "config_lookup",
        "Look up opencode configuration settings. Returns agent config, skills, plugins, and MCP server settings.",
        %{
          "path" => %{
            "type" => "string",
            "description" => "Config path to look up (e.g. 'agents', 'skills', 'plugins', 'mcp')"
          },
          "key" => %{"type" => "string", "description" => "Specific key to retrieve (optional)"}
        },
        []
      ),
      tool_def(
        "connection_diagnostic",
        "Check if external services (ACS, database, LLM providers) are reachable. Returns connectivity status for each service.",
        %{
          "service" => %{
            "type" => "string",
            "description" =>
              "Specific service to check: 'acs', 'database', 'llm', or 'all' (default)"
          },
          "verbose" => %{
            "type" => "boolean",
            "description" => "Include detailed error info (default: false)"
          }
        },
        []
      ),
      tool_def(
        "memory_health_check",
        "Check the health status of the Anantha memory system. Returns overall health score, pipeline status, DLQ metrics, data flow statistics, and any issues detected. Use this to verify data has been added correctly and identify problems. Specify org_id to filter by organization, or omit for global view.",
        %{
          "org_id" => %{
            "type" => "string",
            "description" =>
              "Optional org ID to scope the health check to a specific organization"
          }
        },
        []
      ),
      tool_def(
        "list_plugins",
        "List all registered plugin apps with their metadata, tool counts, and health status. Returns app name, version, plugin source info, and tools provided by each plugin.",
        %{},
        []
      ),
      tool_def(
        "app_list",
        "List all configured external apps with their base URL, auth status, and endpoint info.",
        %{},
        []
      ),
      tool_def(
        "app_configure",
        "Add or update a configured external app at runtime.",
        %{
          "name" => %{"type" => "string", "description" => "App name (e.g. 'my_app')"},
          "base_url" => %{"type" => "string", "description" => "Root URL of the app"},
          "api_key" => %{
            "type" => "string",
            "description" => "API key for authenticating with the app"
          },
          "auth_endpoint" => %{
            "type" => "string",
            "description" => "Auth validation endpoint path (default: /api/auth/validate-key)"
          },
          "auth_header_name" => %{
            "type" => "string",
            "description" => "HTTP header for API key (default: 'authorization')"
          },
          "auth_header_scheme" => %{
            "type" => "string",
            "description" =>
              "Auth scheme prefix, e.g. 'Bearer', or '' for raw key (default: 'Bearer')"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Request timeout in milliseconds (default: 30000)"
          }
        },
        ["name"]
      ),
      tool_def(
        "app_remove",
        "Remove a configured external app at runtime.",
        %{
          "name" => %{"type" => "string", "description" => "App name to remove"}
        },
        ["name"]
      ),
      tool_def(
        "skill_get",
        "Retrieve skills — reusable workflow guides. Pass `name` to load the procedure body (returns name + content only — list/search first for discovery). Pass search/tag/scope_path (or nothing for catalog) to list lean cards: name, description, when_to_use, tags. USE BEFORE: deployment, secrets, install, support playbooks, or any repeatable procedure.",
        %{
          "name" => %{
            "type" => "string",
            "description" =>
              "Skill name — returns the procedure body (name + content). List/search first to discover names."
          },
          "scope_path" => %{
            "type" => "string",
            "description" =>
              "Business or code scope (e.g. acme/ops/onboarding, lib/acs/skills) — returns skills for this scope"
          },
          "search" => %{
            "type" => "string",
            "description" => "Search query across skill names, descriptions, tags, and content"
          },
          "tag" => %{
            "type" => "string",
            "description" => "Filter skills by tag"
          },
          "mode" => %{
            "type" => "string",
            "description" =>
              "Search mode when using search: hybrid (keyword+vector, default), keyword, or semantic",
            "enum" => ["hybrid", "keyword", "semantic"]
          }
        },
        []
      ),
      tool_def(
        "skill_save",
        skill_save_description(),
        %{
          "name" => %{
            "type" => "string",
            "description" => "Unique skill name (e.g. 'secrets-management')"
          },
          "content" => %{
            "type" => "string",
            "description" => "Skill body content (markdown)"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags for categorization"
          },
          "description" => %{
            "type" => "string",
            "description" => "Short description of what this skill covers"
          },
          "when_to_use" => %{
            "type" => "string",
            "description" => "When agents should load this skill (one sentence)"
          },
          "scope_paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Scope paths where this skill applies (e.g. guides/deployment, lib/acs/skills)"
          },
          "intake_confirmed" => %{
            "type" => "boolean",
            "description" =>
              "Bypass intake questions after user confirmed (or after fixing). Prefer fixing then retry without this when possible."
          }
        },
        ["name", "content"]
      ),
      tool_def(
        "skill_audit_status",
        "Run LLM quality audit on all skills. Returns audit_status (ok/needs_improvement/failing), score, and reasoning per skill. Audit prompts are editable in priv/prompts/skills/evaluate.md. Call after skill_save to verify quality.",
        %{},
        []
      ),
      tool_def(
        "generate_developer_key",
        "Generate a new developer API key (acs_dev_... prefix). The key is scoped to the caller's org. Admin only.",
        %{
          "developer_name" => %{
            "type" => "string",
            "description" => "Human-readable name identifying the developer"
          },
          "role" => %{
            "type" => "string",
            "description" =>
              "Role: admin, service, reader, or collaborator (default: collaborator)"
          }
        },
        ["developer_name"]
      ),
      tool_def(
        "list_developer_keys",
        "List all developer API keys with their metadata (name, role, org, active status, last used). Admin only.",
        %{},
        []
      ),
      tool_def(
        "revoke_developer_key",
        "Revoke a developer API key by developer_name. The key will no longer authenticate. Admin only.",
        %{
          "developer_name" => %{
            "type" => "string",
            "description" =>
              "Name of the developer whose key to revoke (from list_developer_keys)"
          }
        },
        ["developer_name"]
      ),
      tool_def(
        "create_org",
        "Provision a new organization with subdomain URL. Also mints an org-scoped collaborator developer API key and returns it once as developer_key (store it immediately — it cannot be retrieved again). Creates vault directory. Admin only. Multi-tenant mode required.",
        %{
          "name" => %{"type" => "string", "description" => "Display name (e.g. Acme Corp)"},
          "slug" => %{"type" => "string", "description" => "URL slug (e.g. acme)"},
          "subdomain" => %{
            "type" => "string",
            "description" => "Subdomain override (defaults to slug)"
          }
        },
        ["name", "slug"]
      )
    ]
  end

  defp tool_def(name, desc, props, required) do
    %{
      "name" => name,
      "description" => desc,
      "inputSchema" => %{"type" => "object", "properties" => props, "required" => required}
    }
  end

  @simple_dispatch %{
    "steward_ask" => &ChatSurface.steward_ask/1,
    "steward_write" => &ChatSurface.steward_write/1,
    "steward_work" => &ChatSurface.steward_work/1,
    "claim_work" => &CoreHandlers.acs_claim_work/1,
    "release_work" => &CoreHandlers.acs_release_work/1,
    "close_work" => &CoreHandlers.acs_close_work/1,
    "create_work" => &CoreHandlers.acs_create_work/1,
    "resolve_user_task" => &CoreHandlers.acs_resolve_user_task/1,
    "lock_file" => &CoreHandlers.acs_lock_file/1,
    "unlock_file" => &CoreHandlers.acs_unlock_file/1,
    "get_present_status" => &CoreHandlers.acs_get_present_status/1,
    "get_locked_files" => &CoreHandlers.acs_get_locked_files/1,
    "list_tasks" => &CoreHandlers.acs_list_tasks/1,
    "get_logs" => &CoreHandlers.get_logs/1,
    "list_orgs" => &CoreHandlers.list_orgs/1,
    "time" => &CoreHandlers.acs_time/1,
    "save_memory" => &MemoryHandlers.save_memory/1,
    "query_memories" => &MemoryHandlers.query_memories/1,
    "get_person_status" => &PersonHandlers.get_person_status/1,
    "set_person_status" => &PersonHandlers.set_person_status/1,
    "list_authority_levels" => &AuthorityHandlers.list_authority_levels/1,
    "upsert_authority_level" => &AuthorityHandlers.upsert_authority_level/1,
    "delete_authority_level" => &AuthorityHandlers.delete_authority_level/1,
    "set_member_authority_level" => &AuthorityHandlers.set_member_authority_level/1,
    "set_memory_status" => &MemoryHandlers.set_memory_status/1,
    "update_memory" => &MemoryHandlers.update_memory/1,
    "generate_guidance_packet" => &MemoryHandlers.generate_guidance_packet/1,
    "ask" => &QueryAgent.ask/1,
    "list_error_traces" => &ErrorHandlers.list_error_traces/1,
    "ack_error_trace" => &ErrorHandlers.ack_error_trace/1,
    "resolve_error_trace" => &ErrorHandlers.resolve_error_trace/1,
    "create_task_from_error_trace" => &ErrorHandlers.create_task_from_error_trace/1,
    "submit_task_feedback" => &ErrorHandlers.acs_submit_task_feedback/1,
    "help" => &DiagnosticHandlers.acs_help/1,
    "query" => &DiagnosticHandlers.acs_query/1,
    "config_lookup" => &DiagnosticHandlers.config_lookup/1,
    "connection_diagnostic" => &DiagnosticHandlers.connection_diagnostic/1,
    "memory_health_check" => &DiagnosticHandlers.memory_health_check/1,
    "list_plugins" => &CoreHandlers.list_plugins/1,
    "app_list" => &CoreHandlers.app_list/1,
    "app_configure" => &CoreHandlers.app_configure/1,
    "app_remove" => &CoreHandlers.app_remove/1,
    "skill_get" => &SkillHandlers.skill_get/1,
    "skill_save" => &SkillHandlers.skill_save/1,
    "skill_audit_status" => &SkillHandlers.skill_audit_status/1,
    "get_started" => &CoreHandlers.acs_get_started/1,
    "generate_developer_key" => &AdminHandlers.generate_key/1,
    "list_developer_keys" => &AdminHandlers.list_keys/1,
    "revoke_developer_key" => &AdminHandlers.revoke_key/1,
    "create_org" => &AdminHandlers.create_org/1
  }

  defp dispatch_map do
    # Tools needing closures (partial application) built at runtime
    %{
      "write_tool" => &DynamicTools.call_tool("write_tool", &1),
      "specs_get" => &Acs.Specs.Tools.call_tool("specs_get", &1),
      "query_specs" => &Acs.Specs.Tools.call_tool("query_specs", &1),
      "specs_propose" => &Acs.Specs.Tools.call_tool("specs_propose", &1),
      "documents_propose" => &Acs.Specs.Tools.call_tool("documents_propose", &1),
      "specs_approve" => &Acs.Specs.Tools.call_tool("specs_approve", &1),
      "specs_reject" => &Acs.Specs.Tools.call_tool("specs_reject", &1)
    }
  end

  def call_tool(name, args) do
    # Chat OAuth: agents often pass agent_id "" (coding get_started habit). Blank means
    # "use authenticated identity" — don't require a separate agent name.
    args = args |> coerce_agent_id() |> bind_working_context(name)

    with :ok <- validate_agent_identity(args) do
      Acs.IdleTracker.touch()

      if agent_id = Map.get(args, "agent_id") do
        case Acs.Acs.Cache.get_agent_status(agent_id) do
          {:ok, nil} ->
            Acs.Acs.put_agent_status(agent_id, %{
              purpose: "active",
              current_task_id: nil
            })

          _ ->
            Acs.Acs.Cache.touch_agent_status(agent_id)
        end

        Acs.touch_task_lease(agent_id)
      end

      result =
        case Map.fetch(@simple_dispatch, name) do
          {:ok, fun} ->
            fun.(args)

          :error ->
            case Map.fetch(dispatch_map(), name) do
              {:ok, fun} ->
                fun.(args)

              :error ->
                {:error, "Unknown tool: #{name}"}
            end
        end

      next_name = ChatSurface.routed_tool(name, args) || name
      next_args = ChatSurface.canonical_args(name, args)
      decorated = add_next(next_name, next_args, result)
      Logger.debug("MCP tool response: #{name} - #{tool_response_summary(name, decorated)}")
      decorated
    end
  end

  defp coerce_agent_id(args) when is_map(args) do
    requested = Map.get(args, "agent_id")
    auth_identity = Map.get(args, "_auth_agent_id")

    cond do
      blank_agent_id?(requested) and usable_auth_agent_id?(auth_identity) ->
        Map.put(args, "agent_id", auth_identity)

      # The authenticated session owns identity; caller text cannot rename it.
      usable_auth_agent_id?(auth_identity) and is_binary(requested) and
        not blank_agent_id?(requested) and
          normalize_agent_id(requested) != normalize_agent_id(auth_identity) ->
        Map.put(args, "agent_id", auth_identity)

      blank_agent_id?(requested) ->
        Map.delete(args, "agent_id")

      true ->
        args
    end
  end

  @contextual_tools ~w(ask steward_ask query_memories query_specs skill_get generate_guidance_packet)

  defp bind_working_context(args, name) when name in @contextual_tools do
    identity = args["_auth_agent_id"] || args["agent_id"]

    args
    |> put_default("_auth_repo", Acs.MCP.ClientSession.resolve_working_repo(identity))
    |> put_default("scope_path", Acs.MCP.ClientSession.resolve_working_scope(identity))
  end

  defp bind_working_context(args, _name), do: args

  defp put_default(args, _key, value) when value in [nil, ""], do: args
  defp put_default(args, key, value), do: Map.put_new(args, key, value)

  defp blank_agent_id?(nil), do: true

  defp blank_agent_id?(id) when is_binary(id) do
    trimmed = String.trim(id)
    trimmed == "" or trimmed == "unknown"
  end

  defp blank_agent_id?(_), do: false

  defp usable_auth_agent_id?(id) when is_binary(id) do
    trimmed = String.trim(id)
    trimmed != "" and trimmed != "unknown"
  end

  defp usable_auth_agent_id?(_), do: false

  defp validate_agent_identity(args) do
    requested = Map.get(args, "agent_id")
    auth_identity = Map.get(args, "_auth_agent_id")
    auth_role = Map.get(args, "_auth_role")

    cond do
      is_nil(requested) or blank_agent_id?(requested) ->
        :ok

      auth_role == "admin" ->
        :ok

      not usable_auth_agent_id?(auth_identity) ->
        {:error, "Authenticated agent identity is required"}

      normalize_agent_id(requested) == normalize_agent_id(auth_identity) ->
        :ok

      true ->
        {:error,
         "agent_id '#{requested}' does not match authenticated identity '#{auth_identity}'"}
    end
  end

  defp normalize_agent_id(id) when is_binary(id), do: String.downcase(String.trim(id))

  @doc """
  Returns true if the given tool name is registered in the core dispatch.
  Used by ToolRegistry.authorize_tool as a fallback for tools not in YAML definitions.
  """
  def has_tool?(name) do
    Map.has_key?(@simple_dispatch, name) or Map.has_key?(dispatch_map(), name)
  end

  defp tool_response_summary(_name, {:ok, result}) when is_map(result) do
    keys = Map.keys(result) |> Enum.join(", ")
    "ok (keys: #{keys})"
  end

  defp tool_response_summary(_name, {:ok, result}), do: "ok: #{inspect(result)}"
  defp tool_response_summary(_name, {:error, reason}), do: "error: #{inspect(reason)}"
  defp tool_response_summary(_name, :ok), do: "ok"

  # ── _next system: injects next-step suggestions into every tool response ──

  defp add_next(name, args, {:ok, map}) when is_map(map) do
    {:ok, Map.put(map, :_next, next_steps(name, args, map))}
  end

  defp add_next(_name, _args, result), do: result

  defp get_started_next_steps(args, agent_id) do
    auth_id = Map.get(args, "_auth_agent_id")
    you = if usable_auth_agent_id?(auth_id), do: auth_id, else: agent_id

    case chat_audience?(args) do
      true ->
        ask_q = if usable_auth_agent_id?(you), do: you, else: "..."

        [
          %{
            tool: "ask",
            prompt:
              if usable_auth_agent_id?(you) do
                "Search org knowledge for connected user \"#{you}\". Include their name in content_query when fetching their memories. Omit agent_id; never invent a nickname."
              else
                "Search org knowledge. Omit agent_id (ACS fills it); never invent a nickname."
              end,
            params: %{content_query: ask_q}
          },
          %{
            tool: "skill_get",
            prompt: "Find procedures / playbooks",
            params: %{search: "..."}
          },
          %{
            tool: "create_work",
            prompt:
              if usable_auth_agent_id?(you) do
                "Optional: track multi-step work (omit agent_id or pass exactly \"#{you}\")"
              else
                "Optional: track multi-step work"
              end,
            params: %{title: "<describe work>", claim: true}
          }
        ]

      false ->
        [
          %{
            tool: "get_present_status",
            prompt: "Register yourself to get an agent_id",
            params: %{agent_id: ""}
          },
          %{
            tool: "create_work",
            prompt: "Create and self-claim a task to track your work",
            params: %{agent_id: agent_id, title: "<describe work>", claim: true}
          },
          %{
            tool: "list_tasks",
            prompt: "Find existing todo tasks to claim",
            params: %{status_filter: "todo"}
          },
          %{
            tool: "generate_guidance_packet",
            prompt: "Get detailed workflow instructions",
            params: %{scope_path: "agent_coordination_system"}
          },
          %{
            tool: "help",
            prompt: "See all available tools with descriptions",
            params: %{level: 1}
          }
        ]
    end
  end

  defp chat_audience?(args) do
    Acs.MCP.Audience.normalize(Map.get(args, "_auth_audience")) == :chat or
      Acs.MCP.Audience.from_args(args) == :chat
  end

  defp next_steps(tool_name, args, result) do
    agent_id = Map.get(args, "agent_id", "")
    task_id = Map.get(result, :task_id) || Map.get(args, "task_id", "")

    steps =
      case tool_name do
        "get_started" ->
          get_started_next_steps(args, agent_id)

        "create_work" ->
          if Map.get(result, :status) == "claimed" do
            file_paths = Map.get(args, "file_paths", [])
            guidance = Map.get(result, :guidance, %{})

            lock_step = fn fp ->
              %{
                tool: "lock_file",
                prompt: "Lock file to prevent concurrent edits",
                params: %{
                  agent_id: agent_id,
                  task_id: task_id,
                  file_path: fp,
                  repo: "<Repo from AGENTS_STEWARD.md>",
                  repo_confirmed: true
                }
              }
            end

            lock_steps =
              if file_paths != [],
                do: Enum.map(file_paths, lock_step),
                else: []

            relevant_skill_steps(guidance, Map.get(args, "title", "")) ++
              relevant_spec_steps(guidance) ++ lock_steps
          else
            [
              %{
                tool: "claim_work",
                prompt: "Claim the task to start working on it",
                params: %{agent_id: agent_id, task_id: task_id}
              },
              %{
                tool: "list_tasks",
                prompt: "Or list other todo tasks",
                params: %{status_filter: "todo"}
              }
            ]
          end

        "claim_work" ->
          guidance = Map.get(result, :guidance, %{})

          relevant_skill_steps(guidance, "") ++
            relevant_spec_steps(guidance) ++
            [
              %{
                tool: "lock_file",
                prompt: "Lock file to prevent concurrent edits",
                params: %{
                  agent_id: agent_id,
                  task_id: task_id,
                  file_path: "<file_path>",
                  repo: "<Repo from AGENTS_STEWARD.md>",
                  repo_confirmed: true
                }
              },
              %{
                tool: "generate_guidance_packet",
                prompt: "Get detailed guidance for the scope before starting",
                params: %{scope_path: "<scope_path>"}
              }
            ]

        "release_work" ->
          [
            %{
              tool: "skill_save",
              prompt:
                "Followed a step-by-step workflow with the user? Save it now before feedback",
              params: %{
                name: "<kebab-case-name>",
                content: "# Steps\n1. ...\n2. ...",
                description: "One-line summary",
                when_to_use: "When to load this skill",
                scope_paths: ["<scope_path>"],
                tags: ["workflow"]
              }
            },
            %{
              tool: "save_memory",
              prompt:
                "Save eternal truths (principles/invariants) discovered during this task — read memory_protocol first",
              params: %{
                kind: "learning",
                title: "...",
                content: "...",
                scope_path: "<scope_path>"
              },
              guidance: %{
                memory_protocol: Acs.Memory.Guidance.memory_protocol(args["_auth_audience"])
              }
            },
            %{
              tool: "specs_propose",
              prompt:
                "Save shareable output — module spec, project doc, marketing copy, or knowledge file",
              params: %{
                app: "<app>",
                path: "<path>",
                title: "...",
                document_type: "deliverable",
                content: "..."
              }
            },
            %{
              tool: "submit_task_feedback",
              prompt: "Last step — formally close the task after saving information",
              params: %{
                task_id: task_id,
                agent_id: agent_id,
                learned_for_agents: "...",
                guidance_useful: true
              }
            }
          ]

        "close_work" ->
          []

        "lock_file" ->
          [
            %{
              tool: "unlock_file",
              prompt: "Release file lock so others can edit",
              params: %{agent_id: agent_id, file_path: Map.get(args, "file_path", "")}
            }
          ]

        "unlock_file" ->
          [
            %{
              tool: "release_work",
              prompt: "All files done? Mark task complete",
              params: %{agent_id: agent_id, task_id: task_id}
            },
            %{
              tool: "lock_file",
              prompt: "Lock another file for this task",
              params: %{agent_id: agent_id, task_id: task_id, file_path: "<file_path>"}
            }
          ]

        "get_present_status" ->
          [
            %{
              tool: "list_tasks",
              prompt: "List todo tasks to find work items",
              params: %{status_filter: "todo"}
            },
            %{
              tool: "create_work",
              prompt: "Or create a new task for the current request",
              params: %{agent_id: agent_id, title: "...", claim: true}
            }
          ]

        "list_tasks" ->
          auth_id = Map.get(args, "_auth_agent_id")
          you = if usable_auth_agent_id?(auth_id), do: auth_id, else: agent_id

          my_todos =
            Map.get(result, :tasks, [])
            |> Enum.filter(fn t -> t[:status] == "todo" and t[:created_by_agent] == you end)

          if my_todos != [] do
            [
              %{
                tool: "claim_work",
                prompt: "Claim a todo task you created to start working",
                params: %{agent_id: agent_id, task_id: hd(my_todos)[:slug]}
              }
            ]
          else
            [
              %{
                tool: "create_work",
                prompt: "No todo tasks from you — create one for the current request",
                params: %{agent_id: agent_id, title: "...", claim: true}
              }
            ]
          end

        "get_locked_files" ->
          []

        "save_memory" ->
          cond do
            Map.get(result, :status) == "needs_scope_choice" ->
              [
                %{
                  tool: "save_memory",
                  prompt:
                    "Ask the user which visibility to use, then retry with the same fields plus visibility",
                  params:
                    Map.take(args, [
                      "kind",
                      "title",
                      "content",
                      "scope_path",
                      "about_type",
                      "about_name",
                      "about_email",
                      "about_person_email",
                      "about_person_name",
                      "tags",
                      "summary"
                    ])
                    |> Map.put("visibility", "<org|team|project|personal>")
                }
              ]

            Map.get(result, :status) == "needs_input" ->
              [
                %{
                  tool: "save_memory",
                  prompt:
                    "Ask the user the intake questions, then retry with fixes and intake_confirmed: true",
                  params:
                    Map.take(args, [
                      "kind",
                      "title",
                      "content",
                      "scope_path",
                      "about_type",
                      "about_name",
                      "about_email",
                      "visibility",
                      "tags",
                      "summary"
                    ])
                    |> Map.put("intake_confirmed", true)
                }
              ]

            Map.get(result, :suggested_sensitive) == true ->
              [
                %{
                  tool: "save_memory",
                  prompt:
                    "Ask if this should be personal; if yes, re-save with visibility: personal (or confidential: true)",
                  params: %{
                    kind: Map.get(args, "kind"),
                    title: Map.get(args, "title"),
                    content: Map.get(args, "content"),
                    scope_path: Map.get(args, "scope_path"),
                    visibility: "personal",
                    intake_confirmed: true
                  }
                },
                %{
                  tool: "query_memories",
                  prompt: "Verify the saved memory is findable by search",
                  params: %{
                    query: Map.get(args, "title", ""),
                    scope_path: Map.get(args, "scope_path", "")
                  }
                }
              ]

            true ->
              memory_save_next_steps(args, result)
          end

        "query_memories" ->
          if Map.get(result, :count, 0) == 0 do
            [
              %{
                tool: "save_memory",
                prompt:
                  "No results — document your knowledge so others find it (read memory_protocol first)",
                params: %{
                  kind: "learning",
                  title: "...",
                  content: "...",
                  scope_path: "<scope_path>"
                },
                guidance: %{
                  memory_protocol: Acs.Memory.Guidance.memory_protocol(args["_auth_audience"])
                }
              }
            ]
          else
            [
              %{
                tool: "submit_task_feedback",
                prompt:
                  "Results not quite right? Flag stale or noisy memories in feedback so Steward improves",
                params: %{
                  agent_id: agent_id,
                  info_needed: "Search for '<query>' returned poor results"
                }
              }
            ]
          end

        "set_memory_status" ->
          [
            %{
              tool: "query_memories",
              prompt: "Verify the updated memory appears correctly",
              params: %{scope_path: Map.get(args, "scope_path", "")}
            }
          ]

        "update_memory" ->
          [
            %{
              tool: "query_memories",
              prompt: "Verify the updated memory reflects the changes",
              params: %{scope_path: Map.get(args, "scope_path", "")}
            }
          ]

        "generate_guidance_packet" ->
          scope = Map.get(args, "scope_path", "")
          skills = Map.get(result, :relevant_skills, [])

          skill_steps =
            skills
            |> Enum.take(5)
            |> Enum.map(fn s ->
              name = s[:name] || s["name"]

              %{
                tool: "skill_get",
                prompt: "Load procedure body: #{name}",
                params: %{name: name}
              }
            end)

          scope_step =
            if scope != "" do
              [
                %{
                  tool: "skill_get",
                  prompt: "Browse all skills available for this scope",
                  params: %{scope_path: scope}
                }
              ]
            else
              [
                %{
                  tool: "skill_get",
                  prompt: "Browse full skill catalog — see what's available and when to use each",
                  params: %{}
                }
              ]
            end

          skill_steps ++ scope_step

        "list_error_traces" ->
          if Map.get(result, :total, 0) > 0 do
            trace = Map.get(result, :traces, []) |> List.first()

            [
              %{
                tool: "ack_error_trace",
                prompt: "Claim an error to investigate",
                params: %{trace_id: if(trace, do: trace[:id], else: "<trace_id>")}
              },
              %{
                tool: "create_task_from_error_trace",
                prompt: "Turn this error into a fix task",
                params: %{trace_id: if(trace, do: trace[:id], else: "<trace_id>")}
              }
            ]
          else
            [
              %{
                tool: "get_logs",
                prompt: "No error traces found — check logs directly for clues",
                params: %{level: "error", limit: 50}
              }
            ]
          end

        "ack_error_trace" ->
          [
            %{
              tool: "resolve_error_trace",
              prompt: "Mark as resolved once the root cause is fixed",
              params: %{trace_id: Map.get(args, "trace_id", "")}
            }
          ]

        "resolve_error_trace" ->
          []

        "create_task_from_error_trace" ->
          [
            %{
              tool: "claim_work",
              prompt: "Claim the error-fix task to start investigating",
              params: %{agent_id: agent_id, task_id: Map.get(result, :task_id, "")}
            }
          ]

        "submit_task_feedback" ->
          [
            %{
              tool: "list_tasks",
              prompt: "Check if more work is waiting",
              params: %{status_filter: "todo"}
            },
            %{
              tool: "create_work",
              prompt: "Or create the next task",
              params: %{agent_id: agent_id, title: "...", claim: true}
            }
          ]

        "help" ->
          []

        "query" ->
          []

        "config_lookup" ->
          []

        "connection_diagnostic" ->
          [
            %{
              tool: "get_logs",
              prompt: "Issues found? Check error logs for details",
              params: %{level: "error", limit: 50}
            }
          ]

        "memory_health_check" ->
          [
            %{
              tool: "get_logs",
              prompt: "Memory issues found? Check error logs",
              params: %{level: "error", limit: 50}
            }
          ]

        "specs_get" ->
          [
            %{
              tool: "specs_propose",
              prompt: "Missing or outdated? Propose a module spec or shareable document",
              params: %{
                app: Map.get(args, "app", ""),
                path: Map.get(args, "path", ""),
                title: "...",
                document_type: "spec",
                content: "..."
              }
            },
            %{
              tool: "specs_approve",
              prompt: "Spec looks correct? Approve it",
              params: %{
                app: Map.get(args, "app", ""),
                path: Map.get(args, "path", ""),
                reviewer: agent_id
              }
            }
          ]

        "query_specs" ->
          [
            %{
              tool: "specs_propose",
              prompt: "Save a module spec or shareable document (project, marketing, knowledge)",
              params: %{
                app: "<app>",
                path: "<path>",
                title: "...",
                document_type: "deliverable",
                content: "..."
              }
            },
            %{
              tool: "submit_task_feedback",
              prompt:
                "Found outdated or missing specs? Flag them in feedback to improve the knowledge base",
              params: %{
                agent_id: agent_id,
                info_needed: "Spec search results were incomplete or outdated"
              }
            }
          ]

        "ask" ->
          result_count = Map.get(result, :total, 0)
          content_query = Map.get(args, "content_query", "")

          query_prompt =
            if is_binary(content_query) and content_query != "" do
              "Search for '#{content_query}' returned poor results"
            else
              "Search results were incomplete or outdated"
            end

          if result_count == 0 do
            [
              %{
                tool: "save_memory",
                prompt: "No results — document your knowledge so others find it",
                params: %{
                  kind: "learning",
                  title: "...",
                  content: "...",
                  scope_path: "<scope_path>"
                }
              },
              %{
                tool: "submit_task_feedback",
                prompt:
                  "Couldn't find what you needed? Flag the gap in feedback so Steward improves",
                params: %{agent_id: agent_id, info_needed: query_prompt}
              }
            ]
          else
            [
              %{
                tool: "specs_get",
                prompt:
                  "Document listed without body? Load it before acting (chat: steward_ask action=document)",
                params: %{app: "<app>", path: "<path>"}
              },
              %{
                tool: "skill_get",
                prompt:
                  "If a listed skill fits the task, you MUST fetch and follow it before acting (chat: steward_ask action=skill)",
                params: %{name: "<skill-name>"}
              },
              %{
                tool: "submit_task_feedback",
                prompt:
                  "Results not quite what you expected? Flag stale or wrong knowledge in feedback",
                params: %{agent_id: agent_id, info_needed: query_prompt}
              }
            ]
          end

        name when name in ["specs_propose", "documents_propose"] ->
          [
            %{
              tool: "specs_approve",
              prompt: "Proposed entry ready? Approve to make it official",
              params: %{
                app: Map.get(args, "app", ""),
                path: Map.get(args, "path", ""),
                reviewer: agent_id
              }
            }
          ]

        "specs_approve" ->
          []

        "specs_reject" ->
          []

        "skill_get" ->
          catalog = Map.get(result, :catalog, [])
          skills = Map.get(result, :skills, [])
          related = Map.get(result, :related, [])
          scope_path = Map.get(args, "scope_path", "")
          by_name? = is_binary(args["name"]) and args["name"] != ""

          read_steps =
            cond do
              # Already loaded the body by name — follow it; don't re-fetch.
              by_name? ->
                []

              match?([_ | _], skills) ->
                skills
                |> Enum.take(5)
                |> Enum.map(fn s ->
                  n = skill_name(s)

                  %{
                    tool: "skill_get",
                    prompt: "Load procedure body: #{n}",
                    params: %{name: n}
                  }
                end)

              true ->
                []
            end

          related_steps =
            related
            |> Enum.take(3)
            |> Enum.map(fn s ->
              n = skill_name(s)
              tagline = s["when_to_use"] || s[:when_to_use] || s["description"] || s[:description]

              %{
                tool: "skill_get",
                prompt: "Related skill: #{n} — #{tagline}",
                params: %{name: n}
              }
            end)

          catalog_steps =
            if skills == [] and catalog != [] do
              catalog
              |> Enum.take(5)
              |> Enum.map(fn s ->
                n = skill_name(s)

                tagline =
                  s["when_to_use"] || s[:when_to_use] || s["description"] || s[:description]

                %{
                  tool: "skill_get",
                  prompt: "Available: #{n} — #{tagline}",
                  params: %{name: n}
                }
              end)
            else
              []
            end

          scope_browse =
            if scope_path != "" do
              []
            else
              [
                %{
                  tool: "skill_get",
                  prompt: "Entering a scope? Pass scope_path to see skills for that area",
                  params: %{scope_path: "<scope_path>"}
                }
              ]
            end

          read_steps ++
            related_steps ++
            catalog_steps ++
            scope_browse ++
            [
              %{
                tool: "skill_save",
                prompt: "Missing a workflow? Create a skill so others reuse it",
                params: %{name: "<name>", content: "...", scope_paths: ["<scope_path>"]}
              },
              %{
                tool: "skill_audit_status",
                prompt: "Audit all skills for quality gaps",
                params: %{}
              }
            ]

        "skill_save" ->
          [
            %{
              tool: "skill_audit_status",
              prompt: "Verify new skill meets quality standards",
              params: %{}
            }
          ]

        "skill_audit_status" ->
          [
            %{
              tool: "skill_save",
              prompt: "Fix low-scoring skills to improve quality",
              params: %{name: "<name>", content: "..."}
            }
          ]

        "app_list" ->
          [
            %{
              tool: "app_configure",
              prompt: "Need a new external service? Configure an app",
              params: %{name: "<app_name>"}
            }
          ]

        "app_configure" ->
          [%{tool: "app_list", prompt: "Verify the app was configured correctly", params: %{}}]

        "app_remove" ->
          [%{tool: "app_list", prompt: "Verify the app was removed", params: %{}}]

        "list_plugins" ->
          []

        "list_orgs" ->
          []

        "time" ->
          []

        _ ->
          []
      end

    maybe_chat_next_steps(steps, args)
  end

  defp memory_save_next_steps(args, result) do
    verification = %{
      tool: "query_memories",
      prompt: "Verify the saved memory is findable by search",
      params: %{
        query: Map.get(args, "title", ""),
        scope_path: Map.get(args, "scope_path", "")
      }
    }

    # Chat's consolidated memory_status schema only exposes stale/deprecated.
    # Approval is an admin-only coding operation, so never suggest the invalid
    # approved transition to chat clients.
    if chat_audience?(args) do
      [verification]
    else
      [
        verification,
        %{
          tool: "set_memory_status",
          prompt: "No conflicts? Approve to make visible to all agents",
          params: %{memory_id: Map.get(result, :id, ""), status: "approved"}
        }
      ]
    end
  end

  # Chat surface uses documents_propose; rewrite / filter `_next` so chat never sees specs_*.
  # Attach memory_protocol to any save_memory suggestion so agents see consent rules before saving.
  defp maybe_chat_next_steps(steps, args) do
    steps = Enum.map(steps, &maybe_attach_memory_guidance(&1, args))

    case Acs.MCP.Audience.normalize(Map.get(args, "_auth_audience")) do
      :chat ->
        steps
        |> Enum.map(&rewrite_chat_next_tool/1)
        |> Enum.filter(fn step -> Acs.MCP.CoreToolRoles.chat_tool?(step.tool) end)

      _ ->
        steps
    end
  end

  defp maybe_attach_memory_guidance(%{tool: "save_memory"} = step, args) do
    case step do
      %{guidance: %{memory_protocol: _}} ->
        step

      _ ->
        Map.put(step, :guidance, %{
          memory_protocol: Acs.Memory.Guidance.memory_protocol(args["_auth_audience"])
        })
    end
  end

  defp maybe_attach_memory_guidance(step, _args), do: step

  defp rewrite_chat_next_tool(%{tool: "specs_propose"} = step) do
    step
    |> Map.put(:tool, "documents_propose")
    |> ChatSurface.consolidate_step()
  end

  defp rewrite_chat_next_tool(step), do: ChatSurface.consolidate_step(step)

  defp relevant_skill_steps(guidance, fallback_title) do
    skills = Map.get(guidance, :relevant_skills) || []

    if skills == [] and fallback_title != "" do
      [
        %{
          tool: "skill_get",
          prompt: "Search for workflow guides relevant to this task",
          params: %{search: fallback_title}
        }
      ]
    else
      Enum.map(skills, fn skill ->
        name = skill[:name] || skill["name"]

        %{
          tool: "skill_get",
          prompt: "Load procedure body: #{name}",
          params: %{name: name}
        }
      end)
    end
  end

  defp relevant_spec_steps(guidance) do
    specs = Map.get(guidance, :relevant_specs) || []

    read_steps =
      specs
      |> Enum.reject(fn s -> (s[:status] || s["status"]) == "missing" end)
      |> Enum.map(fn spec ->
        app = spec[:app] || spec["app"]
        path = spec[:path] || spec["path"]

        %{
          tool: "specs_get",
          prompt: "Read spec for module you'll work on: #{app}/#{path}",
          params: %{app: app, path: path}
        }
      end)

    propose_steps =
      specs
      |> Enum.filter(fn s -> (s[:status] || s["status"]) == "missing" end)
      |> Enum.map(fn spec ->
        app = spec[:app] || spec["app"]
        path = spec[:path] || spec["path"]

        %{
          tool: "specs_propose",
          prompt: "Module #{path} has no spec — document it before or after implementing",
          params: %{app: app, path: path, title: path, purpose: "..."}
        }
      end)

    read_steps ++ propose_steps
  end

  defp propose_entry_properties do
    %{
      "app" => %{
        "type" => "string",
        "description" => "App or project name (e.g. steward_acs, acme-corp)"
      },
      "path" => %{
        "type" => "string",
        "description" =>
          "Entry path — module path (acs/memory/guidance) or document path (documents/marketing/campaign)"
      },
      "title" => %{"type" => "string", "description" => "Human-readable title"},
      "document_type" => %{
        "type" => "string",
        "description" =>
          "Kind of entry: \"spec\" for code module docs; knowledge|project|marketing|deliverable|policy|process|guideline|reference for non-code documents. Omit when using structured module-spec fields (purpose/invariants/…).",
        "enum" => [
          "spec",
          "knowledge",
          "project",
          "marketing",
          "deliverable",
          "policy",
          "process",
          "guideline",
          "reference"
        ]
      },
      "purpose" => %{
        "type" => "string",
        "description" => "For module specs: why this module exists"
      },
      "invariants" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Truths that must always hold"
      },
      "workflows" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Expected call sequences / protocols"
      },
      "failure_modes" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Known failure scenarios and handling"
      },
      "constraints" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Non-goals, tradeoffs, limits"
      },
      "tags" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Search tags"
      },
      "content" => %{
        "type" => "string",
        "description" =>
          "Full markdown body — required for documents (marketing copy, project docs, long knowledge). Embed images as ![alt](url)."
      },
      "source" => %{
        "type" => "string",
        "description" => "Origin: file path, URL, or asset folder for attachments"
      },
      "project" => %{"type" => "string", "description" => "Project scope for ABAC filtering"}
    }
  end

  defp specs_propose_description do
    base =
      "Create or update a **spec** (code) or **document** (non-code); status → proposed. " <>
        "SPECS (code): purpose, invariants, workflows, failure_modes — or document_type \"spec\" + content. " <>
        "DOCUMENTS (outside code): document_type + title + content for policy, marketing, project briefs, knowledge files. " <>
        specs_documents_storage_note() <>
        "USE WHEN: after code changes (spec) or when the user produced output to keep (document). " <>
        "When code and a module spec disagree, ask the user which to update."

    instructions = Acs.Prompts.instructions("specs")
    if instructions != "", do: instructions <> "\n\n" <> base, else: base
  end

  defp documents_propose_description do
    "Save or update a long **document** in Steward (policy, brief, marketing, knowledge, process). " <>
      "Pass document_type + title + content. Prefer path under documents/<type>/<slug>. " <>
      specs_documents_storage_note() <>
      "Chat-facing name for the document store (same backend as coding specs_propose). " <>
      "USE WHEN: user pastes/uploads a doc to keep, or after producing long shareable text. " <>
      "NOT for short eternal truths (save_memory) or step-by-step how-tos (skill_save)."
  end

  defp specs_documents_storage_note do
    if Acs.Org.multi_tenant?() do
      "Specs and documents are stored in the database; no filesystem directory setup is needed. Use query_specs to discover valid existing app/path options. "
    else
      "Specs and documents are stored as local files; missing app/path directories are created automatically, so no manual directory setup is needed. If a target cannot be used, call query_specs to discover valid existing app/path options. "
    end
  end

  defp skill_save_description do
    storage =
      if Acs.Org.multi_tenant?() do
        "Skills are stored as database records; no filesystem directory setup is needed. "
      else
        "Skills are stored as local Markdown files; the skills directory is created automatically when missing, so no manual directory setup is needed. If storage is unavailable, the error identifies the directory to use. "
      end

    base =
      "Create or update a skill — a reusable step-by-step workflow for other agents. " <>
        "USE WHEN: you followed a repeatable multi-step procedure worth re-running " <>
        "(deploy, secrets, install, MCP sequence, debug playbook, ingest, review, support) — not a one-off patch note. " <>
        "NOT for one-line truths (use save_memory) or long shareable docs (use specs_propose/documents_propose). " <>
        "REQUIRES: name, description (one sentence, distinct from name), tags, scope_paths, " <>
        storage <>
        "Provide markdown content with numbered " <>
        "steps, prerequisites, verification, and failure recovery. " <>
        "Intake is single-pass and defaults to allow; only returns needs_input for secrets, unusable content, or no followable steps. " <>
        "Retry once with fixes (or intake_confirmed: true). Lands as status: proposed for governance."

    instructions = Acs.Prompts.instructions("skills")
    if instructions != "", do: instructions <> "\n\n" <> base, else: base
  end

  defp skill_name(skill) when is_map(skill) do
    skill["name"] || skill[:name]
  end

  defp skill_name(_), do: nil
end
