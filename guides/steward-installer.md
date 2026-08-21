# Install a private Steward instance

Use this guide only when you want to operate your own Steward service. If you were invited to an existing hosted organization, return to [Set up Steward](/docs/overview) and use **Copy project setup prompt** instead.

## Prerequisites

- Docker with Docker Compose
- A project directory where the setup files can live
- An MCP-compatible coding agent

The default installation uses SQLite and needs no LLM or embedding provider.

## Fastest setup: let your coding agent install it

1. Open your coding agent at the project root.
2. Give it this prompt:

   > Install a private Steward ACS instance for this project. Follow the installer at https://stewardacs.xyz/docs/install and use the default local configuration unless I answer otherwise. Merge all agent and MCP instructions with existing files; do not overwrite unrelated settings. Keep secrets out of git. Start the service and verify the Steward status tool works.

3. The agent should run `bin/setup.sh` from a Steward ACS checkout or follow the bundled installer procedure in `priv/skills/steward-installer.md`.
4. Review the generated files before the agent starts Docker.

## Files the installer creates

- `steward.env` — secrets and runtime configuration
- `steward.docker-compose.yml` — the Steward service
- `AGENTS_STEWARD.md` — rules for coding agents using this repository
- Optional Fluent Bit configuration when log streaming is enabled

Add secret and generated runtime files to `.gitignore`:

```gitignore
steward.env
steward.docker-compose.yml
var/
acs_data/
```

`AGENTS_STEWARD.md` may be committed when it contains instructions only and no secrets.

## Default configuration

Choose these defaults when you want the smallest working installation:

- Port `4001`
- SQLite database
- No external LLM; memory intake auto-approves
- No semantic embeddings; keyword search remains available
- Generated API keys and `SECRET_KEY_BASE`

Minimal Compose file:

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

Minimal environment file:

```env
SECRET_KEY_BASE=<generated-long-random-value>
MCP_API_KEY=<generated-random-value>
SERVICE_API_KEY=<generated-random-value>
LOG_INGEST_KEY=<generated-random-value>
PORT=4001
```

Generate every placeholder independently with a cryptographically secure password generator. Never copy the example placeholders into a running system.

## Start Steward

```bash
docker compose --env-file steward.env -f steward.docker-compose.yml up -d
```

Your local dashboard is `http://localhost:4001/`. The local MCP endpoint is `http://localhost:4001/mcp/v1/messages` with an `x-api-key` header containing `MCP_API_KEY`.

## Optional choices

Configure these only when you need them:

- An LLM provider for memory-quality review: NVIDIA NIM, MiniMax, MIMO, OpenAI, or an OpenAI-compatible endpoint
- Ollama with `nomic-embed-text` for semantic search
- PostgreSQL for concurrent multi-user operation
- Fluent Bit or direct HTTP ingestion for application logs

See [Configuration](/docs/configuration) for exact environment variables and [Operate](/docs/deployment) before exposing Steward outside your machine.

## Connect the project agent

Add the local MCP server to the client using the endpoint and API key above. Put the generated instructions in `AGENTS_STEWARD.md`, then ensure `AGENTS.md` contains:

```md
Check if `@AGENTS_STEWARD.md` exists. If yes, follow the instructions there.
```

Restart the client so it discovers the tools.

## Verify

1. Confirm the container is running with `docker compose --env-file steward.env -f steward.docker-compose.yml ps`.
2. Ask the agent to call the Steward status or `get_started(audience: "coding")` tool.
3. Create and release one test task.
4. Confirm the task appears in `http://localhost:4001/`.

If startup fails, run `docker compose --env-file steward.env -f steward.docker-compose.yml logs steward_acs` and check the missing or invalid environment variable against [Configuration](/docs/configuration).
