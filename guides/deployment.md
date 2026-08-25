# Deployment

Supported setups (only these three):

| Setup | How |
|-------|-----|
| Local dev | `docker compose up -d` (SQLite) |
| Multi-tenant prod (Neon) | **GitHub Actions** → image + Infisical cutover |
| Multi-tenant + local Postgres container | compose override / `WITH_POSTGRES=true` (rare) |

Agent-facing detail lives in [`priv/skills/deployment.md`](../priv/skills/deployment.md). Keep that skill current; this guide is the human index.

**Testing the running system** (CI on `dev`, local boot, post-deploy smoke, extending for new features): [`guides/deployment-testing.md`](deployment-testing.md) and [`priv/skills/deployment-testing.md`](../priv/skills/deployment-testing.md).

## Local development

```bash
cp .env.example .env
# configure Auth0 web credentials; optionally set LLM keys
docker compose up -d
# or: mix phx.server  (loads .env via config/runtime.exs)
```

- Compose: [`docker-compose.yml`](../docker-compose.yml)
- DB: SQLite
- URL: `http://localhost:4001`

## Multi-tenant production (canonical)

**Prod deploys go through GitHub Actions**, not a laptop `deploy.sh` by default.

Workflow: [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml)

1. Merge/push to `prod` (paths under `lib/`, `config/`, `priv/`, `assets/`, `Dockerfile`, compose/Caddy, deploy scripts, or the workflow itself), **or** run **Actions → Deploy → Run workflow**.
   - ⚠️ The push path filter **does NOT include `scripts/` test/smoke scripts** (e.g. `scripts/smoke-chat-tools.sh`). A smoke-only commit pushed to `prod` triggers **no** deploy — this looks like a silent failure. Deploy such changes with a manual dispatch instead: `gh workflow run deploy.yml --ref prod -f environment=prod -f cutover=true -f image_tag="" -f skip_ci=false -f rollback=false`.
2. Job **CI gate** runs the reusable CI workflow (`mix test` + prod release compile + Credo). **Build and cutover do not start if CI fails.** Manual dispatch can set `skip_ci` only for break-glass.
3. Job `build-push` builds the Postgres release image and pushes `naharemete/steward_acs:<git-sha>` (+ `:multitenant`).
4. Job `cutover` SSHs to the Environment host and runs `./scripts/deploy.sh --resume` (**blue/green**): pull idle slot → wait healthy → rewrite `caddy/acs_upstream.caddyfile` + `caddy reload` (recreate Caddy only if Caddyfile/certs changed) → stop previous slot.

### GitHub Environment secrets

Create Environment **prod** (optional **staging**) with:

| Secret / var | Purpose |
|--------------|---------|
| `DEPLOY_HOST` | Server IP/hostname |
| `DEPLOY_USER` | SSH user (e.g. `ubuntu`) |
| `SSH_PRIVATE_KEY` | Deploy key for that host |
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | Image push/pull |
| `PUBLIC_URL` (optional) | Smoke base URL |
| `SMOKE_API_KEY` (optional) | Developer/API key for post-deploy chat `tools/list` smoke (`scripts/smoke-chat-tools.sh`); skipped if unset |
| `REMOTE_DIR` (optional) | Default `/home/ubuntu/steward_acs` |
| `REGISTRY` (optional var) | Default `naharemete/steward_acs` |

After `/mcp/health` (+ optional DCR), deploy runs chat inventory smoke when `SMOKE_API_KEY` is set: opens `/mcp/chat/sse`, calls `tools/list`, asserts names equal `CoreToolRoles.chat_surface/0` from the live container, then checks `/mcp/coding/sse` returns at least one extra tool. Create a collaborator+ developer key in prod and store it only as the GitHub Environment secret (or export locally for break-glass deploys).

Host still needs thin `.env` (from `.env.multitenant`) and `.infisical.env` (machine identity). Secrets stay in Infisical `steward_prod` / `prod` — see [`guides/secrets.md`](secrets.md). Compose on the host always runs through `scripts/infisical-compose.sh`.

### Manual workflow_dispatch

- **environment**: `prod` or `staging`
- **cutover**: `true` (default) to pull + recreate; `false` to build/push only
- **image_tag**: override (empty = short git SHA)
- **skip_ci**: `false` (default). Set `true` only for emergency cutover without the CI gate.

### New server (once)

