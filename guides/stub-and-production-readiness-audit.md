# Stub and production-readiness audit

**Audit date:** 2026-07-31  
**Scope:** Active application code in `lib/`, web assets, runtime configuration, Docker/Compose, scripts, migrations, and CI. Test fixtures and `archive/` were excluded from findings. The `mcp-acs-bridge` Git submodule was not populated in this checkout, so its separate repository was not inspected.

## Executive summary

The main task, account, memory, skill, spec, and web workflows are implemented; this is not a generally scaffolded or placeholder application. Keyword searches also found no active `TODO`, `FIXME`, `XXX`, or `HACK` markers in production Elixir code.

The audit did confirm **two exposed diagnostic stubs**, **one misleading diagnostic fallback**, and **six broader production-readiness problems**. The most urgent deployment risks are the shared root-owned multi-tenant vault, mutable container images, and a TLS fallback that disables certificate verification. The clearest code stubs are `config_lookup/1` and the missing default diagnostic extension module.

### Finding count

| Category | High | Medium | Low |
|---|---:|---:|---:|
| Confirmed stubs / misleading placeholder behavior | 0 | 3 | 0 |
| Other production-readiness issues | 3 | 3 | 0 |
| **Total** | **3** | **6** | **0** |

## Confirmed stubs and placeholder behavior

### STUB-1 — `config_lookup` returns a hard-coded catalog and ignores its `key` input

**Severity:** Medium  
**Evidence:** `lib/acs/mcp/tools/diagnostic_handlers.ex:88-125`; exposed by `lib/acs/mcp/tools.ex:713-723,960`.

The MCP tool is described as a configuration lookup, but its handler:

- assigns `args["key"]` to `_key` and never uses it;
- does not read any configuration file or runtime configuration;
- always returns a fixed map of descriptions and paths;
- advertises `.opencode/agents.json`, `.opencode/skills/`, and `.opencode/plugins.yaml`, none of which exist in this checkout (the active `.opencode/` tree contains `command/` and `plugins/`).

This is a functional stub rather than a real lookup. A caller can receive a successful result containing stale or nonexistent paths.

**Recommendation:** Either implement lookup against an explicit allowlist of real, non-secret configuration values, including the documented `key` filter, or remove the tool until it has a truthful contract. Return an unsupported/error response rather than fabricated success data.

### STUB-2 — Diagnostic tools default to a module that does not exist

**Severity:** Medium  
**Evidence:** `lib/acs/mcp/tools/diagnostic_handlers.ex:132-137,367-385,680-687`; exposed by `lib/acs/mcp/tools.ex:725-755,961-962`.

`connection_diagnostic` uses `extension_module().fetch_llm_config/0`, and `memory_health_check` uses `extension_module().fetch_memory_stats/1`. Unless `:app_extension` is configured, `extension_module/0` returns `Acs.MCP.Tools.AppExtension.Default`.

No `Acs.MCP.Tools.AppExtension.Default` module exists in `lib/`, no runtime configuration installs another extension, and no test provides or exercises this contract. Therefore:

- `connection_diagnostic` crashes when asked to inspect `llm` or `all`;
- `memory_health_check` crashes on every default invocation;
- the fallback is a missing implementation, not a usable default.

**Recommendation:** Add a real default implementation backed by `Acs.LLM` and local repositories, or fail explicitly with `{:error, :diagnostic_extension_not_configured}`. Define a behaviour for extension implementations and add contract tests for default and configured paths.

### STUB-3 — Log database health reports fabricated zeroes on every exception

**Severity:** Medium  
**Evidence:** `lib/acs/mcp/tools/diagnostic_handlers.ex:661-674`.

`collect_log_db_stats/0` rescues every exception and returns a healthy-looking all-zero structure. A missing table, lost database connection, query defect, or programming error is therefore indistinguishable from a genuinely empty log database.

This is placeholder-like fallback behavior in a health diagnostic: it suppresses the exact condition the tool is intended to reveal.

**Recommendation:** Return an explicit degraded/error state with a sanitized reason, and include it in the health score. Rescue only expected startup/schema errors if they truly need special handling.

## Other non-production-worthy code and operational risks

### PROD-1 — TLS certificate verification is disabled when the runtime has no CA store

**Severity:** High  
**Evidence:** `config/runtime.exs:124-139`.

For SSL database connections, the application uses `verify: :verify_peer` when CA certificates are available, but silently falls back to `verify: :verify_none` otherwise. Encryption without peer verification permits man-in-the-middle attacks and should not be an accepted production mode.

**Recommendation:** Ensure the release image contains a CA bundle and fail startup when peer verification cannot be configured. Remove the `verify_none` production fallback.

### PROD-2 — Every Syncthing tenant runs as root against the same vault volume

**Severity:** High  
**Evidence:** `docker-compose.multitenant.yml:1-10,155-193`.

All four tenant-specific Syncthing containers run as root and mount the same `vaults` volume. A compromised or misconfigured tenant container can access other tenants' files. This was also identified in `guides/security-audit.md` and remains unresolved.

**Recommendation:** Allocate a distinct named volume per tenant, run each service under a fixed unprivileged UID/GID, and perform a tested data migration before changing mounts.

### PROD-3 — Production containers use mutable image tags

