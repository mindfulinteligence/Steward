# OpenCode delegation cost log

A running log of every OpenCode-delegated task dispatched against this repo. Each row records the model/tier used, estimated cost, token counts, and outcome. Append a row after every dispatch — see `~/.claude/agents/opencode-manager.md` for the discipline this supports.

## What cost data is available

Claude models have real per-token pricing (see `~/.claude/CLAUDE.md` for current rates). Third-party models reached through OpenCode (mimo-v2.5, glm-5.3, deepseek-v4-flash, etc.) do **not** have real $/token pricing — only a relative `per_5h` request-count estimate and a tier label (`high-volume` / `balanced` / `scarce` / `unlisted`) against a shared dollar pool. Treat "scarce tier" as shorthand for "expensive, use sparingly," not a number you can do arithmetic with. The `$` column for non-Claude models is an approximation based on pool-share, not a billable figure.

## Column definitions

| Column | Meaning |
|---|---|
| **Date** | Dispatch timestamp (YYYY-MM-DD HH:MM). |
| **Ticket / phase** | Brief label: ticket ID + phase (e.g. `#42 implementation`, `#42 review`). |
| **Provider/model** | Exact `providerID/modelID` copied verbatim from `opencode_list_agents` output. |
| **Tier** | free / high-volume / balanced / scarce / unlisted. |
| **Cost ($)** | Estimated cost: real for Claude models, approximate share for others. |
| **Tokens (in/out/cache-read)** | Token counts as reported by OpenCode, formatted `in / out / cache`. Use `0` for unknown sub-fields. |
| **Outcome** | done / stalled→resumed / usage-limit wall / cancelled / error. |
| **Notes** | Anything worth remembering: provider flakiness, unexpected behavior, quality observations. |

## Log

| Date | Ticket / phase | Provider/model | Tier | Cost ($) | Tokens (in/out/cache-read) | Outcome | Notes |
|------|---------------|----------------|------|----------|---------------------------|---------|-------|