```bash
SERVER=ubuntu@NEW_HOST ./scripts/bootstrap-server.sh
# write REMOTE_DIR/.infisical.env, confirm Infisical prod secrets, thin .env
# add GitHub Environment secrets for that host, then Actions → Deploy
# optional first start:
SERVER=ubuntu@NEW_HOST ACS_IMAGE_TAG=<sha> ./scripts/bootstrap-server.sh --start
```

### Escape hatch (laptop / emergency)

Prefer Actions. Use workstation deploy only for break-glass (e.g. Actions down, or a one-off dirty hotfix you intend to replace with a clean prod build ASAP):

```bash
SERVER=ubuntu@YOUR_HOST ./scripts/deploy.sh          # clean tree → SHA tag
ALLOW_DIRTY=1 SERVER=ubuntu@YOUR_HOST ./scripts/deploy.sh
SERVER=ubuntu@YOUR_HOST ACS_IMAGE_TAG=<tag> ./scripts/deploy.sh --resume
SERVER=ubuntu@YOUR_HOST ./scripts/deploy.sh --rollback
SERVER=ubuntu@YOUR_HOST ./scripts/status.sh
SERVER=ubuntu@YOUR_HOST ./scripts/backup-prod.sh
```

`deploy.sh` cutover is a single SSH session. Images carry `org.opencontainers.image.revision` + `.dirty` labels for `status.sh`.
The idle-slot health wait defaults to 300 seconds (`HEALTH_WAIT_SECONDS`); if it expires, deploy prints the container health history and last 120 log lines before leaving the active slot untouched.

### Neon database

Prod uses one Postgres database on Neon (`DATABASE_URL` in Infisical `prod`). Prefer Neon's **pooled** connection string. Set `PGSSL=true` in thin `.env` (default in compose). Never commit the URL.

ACS does not ping PostgreSQL while idle, so Neon can suspend. If an idle SSL socket was closed remotely, tenant resolution discards the stale connection pool and retries its read-only lookup once. Writes are not replayed.

Release entrypoint runs migrations on boot. Manual recovery:

```bash
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml exec steward_acs_blue \
  /app/bin/steward_acs eval "Acs.Release.migrate"
# Use the active slot from `ACS_ACTIVE_SLOT` / `./scripts/status.sh` (blue or green).
```

### Local Postgres container (optional)

When you want Postgres on the host instead of Neon:

```bash
# same .env plus DB_PASSWORD=; compose override sets DATABASE_URL to the local db
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml -f docker-compose.postgres.yml up -d
```

| Aspect | Value |
|--------|-------|
| Compose | `docker-compose.multitenant.yml` |
| Caddy | `Caddyfile.multitenant` |
| Env template | `.env.multitenant` |
| Image | `naharemete/steward_acs:${ACS_IMAGE_TAG:-multitenant}` |
| ACS slots | `steward_acs_blue` / `steward_acs_green` (only one live; `ACS_ACTIVE_SLOT` in thin `.env`) |
| Caddy upstream | `caddy/acs_upstream.caddyfile` (reload on flip; recreate only when Caddyfile/certs change) |
| DB | Neon Postgres via `DATABASE_URL` (optional local Postgres override) |
| Memory | Immutable PostgreSQL ledger (`MEMORY_STORE=database`); no tenant memory files |
| Artifacts | Skills, specs/documents, and tenant tool definitions use the PostgreSQL artifact ledger; prompts are shipped read-only from `priv/prompts` |
| Auth | API/developer keys for services; Auth0 OIDC for individual dashboard users and human MCP access |
| Email (optional) | Set `RESEND_API_KEY` + `RESEND_FROM_EMAIL` for invitation email; omit to keep copy-link only |

### Artifact ledger cutover

In multi-tenant production, skills, specs/documents, and tenant tool definitions are database-ledger records. Prompts remain read-only files shipped in `priv/prompts`; multi-tenant runtime does not mount a vault.

For an existing deployment, first back up the vault and freeze artifact writes on the old file-canonical release. Run the new release with the old vault mounted **read-only at `/vaults`** for the cutover only, then migrate and import:

```bash
/app/bin/steward_acs eval "Acs.Release.migrate"
/app/bin/steward_acs eval 'Acs.Release.import_artifacts()'
```

The importer fails closed when `/vaults/orgs` is missing or empty, when a source organization is unknown to the database, when an existing ledger snapshot differs, or when ledger verification fails. Compare the reported imported/skipped counts with the backed-up source inventory for every organization. Only after that verification may you deploy the final Compose topology (which has no vault mount) and retire Syncthing. Do not restart a file-canonical release after accepting new ledger commits.

