# Steward ACS — Agent Instructions

## ⚠️ First — Find Your Agent ID

Your `agent_id` is your identity across all tool calls. It persists across sessions.

1. **Register** — `steward_get_present_status(agent_id: "")` → auto-registers and returns your `assigned_agent_id` (e.g. `"Yara"`)
2. **Use that name everywhere** — substitute your assigned name for `<AGENT>` in all examples below

> **Never use the literal string `YourName`.** Your assigned `agent_id` is what `get_present_status(agent_id: "")` returns.

## 📦 Your Repository

You work in the repo declared on this line — keep it in sync with this file:

`Repo: steward_acs`

If `get_started()` returns no repo (or this line is missing), **ask the human to add `Repo: <name>` here** and restart. Never invent a repo name.

- **Saves** are tagged `repo: <name>`; retrieval blends your repo first, then org-wide knowledge, then other repos (labeled `repo:`).
- **Chat** agents are project/domain-scoped; coding agents are repo-scoped.

Before the first file lock, identify the checkout you are actually editing:
1. Run `git rev-parse --show-toplevel`.
2. Read `<repo-root>/AGENTS_STEWARD.md` and use its `Repo: <name>` value.
3. Confirm with the human or coordinating agent that this is the intended repository, then pass that value as `repo` with `repo_confirmed: true` on the first `lock_file` call.

The first successful lock establishes the task and session repository so ACS knows where the agent is working. Later locks from a different repo fail with `repo_mismatch`. If the declaration is missing, ask the human; never use the Steward server checkout or invent a repository.

## ⚠️ Before Work — Always Create a Task

Before reading anything else or responding to the user:

1. **Create a task** — `steward_create_work(agent_id: "<AGENT>", title: "...")` or `steward_claim_work(agent_id: "<AGENT>", task_id: "<id>")`
2. **Wait for it to complete** before doing any other work
3. Only then proceed with the user's request

Do not skip this step. Do not assume you can create the task later. Even if the user's request looks like a question, create a task first. The answer to "why didn't you create a task?" is always: you should have, first thing.

## ⚠️ After Work — Always Complete + Feedback

When the work is done:

1. **Save information** — pick a primary store if any trigger applies (else skip saving):
   - **Worked out a plan with the user** (implementation, improvement, migration, remediation) → `specs_propose` a **document** under `documents/plans/<slug>` so the plan persists
   - **Changed a code module's intent/contract** → `specs_propose` with purpose/invariants/workflows (code module spec). After changing `/lib/` code, run `query_specs(undocumented: true)` and `specs_get` the touched module; propose or update the spec before `release_work`.
   - **Followed a repeatable how-to** (numbered steps) → `skill_save`
   - **Produced a long non-code document** → `specs_propose` with `document_type` + `title` + `content`
   - **Discovered a short eternal truth** → `save_memory`
   - **Otherwise** → save nothing; do not force a save
2. **Release the task** — `steward_release_work(task_id: "<id>", agent_id: "<AGENT>")`
3. **Submit feedback** — `steward_submit_task_feedback(...)` last, to formally close the task
4. Only then tell the user you're done

Do not skip this. Releasing frees the lock for other agents. Feedback generates memories so the next agent benefits from what you learned.

### Feedback categories

Feedback is a **system review** — not a learning. Use the right fields:

| Field | When to use |
|-------|-------------|
| `learned_for_agents` | New findings, workarounds, reusable insights from this task |
| `had_issues` | Bugs, confusing guidance, broken workflows |
| `improvements` | Feature requests or suggestions for Steward |
| `info_needed` | Missing docs, poor search results, hard-to-find info |

### Standalone feedback (no task_id)

Chat agents can submit feedback **without** a task_id for simple Q&A interactions:

`steward_submit_task_feedback(agent_id: "<AGENT>", learned_for_agents: "...", had_issues: "The search didn't find relevant memories")`

## Two Environments

| Server | Key | URL | Use |
|--------|-----|-----|-----|
| **Local** | `acs` | `http://localhost:4001/mcp/v1/messages` | Dev — coding, dev memories, daily coordination |
| **Production** | `acs_prod` | `https://prod.stewardacs.xyz/mcp/v1/messages` | Prod — live instance, production data, remote debugging |

**Note:** Both expose the same tools. To target a specific server, disable the other in `~/.config/opencode/opencode.json`.

## Getting Started (after registering)

1. **Get instructions** — `steward_get_started()` (audience-aware: coding vs chat) or `steward_generate_guidance_packet(scope_path: "...")` for domain guidance
2. **Or claim a task** — `steward_claim_work(agent_id: "<AGENT>", task_id: "<id>")` returns a guidance packet tailored to your task

## Scopes — org knowledge structure

`scope_path` is a hierarchical label for **business domains or code paths**:

- Business: `acme/sales/pricing`, `acme/support/refunds`, `acme/policy/privacy`
- Code: `lib/acs/memory`, `agent_coordination_system/tools`

Store: **memories** = short eternal truths · **specs** = code module docs · **documents** = long non-code artifacts via `specs_propose(document_type, title, content)` (including plans worked out with the user, under `documents/plans/<slug>`) · **skills** = step-by-step procedures.
Always attach a clear `scope_path` when saving so the next agent can retrieve by domain.

## 👤 Human-Readable Task IDs (Slugs)

Tasks get a **slug** (kebab-case from title, e.g. `"fix-login-bug"`) generated automatically. Use slugs everywhere — never UUIDs:

- `steward_claim_work(agent_id: "<AGENT>", task_id: "fix-login-bug")`
- `steward_release_work(agent_id: "<AGENT>", task_id: "fix-login-bug")`
- `steward_lock_file(agent_id: "<AGENT>", task_id: "fix-login-bug", file_path: "...")`

All responses return `slug` alongside `task_id`.

## Core Rule

**You create it, you claim it.** Always self-claim tasks unless directed otherwise.

## Tools

Call any tool by its `steward_` name. For a full listing with descriptions: `steward_help()`.
