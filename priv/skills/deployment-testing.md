---
name: "deployment-testing"
description: Set up, extend, and update ACS CI + local system + post-deploy smoke testing.
when_to_use: Before changing deploy smoke, CI, chat_surface, or verifying a feature against a running ACS; when onboarding agents to how the system is tested on dev and after cutover
tags: ["deployment", "testing", "ci", "smoke", "chat-surface"]
scope_paths: ["guides/deployment-testing", "guides/deployment", ".github/workflows", "scripts", "lib/acs/mcp/core_tool_roles.ex"]
---

# Deployment testing

## When to use

- First time on this repo: confirm testing infra is set up
- Adding a feature that needs live MCP/API or a deploy gate
- Changing CI, `deploy.sh` smoke, `smoke-chat-tools.sh`, or `chat_surface/0`
- After push to `dev` / cutover: know what green means

Human index: [`guides/deployment-testing.md`](../../guides/deployment-testing.md). Ship ops: [`guides/deployment.md`](../../guides/deployment.md).

## Layers (do not confuse)

1. **CI** — `.github/workflows/ci.yml` on `dev` (+ PRs to `prod`): runs the complete `scripts/repo-readiness.sh` contract. Does not run multitenant compose.
2. **CI gate on Deploy** — same CI via `workflow_call` before `build-push` / cutover on `prod`. Failures block ship automatically (`skip_ci` is break-glass only).
3. **Local system** — `mix phx.server` or `docker compose up -d` on :4001 for live verification.
4. **Post-deploy smoke** — `deploy.sh` after cutover: `/mcp/health`, optional fixed DCR, optional chat `tools/list` vs live `CoreToolRoles.chat_surface/0`.

## Setup (once) — do this if missing

### Local

1. `cp .env.example .env` and fill Auth0 web + `MCP_API_KEY` (local secrets only).
2. `docker compose up -d` or `mix phx.server`.
3. `curl -fsS http://127.0.0.1:4001/mcp/health` → success.
4. If Cursor ACS MCP discovery fails but health works: use `/mcp/v1/messages` + `x-api-key` (do not assume Phoenix is down).

### CI

1. No special secrets for default CI.
2. Before pushing, run `./scripts/repo-readiness.sh` locally.
3. After `git push -u origin HEAD` on `dev`: `gh run list --branch dev --workflow=CI` and watch until green.

### Prod smoke secrets (GitHub Environment **prod**)

1. Set `PUBLIC_URL` (required for public smoke).
2. Create a collaborator+ developer API key in prod → store as `SMOKE_API_KEY` (recommended). Without it, chat inventory smoke is skipped.
3. Confirm Deploy workflow cutover still runs health (+ DCR when configured).
4. Optional local helper: `./scripts/check-bluegreen.sh`.

## Verify a feature on `dev`

1. Confirm branch is `dev` (do not switch branches yourself).
2. `mix test` on touched tests.
3. Run `./scripts/repo-readiness.sh` before pushing.
4. If the bug only shows with a live process: start local system, hit health, exercise MCP/UI.
5. Push `dev` → CI green.
6. Promote to `prod` only when the user asks to deploy.

## New features — which layer to extend

### Chat MCP tool

1. Implement + ExUnit.
2. Add to `chat_surface/0` in `lib/acs/mcp/core_tool_roles.ex` if chat connectors should see it.
3. Sync `priv/prompts/chat_system_prompt_body.md` / Always Active & Opt In wrappers / guidance.
4. Update `test/acs/mcp/core_tool_roles_test.exs`.
5. Do **not** hardcode the tool list in `smoke-chat-tools.sh` — deploy evals live `chat_surface/0`. Mismatch fails smoke when `SMOKE_API_KEY` is set.

### Coding-only MCP tool

1. ExUnit + role tests; leave off `chat_surface`.
2. Smoke already asserts coding SSE returns at least one tool beyond chat.

### New must-pass-on-cutover check

1. Add to `scripts/deploy.sh` smoke block or `scripts/smoke-chat-tools.sh`.
2. Document any new secret in `guides/deployment-testing.md` + `guides/deployment.md`.
3. Prefer ExUnit for logic; smoke only for live-host invariants.

### New CI dependency / OTP-Elixir pin / Postgres

1. Edit `.github/workflows/ci.yml` install or service blocks.
2. Keep local and CI validation in sync through `scripts/repo-readiness.sh`.
3. If the release image needs it: `Dockerfile` + confirm the readiness job.
4. Note agent-facing setup in `guides/deployment-testing.md` if locals need the same.

### Blue/green math

1. Change `scripts/lib/acs_bluegreen.sh`.
2. Keep `./scripts/check-bluegreen.sh` passing.

## Update the infra

| Touch | Also update |
|-------|-------------|
| `ci.yml` / `scripts/repo-readiness.sh` | `guides/deployment-testing.md` and this skill if steps change |
| `deploy.yml` / cutover | `guides/deployment.md`, `priv/skills/deployment.md` |
| `deploy.sh` / `smoke-chat-tools.sh` | this skill + deployment-testing guide |
| `core_tool_roles.ex` | tests + chat prompt |

Local chat smoke against a running build:

```bash
EXPECTED_CHAT_TOOLS=$(mix run -e 'IO.puts(Enum.join(Acs.MCP.CoreToolRoles.chat_surface(), ","))')
PUBLIC_URL=http://127.0.0.1:4001 SMOKE_API_KEY="<developer-key>" \
  EXPECTED_CHAT_TOOLS="$EXPECTED_CHAT_TOOLS" ./scripts/smoke-chat-tools.sh
```

## Agent rules

- Treat missing `SMOKE_API_KEY` as incomplete prod smoke — call it out; do not pretend chat inventory is verified.
- Never use `SKIP_SMOKE=1` except user-approved break-glass.
- Stay on `dev` for day-to-day; deploy path is user-asked promote → Actions.
- Save procedure changes with `skill_save` / keep this file and the guide in sync.
