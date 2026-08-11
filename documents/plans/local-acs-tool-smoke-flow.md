# Plan: Local ACS tool smoke flow with CI push hook

## Decision summary

Add a deterministic, no-LLM tool smoke that exercises **every** MCP tool over the
wire against a freshly-booted local ACS instance, and run it as a CI gate on push
to `dev` so future tool bugs are caught before they reach the remote store.

- **Deterministic HTTP smoke** (`scripts/smoke-mcp-tools.sh`) — drives the real
  streamable MCP endpoint (`POST /mcp/v1/messages`, `x-api-key` auth): `initialize`,
  `notifications/initialized`, `tools/list`, then `tools/call` for each advertised
  tool. No LLM involved, so results are reproducible.
- **Local runner** (`scripts/local-tool-smoke.sh`) — boots a disposable local ACS
  on a fresh SQLite DB (temp dir), waits for `/mcp/health`, runs the smoke, tears
  down. This is the single flow used both locally and in CI.
- **CI push hook** — a new `tool-smoke` job in `.github/workflows/ci.yml` runs on
  push to `dev` (existing `on` triggers unchanged), reusing the same runner.
- **BUG FOUND + FIXED while building the smoke**: `revoke_developer_key` crashed
  with a swallowed "Tool execution failed" when two rows shared a `developer_name`
  (`Repo.get_by` raising "expected at most one result but got 2"). `revoke_by_name/2`
  in `lib/acs/developers/developers.ex` was rewritten to revoke all active rows
  matching name+org. Regression tests added in `test/acs/developers_test.exs`.

## Why

- The smoke exists to catch exactly the class of bug above: `ToolRegistry.safe_execute`
  (`lib/acs/mcp/tool_registry.ex:849-859`) swallows every handler crash into the
  generic text `Tool execution failed`, so a broken tool shows up only as a confusing
  failure at runtime. No test previously booted the app and exercised tools over the
  wire — unit tests call handlers in isolation.
- Local docker instance on `:4001` had a **stale named volume** (`acs_data:/app/priv`)
  whose DB predates the 2026-08-08/08-10 migrations (`repo`, `audience` columns), so it
  was untrustworthy for validation. The disposable flow sidesteps this entirely: fresh
  DB + `mix ecto.migrate` every run.

## Changes

1. **NEW `scripts/smoke-mcp-tools.sh`** — deterministic HTTP MCP tool smoke.
   - Env: `PUBLIC_URL` (default `http://127.0.0.1:4001`), `SMOKE_API_KEY` (falls back
     to `MCP_API_KEY`, required), `SKIP_TOOLS` (comma), `EXPECTED_TOOLS` (exact-match).
   - Health gate on `/mcp/health`; `initialize`/`notifications/initialized`/`tools/list`;
     exact set-match against `EXPECTED_TOOLS` (fails if a new tool appears without an entry).
   - **Setup phase** creates real state in dependency order and captures returned IDs:
     `create_org` → `create_work` → `claim_work` → `lock_file` → `get_locked_files` →
     `unlock_file` → `release_work` → `submit_task_feedback` → second `create_work` →
     `claim_work` → `close_work` → `list_tasks` → `save_memory` → `set_memory_status` →
     `query_memories` → `specs_propose`/`get`/`approve`/`reject` → `documents_propose` →
     `query_specs` → `skill_save`/`get`/`audit_status` → `generate_developer_key` →
     `list_developer_keys` → `revoke_developer_key` → `upsert_authority_level` →
     `list_authority_levels` → `delete_authority_level` → `app_configure`/`list`/`remove`.
   - `EXPECT_ERROR` set for intentional negative tests (nonexistent trace IDs, OAuth-only
     `set_member_authority_level` under an API key, nonexistent user task): a clean
     structured `isError` there counts as PASS.
   - **Hard-fail rule**: any result whose text contains `Tool execution failed` is a
     swallowed crash (always a bug) → FAIL regardless of `EXPECT_ERROR`.
   - Summary line `== SUMMARY: total= ok= fail= skipped= ==`; exit 1 on any failure.
2. **NEW `scripts/local-tool-smoke.sh`** — boots a disposable local ACS (fresh SQLite
   DB in a temp dir via `DATABASE_PATH`, `mix ecto.migrate`, `mix phx.server` on
   `PORT`), polls `/mcp/health`, runs the smoke, kills the server and removes the DB
   (trap; `KEEP=1` to preserve). Env: `PORT` (default 4101), `MCP_API_KEY`,
   `SMOKE_API_KEY` (defaults to `MCP_API_KEY`), `DATABASE_DIR`, `KEEP`.
3. **MODIFIED `.github/workflows/ci.yml`** — new `tool-smoke` job (after `lint`):
   `setup-beam` otp 26.2.5 / elixir 1.17.3, deps cache (same key), `libsqlite3-dev`,
   `mix deps.get`, `mix compile`, then `./scripts/local-tool-smoke.sh` with
   `MCP_API_KEY=ci_tool_smoke_key` `PORT=4101`. Job fails on nonzero exit.
4. **FIXED `lib/acs/developers/developers.ex`** — `revoke_by_name/2` revokes all active
   rows for name+org instead of crashing via `Repo.get_by`.
5. **MODIFIED `test/acs/developers_test.exs`** — added `revoke_by_name/2` describe with
   4 tests (basic revoke, duplicate-name regression, org isolation, unknown name).

## Acceptance tests

- `MCP_API_KEY=<local key> PORT=4101 ./scripts/local-tool-smoke.sh` → `PASS`, all tools OK.
- `mix test test/acs/developers_test.exs` → 17 tests, 0 failures.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`
  → all clean.
- `.github/workflows/ci.yml` parses; jobs = `test`, `release`, `lint`, `tool-smoke`.

## Out of scope

- LLM-driven opencode smoke (`opencode run --pure --model ...` driving `acs_*` tools) —
  validated as feasible during research but deliberately NOT the CI gate (nondeterministic,
  needs an LLM provider key in Actions). Can be added as an optional local flow later.
- Fixing the stale local docker volume `acs_data:/app/priv` on `:4001` (the disposable
  flow makes it unnecessary).

## Verification notes / known side effects

- The smoke's `skill_save` writes smoke skill files into `priv/skills/orgs/default/` on
  the host checkout; clean them up after a local run (they are untracked, e.g.
  `smoke-skill-tool-smoke-*`). CI runs in a clean checkout so this is only a local concern.
- Run the smoke against a **fresh** disposable DB. Reusing a long-lived DB across runs
  can trip the semantic memory dedup guard (cosine similarity ≥ 0.92) on `save_memory`.
- SQLite single-writer: the local runner owns its own temp DB and port, so it never
  conflicts with a running `docker compose up -d` on `:4001`.
