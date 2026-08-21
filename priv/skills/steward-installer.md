---
audit_reasoning: "The skill is highly actionable with clear, sequential steps, concrete commands, and a default configuration. It covers prerequisites (Docker, API keys), verification steps, and failure recovery (e.g., if ACS isn't running). The description is distinct from the name and content opening. It is unique compared to existing skills, which focus on deployment, secrets, and user management, not initial installation."
audit_score: 8
audit_status: "ok"
audited_at: "2026-07-15T14:43:58.179759Z"
description: Installing ACS for new users - step by step setup guide
name: "steward-installer"
scope_paths: ["guides/steward-installer", "site", "guides"]
when_to_use: When onboarding a new user or setting up ACS for the first time
tags: ["install", "setup", "onboarding", "guide"]
---

# ACS Installer Guide

When setting up ACS for a new user, walk through these steps in order.

Canonical human guide: `https://stewardacs.xyz/docs/install`. Use the hosted
workspace path below unless the user explicitly wants to operate a private
instance.

## Hosted invitation shortcut

For a user invited to an existing hosted organization, do not install another ACS instance:

1. Accept the invitation and open the organization workspace.
2. Expand **Agent URLs** and click **Copy project setup prompt**.
3. Open the coding agent at the project root and paste the prompt.
4. Review the agent's merged MCP and `AGENTS.md` / `AGENTS_STEWARD.md` changes.
5. Restart or reconnect the client, complete browser OAuth, and ask it to call `get_started(audience: "coding")`.

The coding URL is `https://<workspace-host>/mcp/sse`; the chat URL is
`https://<workspace-host>/mcp/chat/sse`. Hosted connections use browser OAuth
and must not add API-key headers. Copy system prompts from **Agent URLs** or
`https://<workspace-host>/settings/prompts` instead of reconstructing them.

Verification: the response names the invited organization and exposes coding tools. If the connector is unavailable, confirm the prompt's organization URL and restart the client. If the agent proposes replacing existing MCP or agent files, stop it and require a merge.

## Step 1: Check if ACS is Available

Call `steward_get_present_status(agent_id: "YourName")`.

**If it works** — ACS is running. Register and claim work. Done.

**If it fails** — ACS isn't running. Ask if they want help setting it up.

## Step 2: Ask the 4 Questions

### LLM Provider
ACS uses an LLM for memory quality auditing. Options:
- **None** — memories auto-approve, no API key needed
- **NVIDIA NIM** — fast, free tier available. Needs `NIM_API_KEY`
- **MiniMax** — low cost. Needs `MINIMAX_API_KEY`
- **MIMO** — fast, competitive. Needs `MIMO_API_KEY`
- **OpenAI** — best quality. Needs `OPENAI_API_KEY`
- **OpenAI-compatible** — self-hosted. Needs base URL, model name

### Semantic Embeddings
- **No (default)** — basic text search, no extra setup
- **Yes** — semantic search, needs Ollama running with `nomic-embed-text` model

### Database
- **SQLite (default)** — single file, no extra container
- **PostgreSQL** — multi-user, concurrent. Needs host/port/db/user/password

### Log Streaming
- **Fluent Bit** — reads Docker container logs automatically (zero code changes)
- **Direct integration** — apps POST to ACS individually

## Step 3: Generate Setup Files

After questions, generate:
- `steward.env` — all configuration and secrets
- `steward.docker-compose.yml` — services to run
- `AGENTS_STEWARD.md` — agent startup instructions
- `fluent-bit.conf` + `parsers.conf` (if Fluent Bit enabled)

Add to `.gitignore`:
```
steward.env
steward.docker-compose.yml
var/
acs_data/
```

`AGENTS_STEWARD.md` may be committed when it contains no secrets. Merge its
reference into an existing `AGENTS.md`; never replace unrelated instructions.

Launch: `docker compose --env-file steward.env -f steward.docker-compose.yml up -d`

## Step 4: After Startup

1. Register: `steward_get_present_status(agent_id: "YourName")`
2. Claim work: `steward_claim_work(agent_id: "YourName")`
3. Read the guidance packet

## Default Config (when user says "just make it work")

- Port: 4001
- API key: generated (in steward.env)
- No LLM → memories auto-approve
- No embeddings → SQLite FTS
- SQLite → no extra containers

Minimal `steward.docker-compose.yml`:
```yaml
services:
  steward_acs:
    image: naharemete/steward_acs:latest
    ports: ["4001:4001"]
    env_file: steward.env
    volumes:
      - acs_data:/app/priv
volumes:
  acs_data:
```

Minimal `steward.env`:
```env
SECRET_KEY_BASE=<generated>
MCP_API_KEY=<generated>
SERVICE_API_KEY=<generated>
LOG_INGEST_KEY=<generated>
PORT=4001
```
