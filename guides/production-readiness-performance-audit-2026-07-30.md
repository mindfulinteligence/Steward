# Production readiness and performance audit

**Audit date:** 2026-07-30

**Audited revision:** `a8265dfd682cfe3b469d4b3eebbe812acd189a2f`

**Scope:** Phoenix/Elixir application code, authentication and authorization, tenant boundaries, MCP/API transports, persistence and migrations, ETS/GenServer state, filesystem-backed stores, production configuration, Docker/Compose, CI/deployment, observability, tests, dependencies, and documented feature surface.

**Method:** Static code review plus local compilation, tests, formatting, Credo, and Hex advisory checks. No production traffic, production data, load test, query plans, Docker daemon, live deployment, or restore environment was available.

## Executive verdict

**Not production-ready. Do not promote the current revision to an unattended or internet-facing production environment.**

The release has one confirmed critical authentication defect, multiple high-severity security and availability risks, known vulnerable locked dependencies, a deployment workflow that is not gated on CI, and a currently failing test/quality baseline. Performance findings are confirmed code paths but are not load-test measurements; their real-world thresholds still need benchmarking with representative tenant sizes and concurrency.

### Release blockers

1. **Critical:** whenever browser OIDC is unavailable, basic login deterministically uses checked-in `admin/admin`; the advertised environment overrides are ignored.
2. **High:** locked Phoenix, Bandit, Hackney, and Postgrex packages have published advisories; two advisories are denial-of-service issues in the web stack.
3. **High:** production cutover can run independently of failing or incomplete CI.
4. **High:** database TLS can be plaintext or silently fall back to `verify_none`; the release image does not explicitly install/guarantee a CA bundle.
5. **High:** the pre-authentication rate limiter trusts attacker-controlled API-key values and paths, allowing bucket rotation and global limiter exhaustion.
6. **High:** the full test suite is red (604 tests, 7 failures, 4 excluded), formatting is red, and strict Credo is red.
7. **High:** production PostgreSQL behavior is not tested even though CI starts PostgreSQL; test configuration remains SQLite.
8. **High:** core growth paths are unbounded and/or globally amplified: task/member reads, all-tenant ETS scans, global PubSub refreshes, per-log DB tasks, and SSE sessions.

## Findings summary

| ID | Severity | Area | Finding |
|---|---|---|---|
| SEC-1 | Critical | Authentication | Basic login is fixed to `admin/admin` whenever OIDC is unavailable |
| SEC-2 | High | Rate limiting | Unauthenticated callers can rotate limiter identities and exhaust global state |
| SEC-3 | High | Database transport | TLS is optional and CA failure downgrades verification |
| SEC-4 | High | Credential lifecycle | Removed administrators retain independently minted admin MCP keys |
| SEC-5 | Medium | Authorization | Direct task APIs bypass centralized role policy |
| SEC-6 | Medium | Tenant integrity | One global log-ingestion key can write to any host-selected tenant |
| SEC-7 | Medium | SSRF | DNS validation and connection are separate, leaving rebinding risk |
| SEC-8 | Medium | Secrets | Required admin MCP key has no strength validation |
| SUP-1 | High | Dependencies | Locked packages have active security advisories |
| OPS-1 | High | Deployment | Production cutover is not gated on CI success |
| OPS-2 | High | Test fidelity | PostgreSQL service is unused by the SQLite-configured tests |
| OPS-3 | High | Schema changes | Blue/green startup migrations can break the old serving slot |
| OPS-4 | High | Readiness | Health checks only database reachability while initialization is asynchronous |
| OPS-5 | High | Recovery | Repository-controlled backup is manual/host-local and no restore automation is present |
| OPS-6 | Medium | Supply chain | Images and one direct dependency constraint are floating |
| PERF-1 | High | Logging | Each log can spawn a task, insert one DB row, and scan ETS retention |
| PERF-2 | High | Queries | Unbounded reads and indexes do not match common tenant sort/search paths |
| PERF-3 | High | Shared state | All-tenant ETS scans and global PubSub cause cross-tenant amplification |
| PERF-4 | High | SSE | No session quota, lifetime, mailbox backpressure, or O(1) disconnect cleanup |
| PERF-5 | High | Workers | In replicated deployments, every node repeats reconciliation, embedding, auditing, and watching |
| PERF-6 | High | Tool registry | One synchronous GenServer is the control plane for all tenants |
| PERF-7 | Medium | External auth | Sequential/synchronous remote auth and non-single-flight JWKS refresh block requests |
| API-1 | Medium | Public contract | README advertises MCP tools that do not exist |
| API-2 | Low | Documentation | README points to a nonexistent example directory |
| API-3 | Low | Configuration | Stale `Acs.Cognition.Loader` config references a nonexistent module |

