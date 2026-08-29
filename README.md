# Steward ACS — Agent Coordination System

> Air traffic control for AI agents. Task lifecycles, file locking, knowledge memory, and MCP tools — all in a standalone Phoenix app.

**Website: [stewardacs.xyz](https://stewardacs.xyz)**

**Documentation: [stewardacs.xyz/docs](https://stewardacs.xyz/docs)** — installation, configuration, development, deployment, and testing guides published from this repository.

New to Steward? Start with [what Steward is, how to connect agents, and how teams use it](guides/getting-started.md).

Steward ACS is an **infrastructure layer** for multi-agent coordination. It runs as a standalone Phoenix web application (port 4001) and exposes MCP (Model Context Protocol) tools that any AI agent — Claude, GPT, Llama, or any MCP-compatible client — can call directly. It does not do the work itself; it manages the agents who do.

---

## Features

| Capability | Description |
|---|---|
| **Task Lifecycle** | Create, claim, release work units. 10-minute auto-release prevents stuck tasks. Similar-task detection prevents duplicate work. |
| **File Locking** | Lock files before editing. Prevents multi-agent edit conflicts. Auto-releases with task lifecycle. |
| **Knowledge Memory** | Persistent "eternal truths" — patterns, decisions, warnings shared across all agents. LLM-powered semantic search. |
| **MCP Tool Gateway** | Expose any REST API as an agent-callable MCP tool. YAML-defined, hot-reloadable, no server restart. |
| **Agent Presence** | Real-time tracking of every agent's current task, purpose, application, and component. |
| **Specs & Documents** | **Specs** = code module docs (purpose, invariants, workflows). **Documents** = non-code artifacts (policies, briefs, marketing). Same store; guidance packets surface both. |
| **Error Tracking** | Persistent error traces with acknowledgment and resolution workflow. Create investigation tasks from errors. |
| **Cluster Coordination** | Multi-cluster support with isolated namespaces per environment or team. |

---

## Quick Start

### Docker — Local

```bash
git clone https://github.com/NaharEmet/steward_acs.git
cd steward_acs

# Configure Auth0 dashboard OAuth and optional LLM providers.
# Copy and edit the example env file before starting:
# cp .env.example .env
# nano .env

docker compose up -d

curl http://localhost:4001/mcp/health

# Open http://localhost:4001 in your browser and continue through Auth0 Universal Login.
```

> **Note:** Memory auditing and semantic search need at least one LLM provider API key. Set `TOKENROUTER_API_KEY`, `NIM_API_KEY`, `MINIMAX_API_KEY`, or `OPENAI_API_KEY` in `.env` (or directly in `docker-compose.yml`) to enable them. Without these, you'll see `Audit failed: :no_providers_enabled` in the logs.

### From Source

```bash
# Prerequisites: Elixir ~> 1.17, Erlang OTP 26+, SQLite3 or PostgreSQL
mix deps.get
mix ecto.setup
mix phx.server

# Run tests
mix test
```

---

## Architecture

```
                    ┌─────────────────────────────┐
                    │   AI Agents (MCP Clients)     │
                    │  Call acs_* tools via HTTP    │
                    └─────────────┬───────────────┘
                                  │
                    ┌─────────────▼───────────────┐
                    │     MCP Tool Gateway         │
                    │  YAML-defined, hot-reload    │
                    │  Routes to internal/external │
                    └─────────────┬───────────────┘
                                  │
                    ┌─────────────▼───────────────┐
                    │       Core Engine            │
                    │  Task Manager  Lock Manager  │
                    │  Memory Store  Presence      │
                    │  Cognition     Error Registry│
                    └─────────────┬───────────────┘
                                  │
                    ┌─────────────▼───────────────┐
                    │   ETS Cache (in-memory)      │
                    └─────────────┬───────────────┘
                                  │
                    ┌─────────────▼───────────────┐
                    │  PostgreSQL / SQLite          │
                    │  Tasks, locks, memory, logs  │
                    └─────────────────────────────┘
                    ┌─────────────────────────────┐
                    │  Background Processes        │
                    │  Sweeper  Auditor  MetaHarness│
                    └─────────────────────────────┘
```

**Tech stack:** Elixir 1.17+, Phoenix 1.8, Bandit 1.5 (HTTP), Ecto SQL 3.13, PostgreSQL (prod) / SQLite3 (dev), ETS caching, Phoenix PubSub, Tailwind CSS.

---

## Deployment

### Local (Docker)

```bash
docker compose up -d
```

Builds from the Dockerfile, runs with `MIX_ENV=dev` on port 4001 with SQLite.

### Remote

See [guides/deployment.md](guides/deployment.md) for deployment styles (code dev, org memory, multi-tenant). For remote PostgreSQL + Caddy TLS, also see [stewardacs.xyz](https://stewardacs.xyz).

**Important for SSE:** The `/mcp/sse` endpoint uses Server-Sent Events (long-lived streaming connections). Ensure your reverse proxy does not buffer or timeout these connections.

### Obsidian Vault Sync

Steward ACS can read and write memories directly from an Obsidian vault. Memories are stored as `.md` files with YAML frontmatter — editable in Obsidian, readable by Steward.

```bash
export MEMORY_STORE=obsidian
export OBSIDIAN_VAULT_PATH=/path/to/your/vault
```

The file watcher debounces events (1000ms) and excludes `.obsidian/` internal files. Single-tenant remote deployments can use Syncthing for vault synchronization.

---

## Key Configuration

| Variable | Required (prod) | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | Yes | — | Phoenix secret (`mix phx.gen.secret`) |
| `DATABASE_URL` | Yes | — | PostgreSQL connection string |
| `MCP_API_KEY` | Yes | — | MCP tool authentication |
| `SERVICE_API_KEY` | Yes | — | Internal service MCP key |
| `OIDC_BROWSER_ENABLED` | Yes | `false` | Enable Auth0 OIDC for individual dashboard login |
| `AUTH0_WEB_CLIENT_ID` | When dashboard OAuth is on | — | Auth0 Regular Web Application client ID |
| `AUTH0_WEB_CLIENT_SECRET` | When dashboard OAuth is on | — | Auth0 Regular Web Application client secret |
| `AUTH0_WEB_REDIRECT_URI` | When dashboard OAuth is on | — | Exact registered callback URL ending in `/auth/callback` |
| `ACCOUNT_HOST` | Yes in multi-tenant mode | endpoint host | Canonical host for login, onboarding, and invitations |
| `SELF_SERVICE_ORGS_ENABLED` | No | `false` | Let verified orgless users create an organization |
| `PHX_HOST` / `DOMAIN` | Yes | — | Public hostname for URLs and LiveView origin checks |
| `ACS_ORG_NAME` | No | `default` | Org namespace (scopes all operations) |
| `ACS_DEVELOPER_NAME` | No | `unknown` | Developer identity for memory attribution |
| `COOKIE_SIGNING_SALT` | No | derived | Session cookie salt (set at Docker build for stable LiveView auth) |
| `CORS_ORIGINS` | No | `*` | Comma-separated browser origins allowed for MCP CORS |
| `AUDITOR_INTERVAL` | No | `30000` | Memory auditor polling interval (ms) |
| `OLLAMA_URL` | No | `http://localhost:11434` | Ollama endpoint for local embeddings |
| `MEMORY_STORE` | No | `yaml` | Storage format: `yaml` or `obsidian` |
| `OBSIDIAN_VAULT_PATH` | No | — | Filesystem path to Obsidian vault |
| `ENABLED_LLM_PROVIDERS` | No | all | Comma-separated whitelist (e.g. `tokenrouter,nim`) |
| `NIM_API_KEY` | No | — | NVIDIA NIM API key for LLM evaluation |
| `TOKENROUTER_API_KEY` | No | — | TokenRouter API key for LLM evaluation |
| `TOKENROUTER_MODEL` | No | `z-ai/glm-5.3-free` | TokenRouter model override |
| `MINIMAX_API_KEY` | No | — | MiniMax API key for LLM evaluation |
| `OPENAI_API_KEY` | No | — | OpenAI API key for LLM evaluation |
| `OPENAI_BASE_URL` | No | — | Custom OpenAI-compatible endpoint URL |
| `OPENAI_MODEL` | No | — | OpenAI model name override |
| `MCP_TOOLS_PATH` | No | `<app>/acs/acstools` | Comma-separated directories for YAML tool definitions |
| `MCP_AUTH_LOCAL_FALLBACK` | No | `false` | Allow unauthenticated MCP calls from localhost |
| `HTTP_SLEEP_MAX_MS` | No | — | Max sleep duration for `sleep` tool (ms) |

| `ALLOWED_COMMANDS` | No | — | Comma-separated allowed commands for `exec_command` tool |
| `BRIDGE_ALLOWED_HOSTS` | No | — | Comma-separated allowed hosts for the HTTP Bridge |
| `ACS_ADMIN_EMAILS` | No | — | Comma-separated admin emails for notifications |
| `LOG_INGEST_KEY` | No | — | Shared key for log ingestion endpoint |
| `OAUTH_BEARER_ENABLED` | No | `false` | Enable Auth0 JWT validation for Claude Connectors |
| `AUTH0_DOMAIN` | When OAuth on | — | Auth0 tenant domain (e.g. `dev-jw5wgp2b.us.auth0.com`) |
| `AUTH0_AUDIENCE` | When OAuth on | — | MCP API identifier — must match Claude connector URL (e.g. `https://prod.stewardacs.xyz/mcp/sse`) |
| `AUTH0_ISSUER` | No | `https://${AUTH0_DOMAIN}/` | Override OIDC issuer if non-standard |
| `MCP_PUBLIC_URL` | When OAuth on | — | Public base URL for OAuth metadata (e.g. `https://prod.stewardacs.xyz`) |
| `MCP_RESOURCE_URL` | No | same as audience | Resource URL in protected-resource metadata |
| `MCP_QUERY_KEY_AUTH` | No | `false` | Allow `?api_key=` on MCP SSE (legacy connector fallback) |
| `SESSION_VALIDITY_DAYS` | No | `7` | Dashboard session lifetime |

### LLM Provider Setup

Memory auditing and semantic search need an LLM provider. Set at least one of these:

| Variable | Provider |
|---|---|
| `NIM_API_KEY` | NVIDIA NIM |
| `TOKENROUTER_API_KEY` | TokenRouter (OpenAI-compatible) |
| `MINIMAX_API_KEY` | MiniMax |
| `OPENAI_API_KEY` | OpenAI (also set `OPENAI_BASE_URL` / `OPENAI_MODEL` for custom endpoints) |

You can restrict which providers are used via `ENABLED_LLM_PROVIDERS` (comma-separated, e.g. `tokenrouter,nim`). By default all enabled providers with valid API keys are tried in priority order. TokenRouter uses `https://api.tokenrouter.com/v1` and defaults to `z-ai/glm-5.3-free`.

### MCP Tool Definitions

Steward ACS discovers tool definitions from YAML files on disk. The search path is configured via:

- `MCP_TOOLS_PATH` env var (comma-separated directories)
- `config :steward_acs, Acs.MCP.ToolLoader, tools_paths:` in config files
- Default: `<app_dir>/acs/acstools/`

Create tool YAML files in one of these directories and they'll be hot-reloaded automatically. See `priv/acs_tools/` for examples.

See `.env.remote`, `.env.example`, and `config/runtime.exs` for the full reference.

---

## MCP Tool Overview

All tools are prefixed `acs_*` when called by agents.

| Category | Tools |
|---|---|
| **Core** | `create_work`, `claim_work`, `release_work`, `lock_file`, `unlock_file`, `get_present_status`, `list_tasks`, `sleep`, `wake`, `help` |
| **Knowledge** | `save_memory`, `query_memories`, `set_memory_status`, `generate_guidance_packet` |
| **Cognition** | `cognition_get`, `cognition_search`, `cognition_propose`, `cognition_approve`, `cognition_reject`, `cognition_list`, `cognition_list_undocumented` |
| **Diagnostic** | `config_lookup`, `connection_diagnostic`, `query_memories`, `memory_health_check`, `get_logs` |
| **Error** | `list_error_traces`, `ack_error_trace`, `resolve_error_trace`, `create_task_from_error_trace` |
| **Advanced** | `write_tool`, `refresh_tools`, `time`, `list_orgs`, `list_categories`, `list_tools`, `exec_command` |

---

## Project Structure

```
steward_acs/
├── config/            # Environment configs (dev, prod, test, runtime)
├── lib/
│   ├── acs.ex         # Public API module
│   ├── acs/           # Core logic: tasks, locks, memory, MCP, cognition
│   ├── acs_web/       # Phoenix web layer + LiveView dashboard
│   └── mix/tasks/     # Mix tasks (keys, cognition, meta-harness)
├── priv/
│   ├── acs_memory/    # Canonical YAML memory files
│   └── repo/migrations/
├── test/
├── assets/
├── archive/deploy/                 # Superseded compose files
├── Dockerfile
├── docker-compose.yml              # Local dev (SQLite, port 4001)
├── docker-compose.multitenant.yml  # Canonical multi-tenant prod
├── docker-compose.postgres.yml     # Postgres override for prod
├── Caddyfile.multitenant           # Wildcard TLS + Auth0 OAuth routes
├── .env.example                    # Local env template
├── .env.multitenant                # Prod env template
└── mix.exs
```


---

## Development

```bash
# Setup
mix setup

# Run dev server (port 4001)
mix phx.server

# Interactive shell
iex -S mix phx.server

# Run tests
mix test

# Lint
mix credo
```

---

## License

Apache License 2.0
