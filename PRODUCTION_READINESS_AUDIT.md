# Production Readiness Audit

**Audit date:** 2026-07-30  
**Project:** Steward ACS  
**Scope:** application correctness, authentication and authorization, tenant isolation, MCP/API behavior, dependencies, CI/CD, release construction, containers, migrations, backup/restore, observability, resource safety, tests, documentation, and unfinished-code markers.

## Executive verdict

> **NOT PRODUCTION READY — release blocked.**

The repository can assemble a production release, but it must not be exposed as an unattended public production service in its current state. A supported production configuration can fall back to the fixed `admin/admin` dashboard credentials and grant organization-owner access. The current test suite also demonstrates a cross-tenant task-feedback failure. Locked dependencies contain published high-severity advisories, CI does not gate deployment, and several production paths have tenant-context, PostgreSQL, availability, migration, and recovery defects.

### Minimum release gate

Do not release until, at minimum:

1. Default dashboard authentication is removed from production and incomplete OIDC configuration fails startup.
2. The cross-tenant feedback test and all other tests pass deterministically.
3. Published dependency advisories are resolved and dependency auditing is required in CI.
4. Deployment consumes the exact artifact/digest produced by a successful required CI run.
5. Production PostgreSQL behavior, tenant context propagation, outbound-request safety, and the core `ask` path are corrected and covered by tests.
6. Database TLS fails closed, migration compatibility is proven, and backup restoration is tested.

## Verification performed

| Check | Result |
|---|---|
| `mix format --check-formatted` | **Failed** — 25 files are not formatted. |
| `mix compile --warnings-as-errors` | **Passed**. |
| `mix credo --strict` | **Failed** — one warning (`Acs.Specs.Entry` has 36 fields). |
| `mix hex.audit` | **Failed** — eight advisories across four locked packages, including three High advisories. |
| `mix deps.unlock --check-unused` | **Failed** — 20 unused lock entries. |
| `mix test` | **Failed** — 604 tests, 2 failures, 4 excluded. |
| `MIX_ENV=prod mix release` with placeholder `REPO_ADAPTER`, `SECRET_KEY_BASE`, `DATABASE_URL`, `PGPASSWORD`, `MCP_API_KEY`, and `PHX_HOST` values | **Passed release assembly only** — startup, database connectivity/TLS, migrations, and image boot were not exercised. |
| Shell syntax (`bash -n` for Bash scripts; `sh -n` for the entrypoint) | **Passed**. |
| Explicit TODO/FIXME/stub scan | No explicit application TODO/FIXME implementation marker found; one ineffective placeholder branch is documented below. |
| Docker/Compose rendering and image boot | **Not run** — Docker is unavailable in the audit environment. |

The four excluded tests require an external Ollama service. Host controls, GitHub branch protections, Infisical contents, Auth0 tenant configuration, Neon PITR settings, externally mounted MCP tools/vault data, certificates, firewall rules, and external alerting could not be verified from the repository.

---

## Critical finding

### C-01 — Production can grant owner access with fixed `admin/admin` credentials

**Evidence:**

- `config/config.exs:48-53` configures `basic_auth: [username: "admin", password: "admin"]`.
- `lib/acs_web/controllers/user_session_controller.ex:20-31` uses password login whenever complete OIDC configuration is unavailable.
- `lib/acs_web/controllers/user_session_controller.ex:212-222` only enables OIDC in multi-tenant mode and only when every required setting is present.
- `docker-compose.multitenant.yml:55-59` permits empty Auth0 client values.
- `lib/acs_web/controllers/user_session_controller.ex:328-337` reads application config, not the documented `ACS_USERNAME`/`ACS_PASSWORD` environment values.
- `lib/acs_web/controllers/user_session_controller.ex:342-369` creates or upgrades `admin@localhost` to organization owner after successful Basic authentication.
- `config/runtime.exs:144-166` does not validate production dashboard authentication.

**Impact:** Single-tenant production always uses the Basic-auth path, and an incompletely configured multi-tenant deployment falls back to it. A remote user can use known credentials and obtain owner privileges.

