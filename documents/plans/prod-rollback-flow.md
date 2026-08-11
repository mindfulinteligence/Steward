# Plan: Prod rollback flow with user confirmation

## Decision summary

When a breaking bug ships to prod, recover quickly to the last good version — but only after the agent explicitly asks the user and waits for approval. Execution stays on the canonical GitHub Actions path (same as deploys), with a confirmation-gated local script as the SSH fallback.

Mechanics already existed (`scripts/deploy.sh --rollback` pins `ACS_IMAGE_TAG_PREV` and does a blue/green cutover). This plan adds the missing pieces: a confirmation gate, a GitHub Actions rollback trigger, and a codified agent procedure.

## Why

- `deploy.sh --rollback` was SSH/laptop-only and documented only as "break-glass" in the `deployment` skill — no agent instruction to ask the user first.
- The GitHub Actions workflow had no rollback input, so the canonical deploy path had no matching recovery path.
- DB migrations are forward-only (Neon) — rollback is code/image-level only, and agents must surface that limitation.

## Changes

1. **`scripts/rollback.sh`** (new) — reads current/prev tag + slot from the host `.env`, prints the plan, and requires either an interactive `y` or `CONFIRM=yes` before running `deploy.sh --rollback` and a post-rollback `/mcp/health` smoke. Mirrors `deploy.sh` env conventions (`SERVER`, `REMOTE_DIR`, `COMPOSE_FILE`, `PUBLIC_URL`).
2. **`.github/workflows/deploy.yml`** — new `rollback` boolean dispatch input. When true: `build-push` and `cutover` are skipped; a new `rollback` job SSHes and runs `scripts/rollback.sh` with `CONFIRM=yes`. Added `scripts/rollback.sh` to the `push` path filter.
3. **`priv/skills/orgs/default/prod-rollback.md`** + `skill_save` — the agent procedure: confirm bug → identify tags → **ask user (blocking)** → execute → verify → report. Includes the confirmation gate wording, failure recovery, and common failures.
4. **`priv/skills/orgs/default/deployment.md`** + `priv/skills/deployment.md` — updated to point rollbacks at the `prod-rollback` skill and the `rollback: true` dispatch; added the new input to the workflow_dispatch list.

## Acceptance tests

- `bash -n scripts/rollback.sh` passes; without `CONFIRM=yes` it prompts and blocks, with `CONFIRM=yes` it performs the same cutover as `deploy.sh --rollback`.
- A `workflow_dispatch` with `rollback: true` runs the `rollback` job, skips `build-push` and `cutover`, and errors clearly if `ACS_IMAGE_TAG_PREV` is missing on the host.
- `prod-rollback` skill is retrievable via `skill_get(name: "prod-rollback")`; `deployment` skill references it.
- Normal deploys (push to prod / dispatch with `rollback: false`) are unaffected.

## Out of scope

- Fixing the live agent-identity-rotation bug on prod (separate task; this flow is what you'd use for it).
- DB schema rollback (forward-only by design).

## Verification notes

- Real rollback execution requires SSH to the prod host (port 22 is blocked from this sandbox) or the GitHub Actions `rollback` dispatch — verify on the remote working instance per `guides/development-workflow.md`.