## Detailed security findings

### SEC-1 — Critical: basic browser authentication is fixed to `admin/admin`

**Evidence**

- `config/config.exs:48-53` configures `basic_auth: [username: "admin", password: "admin"]`.
- `config/runtime.exs:430-437` configures OIDC fields but does not replace or invalidate basic auth and never reads `ACS_USERNAME`/`ACS_PASSWORD`.
- `lib/acs_web/controllers/user_session_controller.ex:19-31` accepts username/password whenever `oidc_config/0` returns nil.
- `lib/acs_web/controllers/user_session_controller.ex:212-242` returns nil unless multi-tenant OIDC is both enabled and fully configured.
- `lib/acs_web/controllers/user_session_controller.ex:328-365` defaults again to `admin/admin`, logs a warning claiming environment overrides are available, and creates/returns a local organization owner.

**Failure scenario:** whenever OIDC is unavailable—disabled, single-tenant, or partially configured—the application deterministically authenticates the checked-in `admin/admin` pair. The advertised `ACS_USERNAME`/`ACS_PASSWORD` settings in Compose currently have no effect. A remote user submits the public defaults and receives an owner session.

**Required remediation:** make browser auth mode explicit and fail startup when its complete configuration is absent. Never fall back from incomplete OIDC to basic auth. If production basic auth remains supported, actually load runtime-only strong credentials and reject defaults/placeholders.

### SEC-2 — High: rate-limit bypass and shared-store exhaustion

**Evidence**

- `lib/acs/mcp/http_server.ex:25-29` applies rate limiting before authentication.
- `lib/acs/mcp/plugs/rate_limit.ex:52-66` uses any supplied `x-api-key` plus the raw request path as the bucket key.
- `lib/acs/mcp/rate_limit_store.ex:8,26-35` caps shared state at 100,000 entries.
- Dashboard login also uses the shared limiter store (`lib/acs_web/plugs/login_rate_limit.ex:19-21`).

**Failure scenario:** an unauthenticated client rotates fake key values and paths, always receiving a fresh bucket. Filling the table denies new buckets, including dashboard login buckets.

**Required remediation:** add an unavoidable pre-auth limiter keyed by trusted client IP and a small route class; add a post-auth limiter keyed by validated credential identity. Never key pre-auth state by unverified headers or arbitrary paths. Use shared/distributed enforcement if the service is replicated.

### SEC-3 — High: production database TLS can be absent or unauthenticated

**Evidence**

- `config/runtime.exs:102-111` enables SSL only for `PGSSL=true` or recognized URL strings; other remote production databases can use plaintext.
- `config/runtime.exs:118-136` explicitly falls back to `verify: :verify_none` when no CA certificates are available.
- `Dockerfile:70-77` does not explicitly install `ca-certificates`; because the image was not built/inspected during this audit, the runtime CA contents are unknown and not guaranteed by the Dockerfile.

**Required remediation:** explicitly install/guarantee a CA bundle, require verified TLS for non-local production PostgreSQL, and fail startup rather than downgrading verification. Add a release-container integration test that rejects an untrusted test CA.

### SEC-4 — High: administrator offboarding does not revoke minted admin keys

**Evidence**

- `lib/acs_web/live/acs_live/settings_live.ex:15-23,84-107` allows owners/admins to create MCP admin keys.
- `lib/acs/developers/developer_api_key.ex:13-23` has no creator membership or expiry.
- `lib/acs/accounts.ex:484-526` demotes/removes users and revokes browser sessions, but does not revoke developer keys they created.

**Required remediation:** bind personal keys to the issuing user/membership, restrict admin-key issuance appropriately, add expiry, and revoke linked keys transactionally on role change/removal.

### SEC-5 — Medium: direct task APIs bypass role policy

