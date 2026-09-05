# Steward ACS

Steward ACS — Agent Coordination System. Air traffic control for AI agents: task lifecycles, file locking, knowledge memory, and MCP tools, all in a standalone Phoenix app.

## OpenCode delegation & cost tracking

The dispatch/verification discipline — ticket-writing checklist, cost-tier matching, recognizing usage-limit walls and silent stalls, never trusting a worker's self-reported "done" — lives in the global subagent file `~/.claude/agents/opencode-manager.md`. That file applies across every project, not just this one.

The model price/tier/notes catalog referenced by that subagent lives in `~/.claude/CLAUDE.md`. Update that global file (not this repo's CLAUDE.md) when something new is learned about a specific model's behavior, so every project benefits.

This repo's own dispatch cost log lives at `.claude/opencode-costs.md`. Every OpenCode dispatch against this repo should get a row appended there (provider/model, tier, dollar cost, tokens, outcome).

Concurrent sessions: this can happen in any repo — a concurrent Claude Code or other session could run its own OpenCode delegation against this same working directory at the same time, which risks interleaved file writes or one session's cleanup pass deleting another's in-progress files. Before assuming exclusive ownership of the working tree, run `ps aux | grep opencode` and listen on OpenCode server ports. This hazard has been observed in other projects; treat it as routine to check, not exceptional.
