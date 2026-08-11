---
description: "Roll back a Steward ACS production deploy to the last good image tag after a breaking bug, but only after explicitly asking the user for confirmation."
name: "prod-rollback"
proposed_by: "nahar emet"
scope_paths: ["steward_acs/production", "guides/deployment"]
status: "approved"
tags: ["deployment", "ops", "rollback", "prod"]
when_to_use: "Use when a breaking bug or regression is live in prod and you need to quickly return to the last known-good version."
audit_reasoning: "This is an exemplary skill. It is highly actionable with clear, numbered steps, includes a mandatory confirmation gate, and provides concrete command examples and file paths. The prerequisites, verification, and failure recovery sections are thorough and address realistic edge cases. The description is distinct and accurately summarizes the skill's purpose and constraints. The audience fit is perfect for a coding agent, with specific tool references (GitHub Actions, SSH, scripts) and technical details. It is unique and not a duplicate of existing skills."
audit_score: 10
audit_status: "ok"
audited_at: "2026-08-10T12:08:53.027416Z"
approved_at: "2026-08-10T12:08:53.034058Z"
approved_by: "llm"
reviewed_at: "2026-08-10T12:08:53.034058Z"
reviewed_by: "llm"
---

# Prod Rollback

## When to use

Use this when a breaking bug or regression has been deployed to prod and the fast recovery is to roll back to the last good image tag. Do **not** use for routine deploys — that is the `deployment` skill.

## Prerequisites

- Work from the `dev` branch unless the user explicitly asks to deploy/promote.
- Load the `deployment` skill or `guides/deployment.md` first.
- Load `prod-outage-triage` first if the report is an outage without an identified cause.
- Do not print secret values from `.env` or Infisical.
- Confirm the prod host and its deploy details (GitHub Environment secrets: `DEPLOY_HOST`, `DEPLOY_USER`, `REMOTE_DIR`, `PUBLIC_URL`).

## The confirmation gate (mandatory)

**You must ask the user before executing any rollback.** Present the exact plan (current tag → prev tag), wait for an explicit "yes", and do not proceed until the user approves. Use wording like:

> Prod has a breaking bug on tag `<current>`. I can roll back to the previous tag `<prev>` via a blue/green cutover (~a few minutes, DB migrations are not rolled back). Shall I proceed? [y/N]

- Proceed only on explicit user approval.
- If the user says no, stop and report the bug details so a forward fix can be scheduled.
- If the user is unreachable and you have standing break-glass authorization, state that assumption before proceeding.

## Steps

1. Create and claim an ACS task for the incident (`create_work`, then `claim_work`).
2. Confirm the current branch with `git branch --show-current`; stop and ask if it is not `dev`.
3. Identify the current and previous tags with read-only host status:
   ```bash
   SERVER=ubuntu@HOST ./scripts/status.sh
   ```
   Look for `env_has_ACS_IMAGE_TAG`, `env_has_ACS_IMAGE_TAG_PREV`, `acs_active_slot`, and `image_git_sha`.
4. Verify the bug is really a regression from the latest deploy: check public health (`curl -i --max-time 15 https://prod.stewardacs.xyz/mcp/health`), error traces, and confirm the current image tag matches the failing deploy.
5. **Ask the user for confirmation** (see the gate above) and wait for an explicit yes.
6. Execute the rollback. Prefer GitHub Actions so no laptop is required:
   - Open the **Deploy** workflow → *Run workflow* → environment `prod`, **rollback: true**.
   - The workflow skips the build and runs `scripts/rollback.sh` on the host with `CONFIRM=yes`.
   - Or, if you have SSH access: `CONFIRM=yes SERVER=ubuntu@HOST ./scripts/rollback.sh`. Interactive fallback without `CONFIRM=yes` prompts for a yes/no.
7. Verify the rollback:
   ```bash
   SERVER=ubuntu@HOST ./scripts/status.sh
   curl -i --max-time 15 https://prod.stewardacs.xyz/mcp/health
   ```
   Expect the active container to run the previous image tag and `/mcp/health` to return 200 with `"database":true`.
8. Report the result to the user: which tag was rolled back, the new active slot/container, health status, and a note that a forward fix is still needed.

## Verification

- The active slot image ref (`image_ref` in `status.sh`) points at the previous tag.
- Public `/mcp/health` returns 200 with `"database":true`.
- `deploy.sh` post-cutover smoke passed (or `SKIP_SMOKE=1` only in a break-glass case).
- The user was asked first and explicitly approved.

## Failure recovery

- `ACS_IMAGE_TAG_PREV` is missing on the host → nothing to roll back to. Report it; do not guess a tag. Check whether the failing deploy was the very first one.
- Rollback image fails health checks → `deploy.sh` aborts before Caddy cutover, leaving traffic on the buggy version. Do not force another rollback blindly; investigate the previous tag (missing dependency, migration incompatibility) and escalate.
- DB schema was changed by the buggy release → DB migrations are forward-only (Neon). Code rollback does not undo schema changes; if the previous version cannot start against the new schema, surface this to the user and plan a forward fix instead.
- Post-rollback health check fails → the cutover may still be in progress; re-run `scripts/status.sh` and the health probe before declaring failure.

## Common failures

- Confusing a new deploy with a rollback: a rollback reuses the previously pushed image tag and does **not** build. The `rollback: true` dispatch skips `build-push`.
- Forgetting the confirmation gate: never run `CONFIRM=yes ./scripts/rollback.sh` or `deploy.sh --rollback` without prior user approval.
