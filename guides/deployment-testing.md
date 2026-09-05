# Deployment testing

How ACS proves a change is safe **before** and **after** it hits a running host.

Agent-facing procedure: [`priv/skills/deployment-testing.md`](../priv/skills/deployment-testing.md).  
Ship/cutover ops: [`guides/deployment.md`](deployment.md).

## What this stack is

Three layers. Agents must know which layer they are changing.

| Layer | Runs where | What it proves | Primary files |
|-------|------------|----------------|---------------|
| **CI (dev)** | GitHub Actions on push to `dev` (and PRs to `prod`) | The complete repository readiness contract | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml), [`scripts/repo-readiness.sh`](../scripts/repo-readiness.sh) |
| **CI gate (prod deploy)** | First job of Deploy on push to `prod` / dispatch | Same CI must succeed before image build or cutover | [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) calls CI via `workflow_call` |
| **Local system** | Laptop | Full app boots and MCP/API behave with real `.env` | `mix phx.server` or `docker compose up -d` |
| **Post-deploy smoke** | After cutover (Actions / `deploy.sh`) | Live host healthy + optional chat inventory | [`scripts/deploy.sh`](../scripts/deploy.sh), [`scripts/smoke-chat-tools.sh`](../scripts/smoke-chat-tools.sh) |

CI does **not** boot the multitenant stack or hit Auth0/Neon. Smoke does **not** replace `mix test`. Local system runs are for agent/manual verification of features that need a live process. Prod cutover is **blocked automatically** when the CI gate fails (`skip_ci` on manual Deploy is break-glass only).

## Must be set up (once)

Without these, CI still runs, but **deploy smoke is incomplete** and local MCP work is flaky.

### 1. Local system (dev agents)

```bash
cp .env.example .env   # Auth0 web + MCP_API_KEY + optional LLM keys — never Neon/prod
docker compose up -d
# or: mix phx.server
curl -fsS http://127.0.0.1:4001/mcp/health
```

- URL: `http://localhost:4001`
- Coding MCP: Cursor project server `acs` → `/mcp/sse` (or `/mcp/v1/messages` + `x-api-key` if SSE discovery fails)
- Details: [`guides/deployment.md`](deployment.md) § Local development, [`guides/secrets.md`](secrets.md)

### 2. CI (no secrets required for default jobs)

Push to `dev` (and PRs targeting `prod`) triggers [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). Push/promote to `prod` runs the **same** jobs as Deploy’s **CI gate** before build/cutover (no parallel ungated deploy).

- `readiness` — runs `scripts/repo-readiness.sh` against the Postgres 16 service. It checks whitespace, formatting, warnings-as-errors compilation, Credo, tests, a production release build, and the disposable MCP tool smoke.
- Production containers do not run recurring database probes: `/mcp/health` is DB-free, and the stale-agent sweep opens a transaction only when it has cleanup work. `scripts/deploy.sh` performs a bounded readiness probe during cutover, and the post-deploy smoke runs once.
- Production Ecto queries emit OpenTelemetry spans under `steward_acs.repo.query`, including total, query, queue, decode, and idle timing plus error status. SQL statements remain disabled, so query parameters and stored content are not exported.
- Agents audit production through the project-local Axiom MCP: `steward_logs` contains HTTP/Ecto traces, errors, `vm.metrics`, and `vm.jump`; `steward-acs-metrics` contains host CPU, memory, filesystem, and network series; `steward_meta_analytics` contains tool reliability and Meta-Harness signals. Database URLs and URL query strings are redacted before trace export. Dashboards are optional views, not the management interface.

Run the exact CI contract locally before pushing:

```bash
./scripts/repo-readiness.sh
```

The test step expects local Postgres at `localhost:5432` by default. Override it
with `TEST_DATABASE_URL`; override release-build configuration with
`RELEASE_DATABASE_URL`. The release defaults are CI-only placeholders and are
not production credentials.

Agents: after pushing to `dev`, check `gh run list --branch dev --workflow=CI` / `gh run watch`. On Deploy, a red CI gate means no image push and no cutover.

### 3. Post-deploy smoke (prod GitHub Environment)

Create Environment **prod** (optional **staging**) secrets — see [`guides/deployment.md`](deployment.md). For smoke specifically:

| Secret | Required? | Purpose |
|--------|-----------|---------|
| `PUBLIC_URL` | Yes for public smoke | Base URL for `/mcp/health` (+ DCR) |
| `SMOKE_API_KEY` | Optional but recommended | Developer key (collaborator+) for chat `tools/list` smoke |

If `SMOKE_API_KEY` is unset, cutover still checks health (+ DCR when fixed client is configured) and **skips** chat inventory. Create the key in the prod dashboard (Developers), store only as the Environment secret.

Blue/green helper self-check (no host needed):

```bash
./scripts/check-bluegreen.sh
```

## How to verify a change on `dev` (before promote)

1. Stay on `dev`. Confirm `git branch --show-current` is `dev`.
2. Focused tests for the code you touched: `mix test path/to/file_test.exs`
3. If the feature needs a live server (MCP SSE, LiveView, auditor loop): start local system, hit `/mcp/health`, exercise the path.
4. Push to `dev` → wait for CI green.
5. Do **not** promote to `prod` until the user asks to deploy.

## Extending for new features

Pick the smallest layer that can catch the bug. Update docs/skill in the same change when you add a gate.

### A. New MCP / chat tool