`lib/acs/mcp/http_server.ex:398-468` authenticates but does not authorize `POST /api/tasks` or `PATCH /api/tasks/:id`. This differs from centralized role rules in `lib/acs/mcp/core_tool_roles.ex:37-47,92-96`; a reader credential can mutate tasks through the direct route. Route these actions through the same authorization policy and add reader-denial tests.

### SEC-6 — Medium: global log-ingestion credential is not tenant-bound

`config/runtime.exs:194-195` defines one application-wide key. `lib/acs/mcp/plugs/mcp_auth.ex:211-240` accepts it, while `lib/acs_web/plugs/resolve_org.ex:26-45` derives the organization from the request host. A valid ingestion client can target another tenant hostname and inject logs. Use per-tenant hashed credentials and require credential-org/host-org equality.

### SEC-7 — Medium: DNS rebinding remains possible for outbound bridge calls

`lib/acs/mcp/url_safety.ex:92-133` resolves and checks a hostname, but `lib/acs/mcp/bridge.ex:254-280` later lets the HTTP client resolve again. Redirect blocking is a good control, but it does not remove the DNS time-of-check/time-of-use gap. Require a production allowlist, pin the validated address while preserving Host/SNI, and enforce network-level egress denial for private/link-local/metadata ranges.

### SEC-8 — Medium: admin MCP secret accepts weak values

`config/runtime.exs:164-187` requires only a nonempty `MCP_API_KEY`; `lib/acs/mcp/plugs/strategies/default.ex:8-19,44-47` grants it admin. Trim and validate length/entropy, reject placeholders, and document generation from at least 32 random bytes.

## Dependency and supply-chain findings

### SUP-1 — High: advisory-affected locked dependencies

`mix hex.audit` failed with the following locked packages:

- `bandit 1.12.0` — **HIGH**, CVE-2026-65623 / GHSA-vg8x-66vg-5pxh: quadratic CPU blow-up reassembling fragmented WebSocket messages.
- `phoenix 1.8.8` — **HIGH**, CVE-2026-56811 / GHSA-6983-jfq8-485w: unbounded channel joins can exhaust processes.
- `phoenix 1.8.8` — **MEDIUM**, CVE-2026-56812 / GHSA-63mc-hw7g-86rr: JavaScript Presence crash on special keys.
- `hackney 1.25.0` — **HIGH**, CVE-2026-47071, plus medium/low CRLF/SSRF/cookie advisories CVE-2026-47075, CVE-2026-47076, and CVE-2026-47069.
- `postgrex 0.22.2` — **LOW**, CVE-2026-58225 / GHSA-4mw9-4qgj-m97w: notification reconnect replay injection/denial of service.

The existing `guides/security-audit.md:34` says the affected HTTP/framework packages were updated and `mix hex.audit` is enforced in CI, but `.github/workflows/ci.yml` currently contains no advisory-audit step. Update dependencies to fixed releases, confirm whether Hackney is needed transitively, run regression tests, and make the audit a protected required check.

### OPS-6 — Medium: mutable supply-chain inputs

Examples include `elixir:1.17-alpine` (`Dockerfile:4,31`), `caddy:2-alpine`, `syncthing/syncthing:latest`, and `ollama/ollama:latest` (`docker-compose.multitenant.yml`). `req_llm` also uses an unbounded lower constraint in `mix.exs:51`, although `mix.lock` currently pins a version. Pin production images by digest, constrain direct dependencies to compatible ranges, generate an SBOM/provenance, sign images, and scan the final image.

## Operational readiness findings

### OPS-1 — High: deploy is not gated on CI

Both CI and Deploy trigger independently on `prod` pushes (`.github/workflows/ci.yml:3-7`, `.github/workflows/deploy.yml:40-59`). Deploy cutover depends only on its own image build/push job (`deploy.yml:68-116`), not on test, lint, release, or security jobs. A broken commit can deploy before or despite CI failure.

**Required remediation:** use one gated workflow or consume only a verified immutable artifact produced after required checks. Test the gate with a deliberately failing non-production commit.

### OPS-2 — High: tests do not exercise PostgreSQL

`config/test.exs:3,7-14` hard-codes SQLite. CI starts PostgreSQL and passes `DATABASE_URL` (`.github/workflows/ci.yml:13-26,55-58`), but that does not change the configured adapter; `postgrex` is production-only (`mix.exs:48`). PostgreSQL migrations, locking, pgvector, SQL syntax, pooling, and TLS can regress undetected.