**Required action:** Disable Basic auth in production or require explicit strong credentials; reject `admin/admin`; and make multi-tenant production fail startup unless the complete OIDC configuration is valid. Never fall back from failed/incomplete OIDC to default credentials.

---

## High-severity findings

### H-01 — Cross-tenant task feedback is accepted

`mix test` failed `test/acs/multi_tenant_security_test.exs:98-111`: feedback submitted from `org-a` for an `org-b` task returned `{:ok, ...}` instead of `{:error, "Task not found"}`.

`lib/acs/mcp/tools/error_handlers.ex:31-42` performs an unscoped task lookup and has identical `if` branches, so the lookup result has no effect. It then stores feedback under the caller organization using the foreign task ID (`lib/acs/mcp/tools/error_handlers.ex:44-63`).

**Impact:** Cross-tenant referential integrity and audit attribution are broken. This is both a production defect and a failing security regression test.

**Required action:** Fetch the task by `{org, task_id}`, reject absent/foreign tasks, enforce an appropriate database constraint, and retain the regression test.

### H-02 — Locked dependencies have published security advisories

`mix hex.audit` reports:

- `bandit 1.12.0`: **High**, CVE-2026-65623 / GHSA-vg8x-66vg-5pxh — quadratic CPU usage for fragmented WebSocket messages.
- `phoenix 1.8.8`: **High**, CVE-2026-56811 / GHSA-6983-jfq8-485w — unbounded channel joins can exhaust processes.
- `hackney 1.25.0`: **High**, CVE-2026-47071 / GHSA-gp9c-pm5m-5cxr — SOCKS5 TLS upgrade ignores timeout.
- `phoenix 1.8.8`: **Medium**, CVE-2026-56812.
- `hackney 1.25.0`: **Medium**, CVE-2026-47075 and CVE-2026-47076.
- `postgrex 0.22.2`: **Low**, CVE-2026-58225.
- `hackney 1.25.0`: **Low**, CVE-2026-47069.

The stale `hackney` package is among the unused lock entries. Contrary to `guides/security-audit.md:34,42`, `.github/workflows/ci.yml` does not run `mix hex.audit` or `mix deps.unlock --check-unused`.

**Required action:** Upgrade affected direct/transitive packages, prune unused lock entries, rerun tests, and make both checks required CI gates.

### H-03 — Outbound app/tool requests permit SSRF and possible service-key disclosure

- `lib/acs/mcp/tools/core_handlers.ex:653-680` stores arbitrary `base_url` values.
- `lib/acs/acs.ex:282-310` sends a request to the value without centralized URL safety checks or explicitly disabling redirects.
- `lib/acs/mcp/bridge.ex:203-226` can fall back to the deployment-wide `SERVICE_API_KEY` for the configured organization.
- `lib/acs/mcp/url_safety.ex:55,93-103` permits HTTP and an empty production host allowlist.

**Impact:** The `Acs.list_orgs/1` path bypasses `UrlSafety` and can request internal destinations using a tenant-configured app URL. Normal bridge calls do invoke `UrlSafety`, which rejects currently resolved private addresses, but they still permit HTTP, accept any public host when the allowlist is empty, and do not establish redirect or DNS-rebinding safety. For the configured/default organization, an attacker-controlled public destination may receive the global service credential.

**Required action:** Apply one fail-closed URL validation path to every outbound request, require HTTPS and a non-empty production allowlist, disable redirects, remove the global key fallback, use org-scoped credentials, and enforce network egress policy against private/metadata ranges and DNS rebinding.

### H-04 — OAuth email relinking does not require a verified-email claim

`lib/acs/mcp/plugs/strategies/oauth_bearer.ex:37-53` does not map or require `email_verified`. `lib/acs/mcp/plugs/mcp_auth.ex:138-149` links an unknown token subject to a local user by email alone. The behavior is covered as accepted behavior in `test/acs/mcp/plugs/oauth_local_authorization_test.exs:83-108`.

**Impact:** A valid token from an enabled connection with an unverified/spoofable matching email can be authorized as an existing local user.

