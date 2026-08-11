---
description: "Deploy and operate Steward ACS (local + multi-tenant prod via GitHub Actions)."
name: "deployment"
proposed_by: "nahar emet"
scope_paths: ["guides/deployment", "scripts", ".github/workflows"]
status: "approved"
tags: ["deployment", "ops", "github-actions", "infisical"]
when_to_use: "Before deploying, cutting over prod, bootstrapping a host, or verifying post-deploy health"
audit_reasoning: "This is an exemplary skill. It is highly actionable with numbered steps, exact commands, file paths, and clear prerequisites. It covers the full lifecycle: local setup, canonical prod deploy via GitHub Actions, host operations, new server bootstrap, escape hatches, and post-deploy smoke checks. The description is distinct and informative. The content is perfectly tailored for a 'coding' audience (IDE agents) with precise tool references (GitHub Actions, Infisical CLI, Docker Compose, Caddy, Axiom). It includes failure recovery (rollback, re-run) and verification steps. It is unique and not duplicated by existing skills. The scope is well-defined and matches the content."
audit_score: 10
audit_status: "ok"
audited_at: "2026-08-05T09:22:46.021990Z"
approved_at: "2026-08-05T09:22:46.028797Z"
approved_by: "llm"
reviewed_at: "2026-08-05T09:22:46.028797Z"
reviewed_by: "llm"
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

1. **Commit and push/merge to `main`** (or **Actions → Deploy → Run workflow**).
2. Wait for `build-push` (DockerHub tag = short git SHA) and `cutover` (`deploy.sh --resume` on the Environment host).
3. Confirm Actions green, then smoke (below).

Path filters on `push` to `main`: `lib/`, `config/`, `priv/`, `assets/`, `mix.*`, `Dockerfile`, multitenant compose/Caddy, `scripts/deploy.sh`, `scripts/bootstrap-server.sh`, `scripts/infisical-compose.sh`, the workflow file.

`workflow_dispatch` inputs: `environment`, `cutover` (default true), optional `image_tag`, `skip_ci` (break-glass), `rollback` (default false — roll back to previous tag, no build).

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
```

`bootstrap-server.sh` is idempotent and does: install Docker Engine (get.docker.com) + Compose, install Infisical CLI (cloudsmith deb), create `$REMOTE_DIR=/home/ubuntu/steward_acs` with `priv/certs/ scripts/ lib/ caddy/ otel/` subdirs, scp the compose/Caddy/scripts/priv files, and seed the thin `.env` from `.env.multitenant` (mode 600, `ACS_IMAGE_TAG` pinned) **only if absent**.

Before `--start`, on the host:

1. Write `$REMOTE_DIR/.infisical.env` (mode 600) with the Universal Auth machine identity:
   ```
   INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=<uuid>
   INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=<uuid>
   ```
   Verify with: `infisical login --method=universal-auth --client-id --client-secret --silent --plain` then `infisical export --projectId 6395f4c0-45f2-4f54-802d-26a55bbb9555 --env prod` (project id from `scripts/infisical-compose.sh`). If login 401s, the Client ID/Secret pair is wrong or from the wrong region (`--domain https://eu.infisical.com` for EU); get corrected creds from Infisical dashboard → Access Control → Machine Identities → Universal Auth.
