---
name: "deployment"
description: Deploy and operate Steward ACS (local + multi-tenant prod via GitHub Actions).
when_to_use: Before deploying, cutting over prod, bootstrapping a host, or verifying post-deploy health
tags: ["deployment", "ops", "github-actions", "infisical"]
scope_paths: ["guides/deployment", "scripts", ".github/workflows"]
audit_reasoning: "Primary path is GitHub Actions; laptop deploy.sh is escape hatch. Infisical + Neon documented."
audit_score: 8
audit_status: "ok"
audited_at: "2026-07-26T08:50:00.000000Z"
---

# Deployment

## When to use

Shipping code to multi-tenant prod, checking deploy health, or bringing up a new host. Local SQLite stays `docker compose` only.

## Prerequisites

- Prod secrets in Infisical `steward_prod` / `prod`; host has thin `.env` + `.infisical.env`
- GitHub Environment **prod** (optional **staging**) with `DEPLOY_*`, `SSH_PRIVATE_KEY`, `DOCKERHUB_*`
- Auth0 callback registered for `ACCOUNT_HOST`

## Canonical prod deploy (GitHub Actions)

Workflow: [`.github/workflows/deploy.yml`](../../.github/workflows/deploy.yml)

1. Merge/push to `prod` (or **Actions → Deploy → Run workflow**).
2. Wait for **CI gate** (reusable CI: test + release + credo). Build/cutover only run if CI succeeds.
3. Wait for `build-push` (DockerHub tag = short git SHA) and `cutover` (`deploy.sh --resume` **blue/green** on the Environment host).
4. Confirm Actions green, then smoke (below).

Cutover keeps the live slot serving until the idle slot is healthy, then reloads Caddy upstream and stops the old slot. Caddy is force-recreated only when `Caddyfile.multitenant` / TLS certs change (hash in `CADDY_BUNDLE_HASH`). Claude SSE sessions on the old process still drop at stop — reconnect should hit the already-healthy new slot.
The idle-slot health wait defaults to 300 seconds (`HEALTH_WAIT_SECONDS`). On timeout, `deploy.sh` prints Docker health history and the last 120 container log lines while leaving the active slot serving.

Path filters on `push` to `prod`: `lib/`, `config/`, `priv/`, `assets/`, `mix.*`, `Dockerfile`, multitenant compose/Caddy, `caddy/`, `scripts/deploy.sh`, `scripts/lib/`, `scripts/bootstrap-server.sh`, `scripts/infisical-compose.sh`, `ci.yml` / `deploy.yml`.

`workflow_dispatch` inputs: `environment`, `cutover` (default true), optional `image_tag`, `skip_ci` (default false — break-glass only).

Do **not** default to laptop `ALLOW_DIRTY=1` / full `deploy.sh` when Actions can ship a clean SHA.

## Local

```bash
cp .env.example .env   # local secrets only — never Neon/prod Auth0
docker compose up -d
```

## Host ops (after Actions cutover)

```bash
SERVER=ubuntu@HOST ./scripts/status.sh
SERVER=ubuntu@HOST ./scripts/backup-prod.sh   # vaults + orgs.yaml; DB is Neon PITR
```

Compose on the host always goes through Infisical:

```bash
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml up -d
# optional local Postgres instead of Neon:
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml -f docker-compose.postgres.yml up -d
```

## New server (once)

```bash
SERVER=ubuntu@NEW_HOST ./scripts/bootstrap-server.sh
# write REMOTE_DIR/.infisical.env + thin .env; confirm Infisical secrets
# point a GitHub Environment at the host, then run the Deploy workflow
```

## Escape hatch only (laptop / break-glass)

Use when Actions cannot run, or you must hotfix before a clean main build:

```bash
SERVER=ubuntu@HOST ./scripts/deploy.sh
ALLOW_DIRTY=1 SERVER=ubuntu@HOST ./scripts/deploy.sh
SERVER=ubuntu@HOST ACS_IMAGE_TAG=<tag> ./scripts/deploy.sh --resume
SERVER=ubuntu@HOST ./scripts/deploy.sh --rollback
```

Replace dirty tags with a clean Actions deploy on `main` as soon as possible.

| Setup | Compose | Notes |
|-------|---------|-------|
| Local | `docker-compose.yml` | SQLite, port 4001 |
| Prod Neon | `docker-compose.multitenant.yml` + Infisical | Canonical |
| Local Postgres override | + `docker-compose.postgres.yml` | Optional |

Older `cloudflare` / `remote` / `prod` compose files live under `archive/deploy/` — do not use.

## Env templates