Add a dedicated PostgreSQL integration environment that runs all migrations and targeted data/locking/health tests, plus a release-container boot smoke test.

### OPS-3 — High: blue/green schema compatibility is not enforced

Every new container runs all pending migrations before serving (`docker/entrypoint.sh:40-43`, `lib/acs/release.ex:7-12`) while the old slot still serves against the same database until traffic flips (`scripts/deploy.sh:267-303`). A non-backward-compatible migration can break the old version and make rollback ineffective.

Enforce expand/contract migrations, separate migration execution into an audited phase, and test old-app/new-schema and new-app/old-schema compatibility.

### OPS-4 — High: liveness is used as readiness

`/mcp/health` checks only `SELECT 1` (`lib/acs/mcp/http_server.ex:376-393`). Deployment and Docker use it as the cutover gate, but memory sync, embeddings, vector setup, and cache warmup run asynchronously after the endpoint starts (`lib/acs/application.ex:99-161`). Traffic can arrive while required initialization is incomplete or failed.

Define separate liveness and readiness contracts; track required initialization state and cut over only after readiness succeeds.

### OPS-5 — High: repository-controlled recovery is incomplete and unproven

`scripts/backup-prod.sh` delegates SQL recovery to Neon, archives a live vault without quiescing writers, and writes locally. The repository contains no scheduling, off-host retention, consistency mechanism, or automated restore verification. External Neon PITR, host scheduling, retention, and prior restore-drill configuration were unavailable and remain unknown. Establish RPO/RTO, verify and monitor Neon PITR, snapshot/quiesce vault writes, store encrypted off-host copies, and conduct recurring isolated restore drills.

### Additional operational gaps

- CI does not run formatting, coverage threshold, Hex advisory audit, SBOM generation, secret scanning, or image scanning (`.github/workflows/ci.yml`).
- Monitoring code exists, but externally enforced SLOs/alerts for readiness, restart loops, migrations, DB pool saturation, exporter drops, and backup freshness were not found.
- The existing security audit already notes shared multi-tenant Syncthing volume exposure and mutable images (`guides/security-audit.md:47-76`); these remain open.

## Performance and scalability findings

These are static risks, not measured incidents. Validate them with production-like row counts, `EXPLAIN (ANALYZE, BUFFERS)`, load tests, DB pool telemetry, ETS sizes, BEAM reductions, SSE mailbox lengths, and representative vaults.

### PERF-1 — High: logging amplifies work and competes with requests

- `Acs.MCP.LogStore` is always supervised (`lib/acs/application.ex:50-69`) and installs a Logger backend (`lib/acs/mcp/log_store.ex:50-61`).
- DB persistence defaults on and starts one unsupervised task per log, performing an individual insert (`lib/acs/mcp/log_store.ex:74-119`).
- Every ETS insert invokes retention trimming (`lib/acs/mcp/log_store.ex:123-143,528-553`).
- LiveView mount telemetry emits an info log per successful mount (`lib/acs/observability/live_view_metrics.ex:24-43`).

Under log bursts, process churn and one-row transactions contend with request queries for the same pool. Replace this with a bounded supervised queue, batched `insert_all`, periodic retention cleanup, explicit overload/drop policy, and queue/drop metrics.

### PERF-2 — High: unbounded lists and mismatched indexes

- Tenant task listing has no limit/cursor (`lib/acs/acs.ex:103-120`), while migrations provide only a standalone org index rather than `(org, inserted_at, id)` (`priv/repo/migrations/20260705000002_add_org_to_all_tables.exs:40-42`).
- Member and pending-invitation reads are unbounded (`lib/acs/accounts.ex:223-251`).
- `Indexer.list_memories/1` is unbounded when callers omit `:limit` (`lib/acs/memory/indexer.ex:312-344`).
- Memory search uses leading-wildcard `LIKE` over title/content/summary and then sorts (`lib/acs/memory/indexer.ex:412-459`); current indexes do not support this pattern.

Require server-side maxima and keyset cursors. Add indexes based on measured query plans. Use PostgreSQL full-text/trigram search (and SQLite FTS5 where relevant) instead of leading-wildcard scans.

### PERF-3 — High: all-tenant ETS and global PubSub amplify work