2. Confirm Infisical prod secrets are filled. Placeholders `REPLACE_ME` and empty values are **skipped** by `infisical-compose.sh` (they don't fail the deploy, they just won't be injected).
3. Open ports 80/443 (ufw) and point DNS at the host. The multitenant Caddyfile serves a wildcard `*.stewardacs.xyz` block using a Cloudflare Origin CA cert: install `origin.pem` (644) + `origin.key` (600) at `$REMOTE_DIR/certs/` (Caddy mounts `./certs:/etc/caddy/certs:ro`). No ACME issuance needed behind Cloudflare proxied DNS.
4. SSH access: install an agent/ed25519 key in `~/.ssh/authorized_keys`, disable password auth (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`).

Then start the stack:

```bash
SERVER=ubuntu@NEW_HOST ./scripts/bootstrap-server.sh --start   # runs deploy.sh --resume (blue/green cutover)
```

### New-server gotcha: SYNCTHING_*_API_KEY required

`docker-compose.multitenant.yml` has 4 syncthing services (`syncthing_default/_prod/_fsgbhutan/_safetyconnect`) **not gated by any profile** (only `axiom` has `profiles:["axiom"]`), each requiring `${SYNCTHING_*_API_KEY:?Set...}` for `STGUIAPIKEY`. These keys are commented out in `.env.multitenant` (commit 23272b5) — they must live in Infisical `prod` or `bootstrap-server.sh --start` / `deploy.sh` dies at compose interpolation with `required variable SYNCTHING_*_API_KEY is missing a value`. App code does **not** read them; they only gate the compose file. Generate with `openssl rand -hex 24` and set with `infisical secrets set <NAME>=<value> --type shared` (machine identity defaults `--type` to personal for deletes; use `--type shared` for both set and delete).

### GitHub Environment secrets for the new host

Repo `NaharEmet/steward_acs`, environment `prod` (set via `gh secret set -e prod`): `DEPLOY_HOST` (new IP), `DEPLOY_USER=ubuntu`, `SSH_PRIVATE_KEY` (a dedicated deploy key — public half appended to host `~/.ssh/authorized_keys`; NOT the operator's `~/.ssh/config` key), plus `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN`. `REMOTE_DIR` defaults to `/home/ubuntu/steward_acs` in the workflow; `PUBLIC_URL` / `SMOKE_API_KEY` are optional extras.

## Escape hatch only (laptop / break-glass)

Use when Actions cannot run, or you must hotfix before a clean main build:

```bash
SERVER=ubuntu@HOST ./scripts/deploy.sh
ALLOW_DIRTY=1 SERVER=ubuntu@HOST ./scripts/deploy.sh
SERVER=ubuntu@HOST ACS_IMAGE_TAG=<tag> ./scripts/deploy.sh --resume
SERVER=ubuntu@HOST ./scripts/deploy.sh --rollback
```

Rolling back after a breaking bug is not a bare escape-hatch: load the `prod-rollback` skill, **ask the user first**, then roll back via GitHub Actions (`rollback: true` dispatch) or `CONFIRM=yes SERVER=ubuntu@HOST ./scripts/rollback.sh` (interactive prompt if `CONFIRM` is unset). Never run a rollback without explicit user approval.

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
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml exec steward_acs \
  /app/bin/steward_acs eval "Acs.Release.migrate"
```

No `mix ecto.migrate` against the release image.

## Smoke checks after deploy

Actions/`deploy.sh` already check container health + public `/mcp/health` (and fixed DCR when configured). Still verify:

1. `SERVER=ubuntu@HOST ./scripts/status.sh` — `health=healthy`, `image_git_sha` matches tag, `env_required_missing=` empty, `compose_wires_oauth_fixed_dcr` matches whether fixed DCR is intended
2. Auth0 login on `ACCOUNT_HOST`, account onboarding, and tenant `/skills`
3. Invite a member (email when Resend is configured, otherwise copy-link), accept with the exact verified email, and verify `/settings/members`
4. `/.well-known/oauth-protected-resource/mcp/sse` only if OAuth enabled — it returns **404 by design** when `OAUTH_BEARER_ENABLED` is unset (single-tenant MCP uses `MCP_API_KEY`). Check `/mcp/sse` (401 without a token = reachable and guarded) and `/mcp/health` (200) instead.
5. No `inotify-tools` / EncodeError / pool starvation in `docker logs steward_acs` (log metadata must use JsonMap on Postgres)
6. If `AXIOM_LOGS` is set, traces and log events appear in the configured Axiom dataset after the health request. Agent tool usage + Meta-Harness rollups go to `AXIOM_AGENT_OPS_DATASET` (default `steward_meta_analytics`) as `message == "agent.tool"` / `"agent.feedback"` / `"meta.summary"` / `"meta.tool"` / `"meta.error_cluster"` / `"meta.agent"`. Set `META_HARNESS_ENABLED=true` (compose default on multitenant). With `COMPOSE_PROFILES=axiom`, `steward_otel` scrapes host metrics into `AXIOM_METRICS_DATASET`. Run `./scripts/axiom-upsert-server-dashboard.sh`, `./scripts/axiom-upsert-agent-ops-dashboard.sh`, and `./scripts/axiom-upsert-llm-dashboard.sh` once for the server, agent-usage, and LLM token dashboards. `message == "vm.metrics"` Events appear every ~30s (BEAM memory + scheduler utilization; plus `host_memory_*` / `cgroup_*` fields on Linux).

## Agent deploy rules

- **Prefer merge/push to `main` → GitHub Actions.** That is the production path.
- Dirty laptop deploys (`ALLOW_DIRTY=1`) are emergency only; follow with a clean Actions build.
- Never re-add a DCR prune GenServer; prevention is fixed client + ACS-owned `/oidc/register`.
- Mid-cutover failure: Actions re-run with same tag, or `deploy.sh --resume`. For a breaking bug already live, follow the `prod-rollback` skill (ask the user first, then `rollback: true` dispatch or `rollback.sh`).
