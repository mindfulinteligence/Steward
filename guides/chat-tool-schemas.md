# Chat MCP tool schemas

The `/mcp/chat/sse` audience advertises exactly three always-loaded tools. The `/mcp/coding/sse` audience keeps the existing fine-grained tools unchanged.

## `steward_ask`

A discriminated union on `action`:

- Empty object or `action: start` → the current chat `get_started` packet.
- `action: search` → current `ask`; accepts `content_query` and existing ask filters.
- `action: skill` → current `skill_get`; accepts `search`, `name`, `tag`, `scope_path`, and `mode`.
- `action: person_status` → current `get_person_status`.
- `action: present_status` → current `get_present_status`.
- `action: list_tasks` → current `list_tasks`; accepts `kind`, `status_filter`, and `for_user`.

When `action` is omitted on a non-empty object, routing defaults to `search`. Empty calls intentionally bootstrap rather than run a blank search.

## `steward_write`

A required discriminated union on `kind`:

- `memory` → current `save_memory` fields and intake behavior.
- `document` → current `documents_propose` fields; `app` and `path` remain required.
- `skill` → current `skill_save`; `name` and `content` remain required.
- `memory_status` → current `set_memory_status`; chat remains restricted to `stale` and `deprecated`.
- `memory_update` → current `update_memory`; resolves the target by `memory_id` (or by `title` + `scope_path`), replaces only the provided fields (`title`, `content`, `summary`, `importance`, `tags`, `triggers`, `failure_modes`, `related_memories`), and keeps provenance via the ledger. No create fallback — unknown memories error; use `memory` to create.
- `person_status` → current `set_person_status`; `status` remains required.
- `feedback` → current `submit_task_feedback`; authenticated chat identity supplies the agent.

`save_memory` already uses `kind` for its memory classification, so the façade calls that field `memory_kind` (for example `decision` or `invariant`) and maps it back to the existing handler argument. This is only a name disambiguation; intake semantics are unchanged.

A `needs_scope_choice` response includes `allowed_teams` from the authenticated context. Team visibility must use one of those names and pass `team` on retry.

## `steward_work`

A required discriminated union on `action`:

- `create` → current `create_work`; `title` remains required. `kind: user` uses the existing reminder fields.
- `claim` → current `claim_work`; `task_id` remains required.
- `release` → current `release_work`; `task_id` remains required.
- `resolve_reminder` → current `resolve_user_task`; `task_id` and `outcome` remain required.

## Compatibility window

For one release, chat `tools/call` accepts the old fine-grained chat names and translates them internally to these routes. They are not advertised by chat `tools/list`. Coding calls and schemas retain the old names and do not advertise the three chat-only façade tools. Remove the protocol alias table after the cutover window.