- Warmup loads every tenant's statuses, tasks, and locks on every node (`lib/acs/acs/cache.ex:117-188`).
- Tenant reads use `:ets.tab2list/1` and only then filter (`lib/acs/acs/cache.ex:263-275,315-325`).
- All broadcasts share the topic `"acs"` (`lib/acs.ex:19-22`), and multiple tenant LiveViews reload full collections after global events.

Partition PubSub topics by org, apply event deltas/debounce in LiveViews, use ETS match specifications keyed by `{org, id}`, and cache only active coordination records rather than all historical tasks.

### PERF-4 — High: SSE lacks quotas and slow-consumer control

- Every SSE request holds a process/socket in an indefinite receive loop with heartbeats (`lib/acs/mcp/http_server.ex:544-615`).
- `SSESessionManager` has no count/lifetime cap (`lib/acs/mcp/sse_session_manager.ex:42-61`).
- All sends pass through one GenServer; disconnect cleanup is O(active sessions) via `Enum.find`, and connection mailbox depth is unchecked (`lib/acs/mcp/sse_session_manager.ex:81-120`).

Add global/per-tenant quotas, idle/max-age limits, proxy admission limits, slow-consumer shedding, mailbox metrics, and O(1) reverse monitor lookup via ETS/Registry.

### PERF-5 — High: replicated deployments repeat background work on every node

Every instance starts auditors, sweepers, watchers, full memory sync, embedding reconciliation, and cache warmup (`lib/acs/application.ex:72-161`). With shared DB/vault storage, replicas multiply filesystem traversal and external embedding calls. Elect a single worker leader or use unique durable jobs, consolidate watchers, track file hashes/mtime, process incrementally, and supervise startup tasks with bounded concurrency.

### PERF-6 — High: global synchronous ToolRegistry

`lib/acs/mcp/tool_registry.ex:1-38` routes listing, lookup, authorization, refresh, and invocation through one named GenServer; invocation allows a 180-second call timeout. Keep mutations serialized but publish immutable read snapshots to ETS/`persistent_term`, and execute tools outside the registry under a bounded supervisor. Instrument callback latency and mailbox length before/after.

### PERF-7 — Medium: external authentication blocks request paths

Optional app auth probes configured applications sequentially with synchronous remote calls (`lib/acs/mcp/plugs/strategies/app_auth.ex:25-52`). JWKS refresh is synchronous and lacks single-flight behavior (`lib/acs/mcp/oauth/jwks.ex:104-160`). Route credentials directly, set explicit connect/receive/retry budgets, use circuit breakers, and implement safe single-flight/stale-while-revalidate JWKS caching.

## Stubs, placeholders, and dead ends inventory

A repository-wide production search found **no actionable TODO/FIXME/XXX/HACK markers, no `not_implemented`/`:unsupported` sentinel paths, no fake-success production handlers, and no routed no-op UI controls**. Tests, prompts that discuss placeholder detection, generated assets, and `archive/` were excluded. The confirmed dead ends are public-contract/configuration drift:

### API-1 — README advertises nine unavailable MCP tools

- `README.md:212` advertises `cognition_get`, `cognition_search`, `cognition_propose`, `cognition_approve`, `cognition_reject`, `cognition_list`, and `cognition_list_undocumented`.
- `README.md:215` advertises `refresh_tools` and `exec_command`.
- The complete category and dispatch registries (`lib/acs/mcp/tools.ex:14-63,932-989`) contain none of these tools.
- The implemented successor surface uses `specs_*` and `documents_*`; internal registry refresh at `lib/acs/mcp/tool_registry.ex:322` is not an MCP endpoint.

Update the README to the actual supported API or add intentional, tested compatibility aliases.

### API-2 — README example path does not exist

`README.md:199` directs users to `priv/acs_tools/`, but the repository has no such directory or YAML examples. Add a maintained example or point to the real supported location.

### API-3 — stale nonexistent module configuration

`config/dev.exs:47-48` configures `Acs.Cognition.Loader`, but no such module exists. The active implementation is `Acs.Specs.Loader`. Remove or migrate the stale key.

### Reviewed but intentional (not stubs)

- Fixed-client OIDC DCR in `lib/acs/mcp/oauth/dcr.ex:4-53` is explicitly designed to avoid dynamic client exhaustion and returns 503 when unconfigured.
- Self-service organization creation has a clear feature gate and disabled UI state (`config/runtime.exs:432`, `lib/acs_web/live/acs_live/onboarding_live.ex:94-97,512-665`).
- Optional email delivery and embedding fallback paths report disabled/unavailable behavior rather than pretending to succeed.