1. Implement the tool + unit tests under `test/`.
2. If it belongs on Claude chat connectors: add the name to `Acs.MCP.CoreToolRoles.chat_surface/0` in [`lib/acs/mcp/core_tool_roles.ex`](../lib/acs/mcp/core_tool_roles.ex).
3. Keep `priv/prompts/chat_system_prompt_body.md` (Always Active / Opt In wrappers via `McpUrls.chat_system_prompt/1`) and chat guidance in sync.
4. Extend [`test/acs/mcp/core_tool_roles_test.exs`](../test/acs/mcp/core_tool_roles_test.exs) (and agent_ops inventory tests if the hash/shape matters).
5. **No smoke script edit required** — deploy smoke evals live `chat_surface/0` from the running container and compares to `/mcp/chat/sse` `tools/list`. Shipping a mismatched image fails smoke automatically when `SMOKE_API_KEY` is set.
6. Coding-only tools: ensure `/mcp/coding/sse` still returns **more** tools than chat (smoke asserts divergence).

For stale PostgreSQL recovery changes, leave database connections idle beyond the provider's close window, then send concurrent tenant MCP requests. They must serialize recovery, recheck the pool before resetting it, and succeed after at most one pool reset. Confirm no background ping was added and no write is retried.

### B. New HTTP route / health invariant

- Prefer ExUnit + ConnCase / LiveView tests in CI.
- If production must fail cutover when broken: add a check in `scripts/deploy.sh` smoke block (after `/mcp/health`) **or** extend `scripts/smoke-chat-tools.sh` if it is MCP-session related. Document the new env secret (if any) in this guide + `guides/deployment.md` + deploy skill.

### C. New runtime dependency (native lib, service)

- Add to CI `test` / `release` / `lint` install steps in `.github/workflows/ci.yml` if the runner needs it.
- If the release image needs it: update `Dockerfile` and confirm the `release` CI job still builds.
- Local: document in `.env.example` / installer skill when agents must configure it.

Compile-time documentation is also a release dependency: Docker must copy `README.md`, `guides/`, and `priv/` before `mix compile`. The docs controller regression test enforces that packaging contract.

### D. New compose / env / Infisical secret

- Thin host `.env` vs Infisical: [`guides/secrets.md`](secrets.md).
- If cutover or smoke needs it: wire through compose + document under GitHub Environment / Infisical tables in `guides/deployment.md`.
- Never put prod secrets in CI logs or laptop `.env` committed to git.

### E. Blue/green / upstream logic

- Change `scripts/lib/acs_bluegreen.sh` + keep `./scripts/check-bluegreen.sh` green.
- Exercise with `deploy.sh --resume` only on a host the user named (prefer Actions).

## Updating the infra itself

| Change | Where | Also update |
|--------|-------|-------------|
| CI jobs / Elixir/OTP versions / Postgres service | `.github/workflows/ci.yml` | This guide if agent steps change |
| Deploy triggers / path filters / Environments | `.github/workflows/deploy.yml` | `guides/deployment.md`, `priv/skills/deployment.md` |
| Cutover + health/DCR/chat smoke | `scripts/deploy.sh`, `scripts/smoke-chat-tools.sh` | This guide + deployment skill |
| Slot/upstream helpers | `scripts/lib/acs_bluegreen.sh`, `scripts/check-bluegreen.sh` | deployment skill |
| Chat allowlist source of truth | `lib/acs/mcp/core_tool_roles.ex` | tests + chat prompt |
| Repository readiness gate | `scripts/repo-readiness.sh` in CI + optional `scripts/git-hooks/pre-commit` format hook | This guide |

### Pre-commit format hook (local)

`.git/hooks` is not versioned, so the hook lives at `scripts/git-hooks/pre-commit` (checks only staged `.ex`/`.exs` files). Each dev enables it repo-locally:

```bash
git config core.hooksPath scripts/git-hooks
```

Bypass for a one-off: `SKIP_FORMAT_CHECK=1 git commit ...` (CI still enforces formatting on `dev` pushes and `prod` PRs).

After changing smoke or CI, run the smallest local check (`mix test …`, `./scripts/check-bluegreen.sh`, or local `PUBLIC_URL=… SMOKE_API_KEY=… EXPECTED_CHAT_TOOLS=… ./scripts/smoke-chat-tools.sh` against a running stack) before relying on Actions.

### Local smoke against a running stack

```bash
# EXPECTED_CHAT_TOOLS from the same build that is serving:
EXPECTED_CHAT_TOOLS=$(mix run -e 'IO.puts(Enum.join(Acs.MCP.CoreToolRoles.chat_surface(), ","))')
PUBLIC_URL=http://127.0.0.1:4001 SMOKE_API_KEY="$SMOKE_API_KEY" \
  EXPECTED_CHAT_TOOLS="$EXPECTED_CHAT_TOOLS" ./scripts/smoke-chat-tools.sh
```

Use a collaborator+ developer key from the local dashboard (or `MCP_API_KEY` only if that key is accepted on `/mcp/chat/sse` in your setup — prefer a real developer key matching prod smoke).

## Agent checklist (short)

- [ ] Infra set up: local `.env` + health; CI watched on `dev`; prod `PUBLIC_URL` + ideally `SMOKE_API_KEY`
- [ ] Feature change: ExUnit first; live local only if needed; chat tools → `chat_surface` + tests
- [ ] New deploy gate: extend smoke/CI in-repo and document here
- [ ] Promote only when the user asks; smoke failures = fix or `--rollback`, do not skip with `SKIP_SMOKE=1` except break-glass