**Required action:** Link identities by issuer/subject. If email fallback remains, require a boolean verified claim and a controlled, audited linking flow.

### H-05 — The “read-only” diagnostic SQL tool can block shared PostgreSQL

`lib/acs/mcp/tools/diagnostic_handlers.ex:293-338` accepts broad `SELECT`, `WITH`, and `EXPLAIN` expressions when denylisted table words are absent. `lib/acs/mcp/tools/diagnostic_handlers.ex:275-276` executes accepted SQL without an explicit query timeout or database-side statement timeout. `SELECT pg_sleep(300)` passes the SQL shape checks, although `Ecto.Adapters.SQL.query/3` remains subject to the Repo/DBConnection client timeout; the cited evidence does not establish that a connection remains occupied for the full 300 seconds.

**Impact:** An organization admin can execute accepted `SELECT`/function expressions under the application database role and repeatedly consume database and global tool-registry time until cancellation. Side effects depend on the functions and privileges available to that role.

**Required action:** Replace arbitrary SQL with fixed diagnostics, use a least-privilege role, and enforce short client- and database-side statement timeouts.

### H-06 — Deployment is not gated on CI success

A push to `prod` starts CI (`.github/workflows/ci.yml:3-7`) and a separate deployment (`.github/workflows/deploy.yml:40-70`) independently. Deployment cutover depends only on image build/push (`.github/workflows/deploy.yml:98-117`). A failing test, lint, audit, or release check can race with or follow a production deployment.

**Required action:** Make deployment consume a successful reusable CI workflow or a successful workflow-run event for the same immutable commit. Promote the exact tested image digest.

### H-07 — Production PostgreSQL behavior is not tested by the test job

CI starts PostgreSQL and supplies `DATABASE_URL` (`.github/workflows/ci.yml:13-26,55-58`), but `config/test.exs:3-14` forces SQLite and `postgrex` is prod-only (`mix.exs:46-49`). Production migrations, constraints, locking, SQL syntax, and adapter behavior therefore remain untested.

**Required action:** Add a real PostgreSQL integration lane with PostgreSQL available in the test environment and run migrations plus critical tenant, locking, vector, and concurrency tests against it.

### H-08 — Automatic migrations are not safe for blue/green rollback

`docker/entrypoint.sh:40-43` applies every pending migration while the previous slot is still serving (`scripts/deploy.sh:257-269`). Existing migrations can delete users/tokens (`priv/repo/migrations/20260723000000_create_organization_membership_system.exs:45-68`) or clear embeddings on conversion errors (`priv/repo/migrations/20260726120000_enable_pgvector_embeddings.exs:69-84`). Documented rollback changes the image/slot, not the database schema (`scripts/deploy.sh:193-220`).

**Required action:** Use explicit pre-cutover migrations after a verified snapshot/PITR checkpoint, enforce expand/contract compatibility with N and N-1, test rollback/recovery, and document that image rollback does not reverse schema changes.

### H-09 — Backup and disaster recovery are incomplete

`scripts/backup-prod.sh:33-53` covers legacy SQLite/vault metadata but not the supported local PostgreSQL topology in `docker-compose.postgres.yml:24-44`. Vault backup is a live `tar`, remains on the same host, and has no codified schedule, retention, checksum, encryption, off-host copy, restore automation, RPO, or RTO. A restore drill remains explicitly outstanding in `guides/security-audit.md:77`.

**Required action:** Add consistent Postgres and vault snapshots, off-host encrypted retention, backup-age monitoring, restore automation, and recurring restore drills for every supported topology.

### H-10 — Production database connections can be plaintext or use unauthenticated TLS

`config/runtime.exs:99-135` accepts `PGSSL=false`, which disables TLS. When `PGSSL` is unset, TLS is enabled only when the URL contains `neon.tech`, `sslmode=require`, or `sslmode=verify-full`, so other remote PostgreSQL URLs can default to plaintext. When TLS is enabled but no CA certificates are returned, configuration falls back to `verify: :verify_none`. The runtime image does not explicitly name `ca-certificates`, although it may be installed transitively.