- Local: `.env.example` → `.env` (all local secrets here)
- Prod thin config: `.env.multitenant` → host `.env` (non-secrets only: hosts, `ACS_IMAGE_TAG`, flags)
- Prod secrets: Infisical `steward_prod` / `prod` via `scripts/infisical-compose.sh`
- Host Infisical agent: `.infisical.env` with Universal Auth machine identity (read-only)
- Neon: `DATABASE_URL` in Infisical (pooled string preferred); `PGSSL` / `POOL_SIZE` may be thin `.env`
- Dashboard Auth0 OIDC: `AUTH0_WEB_*` in Infisical; `ACCOUNT_HOST` / callback URI in thin `.env`
- Self-service org creation: keep `SELF_SERVICE_ORGS_ENABLED=false` through migration/bootstrap, then enable deliberately.
- Auth0 M2M for ops scripts only (`./scripts/setup-auth0.sh`, etc.): `AUTH0_M2M_*` / `certs/Oauth.md` — not loaded by the ACS app.
- Axiom (optional): secret `AXIOM_LOGS` in Infisical only; thin `.env` has `AXIOM_DATASET` / `AXIOM_AGENT_OPS_DATASET` / `AXIOM_METRICS_DATASET` / `COMPOSE_PROFILES=axiom`. Hostmetrics: `otel_collector`. Dashboards: `./scripts/axiom-upsert-server-dashboard.sh` (server) and `./scripts/axiom-upsert-agent-ops-dashboard.sh` (Claude/agent usage). Export is prod-only.

## Migrations

Entrypoint runs `Acs.Release.migrate` on start. Manual:

```bash
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml exec steward_acs_blue \
  /app/bin/steward_acs eval "Acs.Release.migrate"
# Active slot: see ACS_ACTIVE_SLOT / status.sh (blue or green).
```

No `mix ecto.migrate` against the release image.

## Testing stack (CI / local / smoke)

Setup, how to extend for new features (especially `chat_surface`), and how to update CI/smoke infra: [`guides/deployment-testing.md`](../../guides/deployment-testing.md) and skill [`deployment-testing`](deployment-testing.md). Chat inventory smoke needs GitHub Environment `SMOKE_API_KEY`; without it health/DCR still run but chat `tools/list` is skipped.

## Smoke checks after deploy

Actions/`deploy.sh` already check container health + public `/mcp/health` (and fixed DCR when configured). Still verify:

1. `SERVER=ubuntu@HOST ./scripts/status.sh` — `health=healthy`, `acs_active_slot=blue|green`, `image_git_sha` matches tag, `env_required_missing=` empty, `compose_wires_oauth_fixed_dcr` matches whether fixed DCR is intended
2. Auth0 login on `ACCOUNT_HOST`, account onboarding, and tenant `/skills`
3. Invite a member (email when Resend is configured, otherwise copy-link), accept with the exact verified email, and verify `/settings/members`
4. `/.well-known/oauth-protected-resource/mcp/sse` if OAuth enabled
5. No `inotify-tools` / EncodeError / pool starvation in `docker logs steward_acs_blue` / `_green` (log metadata must use JsonMap on Postgres)
6. If `AXIOM_LOGS` is set, traces and log events appear in the configured Axiom dataset after the health request. Agent tool usage + Meta-Harness rollups go to `AXIOM_AGENT_OPS_DATASET` (default `steward_meta_analytics`) as `message == "agent.tool"` / `"agent.feedback"` / `"meta.summary"` / `"meta.tool"` / `"meta.error_cluster"` / `"meta.agent"`. Set `META_HARNESS_ENABLED=true` (compose default on multitenant). With `COMPOSE_PROFILES=axiom`, `steward_otel` scrapes host metrics into `AXIOM_METRICS_DATASET`. Agents: upsert dashboards via **Axiom MCP** (`createDashboard` / `updateDashboard`) — see `.cursor/rules/axiom-mcp.mdc`. Templates live in `otel/axiom-*-dashboard.json`; human fallback scripts are `./scripts/axiom-upsert-server-dashboard.sh`, `./scripts/axiom-upsert-agent-ops-dashboard.sh`, and `./scripts/axiom-upsert-llm-dashboard.sh` (need a management token, not ingest-only `AXIOM_LOGS`). `message == "vm.metrics"` Events appear every ~30s (BEAM memory + scheduler utilization; plus `host_memory_*` / `cgroup_*` fields on Linux).

## Agent deploy rules

- **Prefer merge/push to `prod` → GitHub Actions.** That is the production path (blue/green cutover via `deploy.sh --resume`).
- Dirty laptop deploys (`ALLOW_DIRTY=1`) are emergency only; follow with a clean Actions build.
- Never re-add a DCR prune GenServer; prevention is fixed client + ACS-owned `/oidc/register`.
- Mid-cutover failure: Actions re-run with same tag, or `deploy.sh --resume` / `--rollback`.
