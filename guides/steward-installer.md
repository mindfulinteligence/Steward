# ACS Installer Guide

Follow [`priv/skills/steward-installer.md`](../priv/skills/steward-installer.md) and `bin/setup.sh`. That walkthrough covers:

- Checking if ACS is already running
- Asking about preferences (LLM provider, embeddings, database, log streaming)
- Generating `steward.env`, `steward.docker-compose.yml`, and `AGENTS_STEWARD.md`
- Verifying setup after startup

Hosted invited users do not run the self-hosted installer. After accepting the invitation, they open the organization workspace and paste **Copy project setup prompt** into a coding agent at the project root. The prompt configures the organization MCP URL plus `AGENTS.md` / `AGENTS_STEWARD.md` without overwriting existing project settings.