**Impact:** Database credentials and tenant traffic can be sent without encryption or over TLS without server authentication, enabling active interception.

**Required action:** For production remote PostgreSQL, require TLS with peer and hostname verification, reject `PGSSL=false`, parse and enforce SSL configuration rather than matching URL substrings, and fail startup if a trusted CA bundle is unavailable. Define a narrowly scoped exception for an explicitly local database topology if plaintext transport there is intentionally supported.

### H-11 — `ask` crashes when agent status is non-empty

`lib/acs/mcp/tools/query_agent.ex:220-224` expects status entries shaped as `{agent_id, status}`, while `lib/acs/acs.ex:190-215` returns maps with `:agent_id`. With the default `include_agent_status: true`, an active agent can trigger `FunctionClauseError` in a core query tool.

**Required action:** Establish one documented return shape, update consumers, and add a test where agent status contains at least one entry.

### H-12 — One slow tool blocks the global MCP tool registry

`lib/acs/mcp/tool_registry.ex:271-290` runs external HTTP/LLM/filesystem/database work synchronously inside `GenServer.handle_call/3`; callers can wait up to 180 seconds (`lib/acs/mcp/tool_registry.ex:6-33`).

**Impact:** One slow call blocks listing, authorization, refresh, and execution for every tenant.

**Required action:** Keep registry state operations short and execute tools in bounded supervised tasks/caller processes with per-tenant/global concurrency and timeouts.

### H-13 — Background work loses tenant context

- `lib/acs/memory/embedding.ex:347-378,421-435` does not retain/use `{org, id}` consistently.
- `lib/acs/specs/tools.ex:129-155` spawns work without capturing and restoring the current organization.
- `lib/acs/skills/auditor.ex:32-35,65-79` queues only a skill name and resolves it in the worker’s default context.

**Impact:** Non-default tenants can miss embeddings/audits or affect similarly named data in the configured tenant.

**Required action:** Pass organization explicitly through every message/task/upsert and wrap background execution in `Acs.Org.with_current/2`. Key discovery by `{org, id}`.

### H-14 — SQLite SQL placeholders are used on production PostgreSQL paths

Production defaults to PostgreSQL (`config/prod.exs:3-9`), but `lib/acs/specs/vector_search.ex:103-116` and `lib/acs/meta_harness/operation_logger.ex:347-363` use SQLite `?` placeholders. Errors are ignored/swallowed.

**Impact:** Stale vector chunks can survive deletes/replacements and operation telemetry can silently disappear in production.

**Required action:** Use adapter-correct SQL or Ecto queries and propagate/log failures. Cover these paths in PostgreSQL integration tests.

### H-15 — SSE sessions have no concurrency or lifetime limits

`lib/acs/mcp/http_server.ex:588-615` keeps connections alive indefinitely; `lib/acs/mcp/sse_session_manager.ex:48-61` maintains an unbounded session map. Registration is synchronous, but it occurs only after the endpoint chunk has been published (`lib/acs/mcp/http_server.ex:565-575`), leaving a narrow race in which a client can use the published session ID before registration completes.

**Impact:** Authorized connection churn can exhaust processes/sockets/monitors, and fast clients can race registration.

**Required action:** Register the session before publishing its endpoint, cap sessions globally/per principal/per tenant, and enforce idle and maximum lifetimes.

### H-16 — Readiness and cutover checks are incomplete

`/mcp/health` verifies only `SELECT 1` (`lib/acs/mcp/http_server.ex:375-396`). Required indexing/cache warmup runs afterward in unsupervised tasks (`lib/acs/application.ex:98-161`). The old slot is stopped before the public TLS/proxy smoke test (`scripts/deploy.sh:278-304,349-358`).

**Required action:** Separate liveness/readiness, supervise and gate required initialization, validate Caddy/TLS/public routing before stopping the old slot, and automatically restore the old upstream after failure.

### H-17 — Syncthing instances are not tenant-isolated

All Syncthing instances initialize as root and mount the same full `vaults` volume (`docker-compose.multitenant.yml:1-12,160-192`). Compromise or misconfiguration of one instance exposes other tenant files.