`MCP_TOOLS_PATH` and `EXTERNAL_TOOLS_PATH` remain read-only shared/plugin sources. Tenant tools are ledger records and may define HTTP endpoints only. Shared YAML handlers are disabled unless each module is explicitly listed in the comma-separated `TRUSTED_MCP_HANDLER_MODULES` allowlist.

### Org registry

`ORGS_FILE=/data/orgs.yaml` (volume). Seed from `priv/orgs.yaml` once if the volume copy is missing:

```bash
docker cp priv/orgs.yaml steward_acs_blue:/data/orgs.yaml
# Or steward_acs_green — use ACS_ACTIVE_SLOT / status.sh.
```

After deploying the organization migration, import that registry into the database before enabling OAuth-only access:

```bash
docker compose -f docker-compose.multitenant.yml exec steward_acs_blue \
  /app/bin/steward_acs eval 'Acs.Release.import_organizations()'
# Active slot: ACS_ACTIVE_SLOT / status.sh.
```

Have each existing organization owner sign in once on `ACCOUNT_HOST`, then bootstrap the verified OAuth identity and invalidate the old shared-login workflow:

```bash
docker compose -f docker-compose.multitenant.yml exec steward_acs_blue \
  /app/bin/steward_acs eval 'Acs.Release.bootstrap_owner("owner@example.com", "org-slug")'
# Active slot: ACS_ACTIVE_SLOT / status.sh.
```

Keep `SELF_SERVICE_ORGS_ENABLED=false` until imports, owner bootstrap, wildcard DNS/TLS, and Auth0 callback settings are verified. New invitations email when Resend is configured (`RESEND_API_KEY` + `RESEND_FROM_EMAIL`); otherwise they expose a single-use link to the administrator. Only the token hash is stored.

### Axiom observability

Production can export inbound HTTP/Phoenix/Ecto traces and structured application logs to Axiom, plus optional host metrics via an OTel collector sidecar.

1. Create an **Events** dataset (logs/traces) and a **Metrics** dataset (hostmetrics) in Axiom.
2. Give an ingest token access to both datasets.
3. **Infisical** (`steward_prod` / `prod`): set secret `AXIOM_LOGS` (ingest token). Never put it in the host thin `.env`.
4. Thin host `.env` (non-secret only):

```bash
AXIOM_DATASET=steward_logs
AXIOM_METRICS_DATASET=steward-acs-metrics
# AXIOM_DOMAIN=https://us-east-1.aws.edge.axiom.co  # edge URL preferred for OTLP
COMPOSE_PROFILES=axiom
```

App export is enabled only when the release runs in `prod` and Infisical injects a non-empty `AXIOM_LOGS`. Development and test never ship telemetry. Keep the token ingest-scoped to the configured datasets. `AXIOM_DATASET` must be the existing Events dataset name (`steward_logs`) — the default `steward-acs` name does not exist in this org and ingest is dropped.

`COMPOSE_PROFILES=axiom` starts `otel_collector` (see `otel/collector-config.yaml`), which scrapes host CPU/memory/disk/network every 30s into `AXIOM_METRICS_DATASET`.

After deploying, request `/mcp/health`, exercise a database-backed route, and confirm traces and log events arrive. Every ~30s, `message == "vm.metrics"` Events ship BEAM memory/`scheduler_utilization` plus best-effort Linux fields (`host_memory_*_bytes` from `/proc/meminfo`, `cgroup_memory_*_bytes` / `cgroup_cpu_utilization`). Those are Events-dataset rows (not a separate OTLP metrics stream) and complement hostmetrics. Create/update the monitoring dashboard:

```bash
AXIOM_TOKEN=xaat-… AXIOM_DATASET=steward_logs AXIOM_METRICS_DATASET=steward-acs-metrics \
  ./scripts/axiom-upsert-server-dashboard.sh
```

That script ensures the Metrics dataset exists and upserts the **Steward ACS — server** dashboard (host MPL panels + BEAM `vm.metrics` APL panels).

### Secrets

Local: untracked `.env`. Multi-tenant prod: Infisical via `scripts/infisical-compose.sh` (thin host `.env` is non-secret config only). See [`guides/secrets.md`](secrets.md).

Archived older compose files: [`archive/deploy/`](../archive/deploy/).
