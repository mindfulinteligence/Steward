# Multi-repo scope context and org-wide knowledge blending — plan + implementation proposal

## Decision summary

Support multiple code repositories in one organization while keeping one shared knowledge base.

The system should not create hard walls between repositories. The intended behavior is gradual convention sharing:

- current-repository knowledge is ranked first;
- organization-wide knowledge is always eligible;
- other-repository knowledge is eligible at a lower rank and is clearly labeled;
- coding-agent and chat-agent memories share storage but retain origin provenance;
- explicit repository narrowing/widening remains available when an agent needs deterministic results.

This is **scope-aware blending**, not strict repository isolation.

## 1. Terminology and identity

A `repo` is a **declared project/repository name** (e.g. `steward_acs`, `acme-web`). It is not inferred from `scope_path` or `app`. Coding agents declare their working repo once, on install, in the coding system prompt (`Repo: <name>` in `AGENTS_STEWARD.md`), or via the `:coding_repo` application env / `ACS_CODING_REPO` env var.

| Concept | Meaning | Example |
|---|---|---|
| `repo` | Declared repository name | `steward_acs` |
| `scope_path` | Knowledge/code namespace | `acs/mcp/tools`, `acme/support/refunds` |
| `app` | Existing spec/application namespace | `steward_acs` |
| `origin` | How knowledge entered ACS | `coding_agent`, `chat_agent`, `system`, `imported` |
| `audience` | Retrieval audience and compatibility field | `coding`, `chat` |

`repo` is not derived from the first segment of `scope_path`. Code scopes, skill scopes, and business scopes use different namespaces.

## 2. Working-context handshake (first-lock authority)

The agent may call `get_started` at session start, but the authoritative working context is established by the first successful file lock. This prevents the ACS server checkout or stale prompt context from silently determining where an agent is working.

1. On install, the coding system prompt (`AGENTS_STEWARD.md` in the repo root, or `priv/prompts/coding_system_prompt.md` fallback) declares `Repo: <name>`.
2. The agent must confirm that the discovered checkout is the intended working repository, then the first `lock_file` call must include `repo` and `repo_confirmed: true` when the task has no repo yet. ACS persists it on the task and binds it to the MCP session and agent fallback context.
3. Later locks on the task must match the established repo; mismatches are rejected.
4. `get_started` remains useful guidance, but authenticated session repo and task repo take precedence for saves and retrieval.
5. Agents never invent a repo name; if no repo exists, or the discovered repo has not been confirmed, the first lock fails with an actionable request to provide and confirm `repo`.
6. Saves stamp `repo` from locked task/session context; unknown context is not silently converted into a repository.

Context rules:

- `repo` is session/task-derived; missing context does not silently guess a repository — it falls back to org-wide (`repo: nil`);
- a task cannot span repositories after its first lock; a second repository is rejected rather than weakening the lock boundary.

## 3. Shared data model

Added optional fields to memories, specs, skills, and all three vector indexes:

- `repo` — nullable; nil means organization-wide/non-repository knowledge;
- `origin` — `coding_agent | chat_agent | system | imported`, defaulted from `audience` at save.

Use `repo` for retrieval and `origin` for provenance. Do not split coding and chat memories into separate stores.

For existing fields:

- retain `audience` for retrieval compatibility;
- coding saves default `origin: coding_agent`;
- chat saves default `origin: chat_agent`;
- Anantha backfill defaults existing memories to `coding_agent`, `repo: nil` (no guessing from `scope_path`);
- explicit caller values cannot forge a different `origin` or `repo`; ACS derives them from authenticated context.

Memory IDs include `repo` (when present) in the hash source: `md5("#{scope_path}|#{repo}")`, so identical titles and scopes in different repos do not collide. Legacy IDs remain stable because the hash is unchanged when `repo` is nil.

## 4. Retrieval and blending contract

Every retrieval surface accepts the same repo context:

- `repo` — filter to exactly one repo (`:exact` semantics);
- `current_repo` — caller's repo, used for ranking and labels;
- `repo_mode` — `local | exact | blended` (default blended);
- `origin`, `audience`, `scope_path`, ABAC filters unchanged.

Default coding ranking (blended):

1. exact current `repo`;
2. `repo: nil` organization-wide knowledge;
3. other repositories, labeled `repo: <name>` and ranked lower.