**Required action:** Use separate tenant volumes and unprivileged tenant-specific identities, with a backup-tested migration.

---

## Medium-severity findings

### M-01 — Reader keys can mutate tasks

`reader` is a valid role (`lib/acs/developers/developer_api_key.ex:40`), but `POST /api/tasks` and `PATCH /api/tasks/:id` do not enforce a writer capability (`lib/acs/mcp/http_server.ex:399-469`). Add route-specific authorization.

### M-02 — Reverse-proxy rate limiting is cross-tenant for OAuth clients

Rate limiting runs before auth and often keys on `remote_ip` (`lib/acs/mcp/http_server.ex:26-27`; `lib/acs/mcp/plugs/rate_limit.ex:53-66`). Behind Caddy, clients can share the proxy peer address. Configure trusted proxy resolution, a small pre-auth IP limit, and a post-auth principal/tenant limit.

### M-03 — One global log-ingest key can target every tenant

`config/runtime.exs:194-195` loads one global key; `lib/acs/mcp/plugs/mcp_auth.ex:211-232` validates it and derives the target tenant from host. Use org-bound keys/tokens and compare credential organization with resolved host.

### M-04 — Potentially sensitive feedback and upstream error text lack redaction

`lib/acs/observability/agent_ops.ex:124-185,298-310` exports bounded but otherwise raw feedback/error fields to the configured Axiom sink. `lib/acs/mcp/bridge.ex:84-88` returns upstream response bodies to the authenticated caller. This establishes telemetry data-minimization and error-disclosure risks, but the cited code does not by itself establish a cross-tenant disclosure. Export derived metadata only, apply sink-independent redaction, and sanitize upstream errors before returning them.

### M-05 — Error responses can continue into handler execution

`lib/acs/mcp/http_server.ex:221-232,244-267,325-366` ignores halted connections or mixes `%Plug.Conn{}` with option-list branches. Return immediately from errors to prevent retrieval, double-send, and request crashes.

### M-06 — Log persistence spawns an unsupervised task per entry

`lib/acs/mcp/log_store.ex:74-114` starts a task per database insert, while ingestion accepts batches of 500 (`lib/acs/mcp/http_server.ex:136-170`). Use a bounded supervised batching worker with backpressure/drop policy.

### M-07 — `SleepRegistry` leaks stale queue/monitor state

`lib/acs/acs/sleep_registry.ex:90,190-220` discards monitor refs and fails to clean queue/dispatched entries consistently. Store/demonitor refs, compact queues, and handle all `DOWN` cases.

### M-08 — Concurrent task bumps lose updates

`lib/acs.ex:80-91` performs read/increment/write without atomic SQL or locking. Use an atomic `inc` update scoped by tenant and task ID.

### M-09 — Tenant log pagination filters after global truncation

`lib/acs/mcp/log_store.ex:245-286,528-565` selects a limited global prefix before filtering by organization. A noisy tenant can make another tenant’s pages incomplete and evict its logs. Filter at selection time and enforce per-tenant retention.

### M-10 — Formatting is not enforced and currently fails

CI never runs `mix format --check-formatted`. The current command reports 25 files:

`lib/acs/abac.ex`, `lib/acs/accounts.ex`, `lib/acs/acs/task.ex`, `lib/acs/mcp/client_session.ex`, `lib/acs/mcp/http_server.ex`, `lib/acs/mcp/tool_registry.ex`, `lib/acs/mcp/tools/error_handlers.ex`, `lib/acs/mcp/tools.ex`, `lib/acs/mcp/tools/memory_handlers.ex`, `lib/acs/mcp/tools/skill_handlers.ex`, `lib/acs/memory/guidance.ex`, `lib/acs/meta_harness/generator.ex`, `lib/acs/observability/agent_ops.ex`, `lib/acs/org.ex`, `lib/acs/orgs_cache.ex`, `lib/acs/orgs.ex`, `lib/acs/specs/auditor.ex`, `lib/acs_web/live/acs_live/members_live.ex`, `lib/acs_web/live/acs_live/prompts_live.ex`, and six test files.

