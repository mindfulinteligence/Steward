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
| 2026-09-09 15:20 | query_memories include_team_project implementation | opencode/mimo-v2.5-free | free | 0 | 491 / 770 / 150208 | done | Single-shot dispatch, no stall, no drift. Delivered exact additive change (Map.merge pattern for both query/list branches), tool schema entry, and 4 targeted DB-backed tests. Verified diff matches ticket precisely; full suite 929/929 passed across 3 clean reruns (one earlier isolated flake did not reproduce, unrelated to this diff); mix credo --strict and mix format clean. Pre-existing --warnings-as-errors failure in lib/acs/mcp/error_trace.ex confirmed present on dev before this change (not a regression). |
| 2026-09-20 12:45 | manage_files MCP tool implementation | zai-coding-plan/glm-5.3-flash | high-volume | 0 | 0 / 0 / 0 (tokens not reported) | done | Direct Z.AI Coding Plan subscription (separate dollar pool from opencode-go); nightly campaign window → zero marginal cost. Orchestrator-implemented (no delegation round trip): manage_files tool (upload/download/list, 24h TTL, 50MB cap), Acs.Acs.File schema + migration, Acs.Files.Reaper GenServer, 16 new ExUnit tests. Full suite 945/945 passed; format + credo --strict clean. |
