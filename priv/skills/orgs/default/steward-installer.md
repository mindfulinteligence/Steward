---
audit_reasoning: "The skill is highly actionable, complete, and well-structured. It provides clear, ordered steps, concrete tool references (e.g., `steward_get_present_status`), exact file names, and configuration examples. The description is distinct and informative. It includes prerequisites (implied by the questions), verification steps (Step 4), and a default configuration for a quick start. The audience (coding) is appropriate for the technical, command-line and file-generation instructions. It is unique and not a duplicate of existing skills."
audit_score: 10
audit_status: "ok"
audited_at: "2026-07-28T18:03:33.372113Z"
description: Installing ACS for new users - step by step setup guide
name: "steward-installer"
scope_paths: ["guides/steward-installer", "site", "guides"]
when_to_use: When onboarding a new user or setting up ACS for the first time
tags: ["install", "setup", "onboarding", "guide"]
approved_at: "2026-08-03T10:00:40.597085Z"
approved_by: "human"
reviewed_at: "2026-08-03T10:00:40.597085Z"
reviewed_by: "human"
status: "approved"
---

# ACS Installer Guide

When setting up ACS for a new user, walk through these steps in order.

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
- **TokenRouter** — OpenAI-compatible routing with GLM-5.3. Needs `TOKENROUTER_API_KEY`
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
AGENTS_STEWARD.md
var/
acs_data/
```

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