Add formatting as a required CI check.

### M-11 — Strict Credo currently fails and key checks are disabled

`mix credo --strict` reports a 36-field struct warning at `lib/acs/specs/entry.ex:26`. `.credo.exs:9-37` disables TODO/FIXME, duplicate-code, complexity, nesting, arity, and multiple readability checks. Resolve or explicitly justify the warning; re-enable useful checks or document exceptions narrowly.

### M-12 — The second failing test exposes global test-state pollution

`test/acs/meta_harness/recent_ops_test.exs:11-34` expected one tool but observed five. `RecentOps.setup/0` creates an existing named ETS table without clearing it (`lib/acs/meta_harness/recent_ops.ex:13-32`), so application/test operations leak into the test.

Make test ownership/reset deterministic. This may be a test-isolation defect rather than a production behavior defect, but it prevents a reliable release signal.

### M-13 — Coverage is configured but not generated or enforced

ExCoveralls is configured (`mix.exs:13,63-64,75,84-86`) but CI only runs `mix test`. Publish coverage and enforce a meaningful baseline plus focused expectations for security-critical modules.

### M-14 — No PR-time CI for changes targeting `dev`

`.github/workflows/ci.yml:3-7` runs pull-request checks only for `prod`; changes can land in `dev` before CI unless external branch protection compensates. Run required checks for PRs targeting both protected development and production branches.

### M-15 — Static and end-to-end quality gates are incomplete

No Dialyzer lane, browser/authenticated E2E journey, image startup/migration test, secret scan, SBOM scan, or container scan exists. LiveView route tests cover only a small part of the authenticated/admin surface, and operator Mix tasks have no dedicated `test/mix/` coverage.

### M-16 — Tests mutate process-global configuration and use timing sleeps

At least two async MCP URL test modules mutate shared application configuration, and some tests use fixed `Process.sleep/1` timing. Serialize shared-config tests or inject configuration; replace sleeps with deterministic/eventual assertions.

### M-17 — No per-container resource or log-retention limits

`docker-compose.multitenant.yml` has no CPU, memory, PID, reservation, or Docker log-rotation limits. Ollama or logs can starve the application. Add capacity limits/reservations, `max-size`/`max-file`, disk monitoring, and document that the single-active-slot topology is not runtime HA.

### M-18 — Production observability can silently be disabled

An empty Axiom token disables export/tracing (`config/runtime.exs:17-64`), Compose defaults it empty, and no alert definitions/incident runbook are codified. Require production observability or an explicit exception; monitor exporter drops, health/5xx, DB pool, disk/memory, cert expiry, migration failure, and backup age.

### M-19 — Custom registry configuration does not reach Compose

The deploy workflow can push to `vars.REGISTRY`, but `docker-compose.multitenant.yml:24` hardcodes `naharemete/steward_acs` and cutover passes only the tag. Parameterize and pass the repository or remove the unsupported option.

### M-20 — Documentation and environment templates drift from runtime

- `.env.multitenant:15` enables self-service while `guides/deployment.md:173` says to keep it disabled until bootstrap is verified.
- README local instructions describe Auth0 while local Compose disables OIDC.
- README/Docker/CI use `COOKIE_SIGNING_SALT`, while runtime reads `SESSION_SIGNING_SALT` (`config/runtime.exs:77`).
- README says CORS defaults to `*`, while `config/config.exs:3-8` defaults to localhost.
- `guides/security-audit.md` claims a clean suite and CI-enforced Hex/lock audits, but the current suite/audits fail and CI lacks those commands.

Generate one canonical configuration reference and test templates/documented variable names against runtime consumers.

### M-21 — Mutable image references and missing supply-chain verification

Dockerfile bases and production services use mutable tags, including `syncthing/syncthing:latest`, `ollama/ollama:latest`, `caddy:2-alpine`, and the application’s mutable `:multitenant` fallback (`Dockerfile:4,31,70`; `docker-compose.multitenant.yml:7,24,94,137`). Normal application deployments use a commit-derived tag, but no image/SBOM scan, provenance, signing, or verification gate exists.