Labeling rule: results are labeled `repo:` **only when they come from a different repo** than the caller's current repo — same-repo results are unlabeled to avoid noise.

`repo_mode`:

- `local`: current repo + org-wide only;
- `exact`: only the requested/current repo;
- `blended` (default): current repo first, then org-wide and other repos (down-ranked).

The "high match" behavior is intentional but observable: cross-repo results carry `cross_repo: true` and a repo score, and are never treated as same-repo. Cross-repo blending is a relevance decision, not a permission bypass.

## 5. Search metadata coverage

- `Indexer` persistence and list/search queries carry `repo`/`origin`; `apply_repo_filter/2` enforces `repo` / `repo_mode: :exact` / `repo_mode: :local` narrowing.
- `HybridSearch` scoring adds a `repo` component (`compute_repo_score/3`): requested-repo 1.0, current-repo 1.0, org-wide 0.6, other-repo 0.2, unknown context 0.5. Default blend weights: `0.25*semantic + 0.15*lexical + 0.25*scope + 0.10*metadata + 0.15*audience + 0.10*repo`.
- Result envelopes include `repo`, `origin`, `cross_repo`.
- Guidance packets surface the session repo (`repo` + `repo_hint` when undeclared) and blended ranking for coding guidance.

## 6. Repository catalog

`Acs.Repos` is a normalization/context module:

- resolve declared repo from the coding prompt (`Repo:` line), `:coding_repo` config, or `ACS_CODING_REPO`;
- `repo_for_file_path/1` extracts the app directory before `lib/` in a path;
- `repo_for_scope/1` takes the first scope segment (display/derivation only, never identity);
- `list/0` unions observed spec apps, memory repos, and skill scope prefixes;
- `normalize/1` canonicalizes names.

No manual registry is required. Repository identity is the declared name, not an inferred catalog.

## 7. Backfill and migration

- New migration `20260808000000_add_repo_and_origin_to_acs_memories.exs` adds `repo`/`origin` string columns to `acs_memories`.
- Anantha existing memories backfill: `origin: coding_agent`, `repo: nil` — do not guess a repository from `scope_path`.
- Backfill is idempotent and reports counts.

## 8. Implementation order (as built)

1. `Acs.Repos` normalization module + repo surfaced via existing `get_started`.
2. `Repo:` declaration added to `AGENTS_STEWARD.md` and `priv/prompts/coding_system_prompt.md`.
3. `repo`/`origin` fields on the memory struct, YAML serialization, schema, changeset, migration.
4. First-lock authority: `repo` is persisted on the task and MCP session; `origin` remains derived from `audience`.
5. Repo-aware indexing (`apply_repo_filter/2`) and `HybridSearch` repo scoring + labels.
6. Retrieval labels (`repo` only on cross-repo results) + `repo_mode`/`repo` opts on `query_memories`.
7. Guidance packets: repo line, `repo_hint` when undeclared, multi-repo task warning repeated several times.
8. Tests: repo scoring/labels, repo filter, `Acs.Repos` unit tests.
9. Backfill existing data.
10. End-to-end verification, including first-lock establishment and mismatch rejection.

## 9. Acceptance tests

At minimum test:

- coding `get_started` returns the declared repo (or the ask-the-human hint);
- first `lock_file` establishes task/session repo and subsequent mismatches fail;
- first `lock_file` requires explicit confirmation that the discovered checkout is the intended repository;
- saves stamp `repo` and `origin`; IDs do not collide for identical titles across repos;
- missing context falls back to org-wide data without inventing a repo;
- task repo mismatch is rejected after first lock;
- `local`, `exact`, and `blended` modes produce the documented ranking;
- cross-repo results are labeled, same-repo results are not;
- coding and chat origins remain distinguishable in one shared store;
- ABAC filters apply before lexical and vector results are returned;
- backfill is idempotent and restartable.

## Explicitly out of scope

- hard per-repository ABAC walls;
- per-repository MCP endpoints/connectors;
- hard repository isolation; first-lock task scope is enforced, while retrieval intentionally blends by default;
- UI repository management beyond diagnostics;
- inferring repository identity from scope-path segments;
- pgvector/SQLite parity (both now carry repo/origin filter metadata);
- specs and skills retain repo/origin metadata in their stores and semantic indexes, with the same exact/local/blended filtering contract as memories.