**Severity:** High  
**Evidence:** `docker-compose.multitenant.yml:7,22,138`; `Dockerfile:4,26,68`.

Syncthing and Ollama use `latest`; Caddy and all Dockerfile base images use mutable tags rather than digests. The ACS image defaults to the mutable `multitenant` tag when `ACS_IMAGE_TAG` is omitted. A rebuild or restart can therefore deploy different, unreviewed bits under the same configuration.

**Recommendation:** Pin all runtime and build images by digest, require a commit-addressed ACS image tag, and add image scanning, SBOM/provenance generation, and signature verification.

### PROD-4 — Durable log persistence intentionally discards all failures

**Severity:** Medium  
**Evidence:** `lib/acs/mcp/log_store.ex:65-118`.

Database persistence is launched with unsupervised `Task.start/1`. Error tuples, exceptions, and exits are all converted to `:ok` without a metric, counter, warning, retry, or dead-letter path. ETS continues to serve recent logs, so durable history can be lost invisibly.

Avoiding recursive Logger calls is reasonable, but complete suppression leaves no independent signal that persistence is broken.

**Recommendation:** Use a supervised bounded queue or batch writer with retry/backoff and a non-Logger failure metric/health flag. Expose dropped-write counts in diagnostics.

### PROD-5 — Boot initialization relies on unsupervised tasks and timing sleeps

**Severity:** Medium  
**Evidence:** `lib/acs/application.ex:103-163`.

Memory synchronization, embedding table setup, embedding generation, and cache warmup are started using four unlinked `Task.start/1` processes. Three use fixed sleeps (`100`, `200`, or `300` ms) as ordering. Failures are not restarted by the application supervisor, and fixed delays do not establish dependency readiness.

This can leave a running, apparently healthy node with incomplete indexes or an unwarmed cache after a transient startup error.

**Recommendation:** Move initialization into supervised workers with explicit dependencies, retry/backoff, idempotent readiness checks, and observable status. Include required initialization in readiness rather than relying on elapsed time.

### PROD-6 — CI and the existing audit claim do not match

**Severity:** Medium  
**Evidence:** `.github/workflows/ci.yml:53-56,120-123`; `.credo.exs:13-14`; `guides/security-audit.md:49-56`.

The security audit says `mix hex.audit` and `mix deps.unlock --check-unused` are enforced in CI. The active CI workflow runs compilation, tests, strict compilation, and Credo, but contains neither dependency check. It also does not perform secret scanning, container scanning, Compose validation, or shell linting. Credo explicitly disables its TODO and FIXME checks.

This does not create a runtime stub, but it permits placeholder markers and dependency drift to enter production while documentation says those controls are enforced.

**Recommendation:** Add the stated dependency checks to CI, enable TODO/FIXME checks (or enforce an equivalent policy), validate production Compose, lint shell scripts, and add secret/image scanning. Update `guides/security-audit.md` whenever the enforced gate changes.

## Deployment limitation worth documenting

`scripts/backup-prod.sh` backs up vault data and legacy SQLite data, but explicitly delegates the production Neon/PostgreSQL database to manual Neon PITR/export. There is no repository-controlled database backup or restore verification. This is not a code stub, but production readiness remains conditional on an externally configured and tested database recovery process.

## Reviewed items that are not stubs

The following suspicious search results were inspected and should not be treated as findings:

- `nil`, `[]`, `false`, and `:ok` catch-all clauses are predominantly validation defaults, optional-value normalization, fail-closed authorization, or idempotent APIs.
- `Acs.ClaimContext` empty-list clauses handle invalid inputs; the valid scope and file-path branches perform real spec searches and loads.
- `ToolRegistry.list_tools_mcp(_, _, _, _) -> []` rejects malformed identity/org inputs and is fail-closed.
- Invitation email delivery is intentionally optional and returns `:disabled`; copy-link invitations remain a documented product mode.
- SQLite no-op migrations are adapter-specific compatibility paths, not missing PostgreSQL behavior.
- HTML `placeholder=` attributes and generated JavaScript `noop` callbacks are normal UI/library behavior.
- Hard-coded tool guidance is an intentional offline fallback, not fake runtime data.
- Test mocks, fake embeddings, and placeholder test documents are confined to `test/`.
- The compile-time `SECRET_KEY_BASE` dummy in the Dockerfile is paired with a production runtime requirement for a real secret.

## Suggested remediation order

1. **Before the next production deployment:** remove TLS `verify_none`; isolate tenant vaults; pin production images.
2. **Before advertising diagnostics as supported:** implement or remove the default app extension and replace `config_lookup` with a real, allowlisted lookup.
3. **Reliability hardening:** make health failures explicit, supervise startup jobs, and instrument/retry durable log writes.
4. **Release governance:** make CI match the documented security gates and establish a tested database restore procedure.

## Audit method and limitations

The review combined repository-wide marker searches, trivial-return and broad-rescue searches, manual tracing of suspicious handlers to their MCP registrations, configuration/deployment inspection, and comparison with the existing security audit. This was a static audit; it did not invoke external Auth0, Neon, Axiom, Resend, Ollama, Syncthing, or unpopulated submodule services. No claim is made about externally mounted MCP YAML definitions or tenant vault contents, which are not present in the repository.