**Required action:** Pin digests, use immutable tags, generate SBOM/provenance, scan, sign, verify at deployment, and pin third-party Actions by commit SHA.

---

## Low-severity findings

### L-01 — Unused lock entries increase maintenance and advisory noise

`mix deps.unlock --check-unused` reports 20 entries: `certifi`, `cloak`, `cloak_ecto`, `dns_cluster`, `ex_aws`, `ex_aws_s3`, `ex_json_schema`, `expo`, `gettext`, `hackney`, `metrics`, `mimerl`, `nimble_csv`, `parse_trans`, `pgvector`, `phoenix_ecto`, `sweet_xml`, `telemetry_metrics`, `telemetry_poller`, and `warpath`.

Prune them after confirming no release/runtime dependency still requires them.

### L-02 — Version metadata still identifies the application as `0.1.0`

`mix.exs:7` reports version `0.1.0`. This is not intrinsically unsafe, but production operations need a deliberate versioning/release policy tied to immutable image digests, migration compatibility, changelogs, and rollback support.

---

## Stub, TODO, and placeholder inventory

The requested unfinished-code scan found no explicit application `TODO`, `FIXME`, `HACK`, `XXX`, `NotImplemented`, or “not implemented” marker requiring completion. `.credo.exs:12-13` disables TODO/FIXME checks, so future markers will not fail lint.

One concrete placeholder/no-op implementation was found:

- `lib/acs/mcp/tools/error_handlers.ex:31-42` looks up a task and then executes the same `args` result whether the task exists or not. This is not harmless scaffolding; it causes **H-01** and must be replaced with tenant-scoped validation.

Several catch-all functions return `nil`, `[]`, `%{}`, or `:ok`; static review found them to be input fallbacks or disabled-feature behavior rather than confirmed stubs. They should not be labeled unfinished without contract-level evidence.

---

## Positive controls already present

- The release image is multi-stage and the runtime runs as non-root (`Dockerfile:31-95`).
- The image verifies the compiled database adapter and the entrypoint runs migrations before application startup.
- Production requires a database, `SECRET_KEY_BASE`, `MCP_API_KEY`, and host, and rejects the obvious default PostgreSQL password (`config/runtime.exs`).
- Phoenix forces TLS/HSTS and secure sessions; browser CSRF/security headers are present.
- Caddy disables buffering for SSE.
- Deployments serialize cutovers, use commit-derived application tags during normal flow, wait for container health, and provide rollback mechanics.
- A production release artifact assembled under placeholder audit configuration; this did not verify that the release or container boots successfully in production.
- Strict compilation and shell syntax checks passed.
- No obvious plaintext provider/cloud credential was observed in the files reviewed. No dedicated scanner command, scan output, or git-history scan is recorded in this audit, so this is not a verified clean secret scan.
- The test suite is substantial (604 tests), although it is not currently green and does not exercise production PostgreSQL.

## Recommended remediation sequence

1. **Emergency security:** fix C-01, H-01, H-03, H-04, H-05, reader mutation, and global ingest authorization.
2. **Restore a trustworthy gate:** resolve advisories/lock drift; make format, compile, Credo, dependency audit, tests, PostgreSQL integration, and image smoke required before deploy.
3. **Correct production behavior:** repair `ask`, tenant context propagation, PostgreSQL SQL, error returns, tool-registry execution, and SSE limits.
4. **Harden release operations:** verified DB TLS, explicit compatible migrations, pre-cutover public readiness, immutable signed images, resource limits, and required observability.
5. **Establish recoverability:** complete backups for all topologies, encrypted off-host retention, RPO/RTO, and a documented successful restore drill.
6. **Close quality gaps:** coverage, Dialyzer, E2E/auth route tests, Mix-task tests, deterministic global-state tests, and synchronized documentation.

A follow-up audit should rerun every command in this report, render all Compose variants, build and boot the production image against PostgreSQL, execute authenticated tenant-isolation/E2E tests, and attach evidence of a backup restore before changing the verdict.
