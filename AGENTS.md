Check if `@AGENTS_STEWARD.md` exists. If yes, follow the instructions there. If not, ignore this line.

**Do not do work without a task.** Create or claim one in ACS immediately when asked to do anything.

**Do not finish without releasing + feedback.** Always call `steward_release_work` and `steward_submit_task_feedback` before declaring done.

**Git:** stay on `dev` for all work — commit/push there only. Never create or switch branches. Promote `dev` → `prod` only when the user asks to deploy. If not on `dev`, ask — do not switch yourself.

**Save what you produce:** after coding tasks touching `/lib/`, propose or update the module spec (`specs_propose` purpose/invariants/workflows); after a repeatable procedure, save a skill (`skill_save`); after working out a plan with the user, save it as a document under `documents/plans/<slug>`; run `query_specs(undocumented: true)` to find modules missing specs. See the `steward_get_started` guidance packet for the store decision.

**Keep the public docs current:** `/docs` is compiled from `README.md`, `guides/`, and `priv/skills/steward-installer.md`. Any change to installation, behavior, configuration, deployment, or testing must update the matching source document in the same task.

## Guides

Project-specific workflows live in `guides/`. Check them before starting work:

- [`guides/development-workflow.md`](guides/development-workflow.md) — **remote anantha = working instance; local = test-only** (read first)
- [`guides/secrets.md`](guides/secrets.md) — local `.env` vs Infisical for multi-tenant prod
- [`guides/steward-installer.md`](guides/steward-installer.md) — installing ACS for new users
- [`guides/deployment.md`](guides/deployment.md) — local + multi-tenant prod (+ Postgres override)
- [`guides/deployment-testing.md`](guides/deployment-testing.md) — CI + local system + post-deploy smoke (setup, extend for features, update infra)
- [`priv/skills/steward-installer.md`](priv/skills/steward-installer.md) — installer walkthrough (`bin/setup.sh`)
- [`priv/skills/deployment-testing.md`](priv/skills/deployment-testing.md) — agent procedure for the testing stack above