## Verification results

| Check | Result |
|---|---|
| `MIX_ENV=prod mix compile --warnings-as-errors` | **Passed** |
| `mix test` (second isolated run after audit exploration) | **Failed:** 604 tests, 7 failures, 4 excluded |
| `mix format --check-formatted` | **Failed:** multiple unformatted source/test/config files |
| `mix credo --strict` | **Failed:** one warning (`Acs.Specs.Entry` has 36 fields) |
| `mix hex.audit` | **Failed:** advisory-affected packages listed in SUP-1 (checked 2026-07-30T03:15:57Z against the advisory data returned by Hex at that time) |
| Tracked-baseline `git diff --check` | **Passed before the report was created; this did not inspect the then-untracked report** |
| Report trailing-whitespace check | **Passed after removing the detected Markdown line-end spaces** |

### Current test failures

The two full-suite seeds were `961413` (9 failures) and `253620` (7 failures). In the second run, five failures are in `Acs.MetaHarness.DocumentGeneratorTest` because `format_latency/1` expects `:p99_latency` (`lib/acs/meta_harness/document_generator.ex:229`). One failure is `Acs.MultiTenantSecurityTest` (`test/acs/multi_tenant_security_test.exs:111`), and one is `Acs.MetaHarness.RecentOpsTest` (`test/acs/meta_harness/recent_ops_test.exs:34`). The test output also repeatedly reports Ecto sandbox ownership errors from `Acs.MetaHarness.OperationLogger`/Generator paths. The differing counts show order/shared-state sensitivity; fix and repeatedly run with randomized seeds.

The four excluded tests require an external Ollama service. Production PostgreSQL, Docker Compose rendering/build, container startup, live Auth0, live Neon TLS, deployment cutover, load behavior, backup consistency, and restore were not verified in this environment.

## Strengths observed

- Tenant host resolution and credential-org matching generally fail closed for normal MCP/browser credentials.
- Production session cookies are Secure/HttpOnly/SameSite, browser routes use CSRF protection, and session tokens are random, hashed, and expiring.
- OAuth JWT verification pins RS256 and checks issuer, audience, signature, and expiry.
- Outbound URL validation blocks private/loopback ranges and redirects are disabled, reducing SSRF exposure.
- No application command-execution sink (`System.cmd`, `Port.open`, `:os.cmd`) was found.
- Developer API keys use 32 random bytes and are stored only as hashes.
- Release build checks that the compiled Repo adapter is PostgreSQL, and entrypoint failures stop startup.
- Blue/green deployment uses commit-addressed app image tags, health waiting, revision labels, and a rollback command.
- Test breadth is substantial; the principal gaps are a currently red baseline and insufficient production-environment fidelity.

## Remediation sequence

### Before any production promotion

1. Remove the `admin/admin` fallback and add production startup/auth regression tests.
2. Upgrade all advisory-affected dependencies and enforce `mix hex.audit` in protected CI.
3. Install CA certificates, require verified DB TLS, and test from the release container.
4. Fix rate-limit identity/cap exhaustion and direct API authorization.
5. Fix all tests, formatting, and strict Credo; make them required checks.
6. Gate deploy cutover on the verified immutable CI artifact.
7. Add PostgreSQL migration/integration and release-container smoke jobs.
8. Define real readiness and use it for cutover.

### Before scaling traffic or tenants

1. Batch and bound log persistence; add queue/drop/DB-pool telemetry.
2. Add keyset pagination and query-plan-driven indexes/search indexes.
3. Partition PubSub and ETS access by tenant; avoid full reloads.
4. Add SSE admission quotas, lifetimes, slow-consumer handling, and metrics.
5. Make reconciliation/auditing cluster-singleton and incremental.
6. Run production-like load tests and establish SLOs/alerts.

### Before claiming hardened operations

1. Complete and test expand/contract migration policy.
2. Implement scheduled, consistent, encrypted off-host backup plus restore drills.
3. Pin/sign/scan images and publish SBOM/provenance.
4. Resolve shared Syncthing tenant-volume isolation noted by the prior security audit.
5. Correct stale README/config dead ends and maintain an executable API contract test.
