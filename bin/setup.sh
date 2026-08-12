#!/usr/bin/env bash
set -euo pipefail
umask 077

# ─── Steward ACS — Setup ─────────────────────────────────────────────────────
# Asks 4 questions, writes steward.env + steward.docker-compose.yml.
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-.}"

ask() {
  local prompt="$1" default="$2" var="$3"
  local val
  read -r -p "$prompt [$default]: " val
  printf -v "$var" "%s" "${val:-$default}"
}

ask_secret() {
  local prompt="$1" default="$2" var="$3"
  local val
  read -r -s -p "$prompt: " val
  echo ""
  printf -v "$var" "%s" "${val:-$default}"
}

choose() {
  local prompt="$1" default="$2" var="$3"
  shift 3
  local options=("$@")
  echo ""
  for i in "${!options[@]}"; do
    echo "  $((i+1))) ${options[$i]}"
  done
  local val
  read -r -p "$prompt [1-$#] ($default): " val
  val="${val:-$default}"
  printf -v "$var" "%s" "$val"
}

generate_secret() {
  LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 40 | head -1 || true
}

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║        Steward ACS — Quick Setup                ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ─── Your name (MCP agent identity — same role as acs_dev_ keys in prod) ──────
echo "Your name is used as the agent identity for local coding MCP"
echo "(Active Agents, task ownership). Same idea as a named developer key in prod."
echo ""
ask "Your name (for coding agents)" "" ACS_DEVELOPER_NAME
if [ -z "${ACS_DEVELOPER_NAME}" ]; then
  echo "  No name entered — agents will get a pool name (Alice/Yara/…) until you set one."
  ACS_DEVELOPER_NAME="unknown"
fi

# ─── Question 1: LLM Provider ─────────────────────────────────────────────────
echo ""
echo "The memory auditor needs an LLM to evaluate memory quality."
echo "Without one, memories auto-approve (no quality checks)."
echo ""
echo "Choose an LLM provider:"
echo "  1) none              — No auditor (memories auto-approve)"
echo "  2) nim               — NVIDIA NIM"
echo "  3) minimax           — MiniMax"
echo "  4) mimo              — MIMO"
echo "  5) openai            — OpenAI (api.openai.com)"
echo "  6) openai-compatible — Any OpenAI-compatible API (custom URL + model)"
echo ""
ask "Enter number or name" "1" LLM_CHOICE
LLM_CHOICE=$(echo "$LLM_CHOICE" | tr '[:upper:]' '[:lower:]')

case "$LLM_CHOICE" in
  1|none)
    LLM=""
    LLM_ENV_VARS=""
    LLM_KEY_HELP=""
    ;;
  2|nim)
    LLM="nim"
    ask_secret "NVIDIA NIM API key" "" NIM_KEY
    LLM_ENV_VARS="NIM_API_KEY=${NIM_KEY}"
    LLM_KEY_HELP=""
    ;;
  3|minimax)
    LLM="minimax"
    ask_secret "MiniMax API key" "" MINIMAX_KEY
    LLM_ENV_VARS="MINIMAX_API_KEY=${MINIMAX_KEY}"
    LLM_KEY_HELP=""
    ;;
  4|mimo)
    LLM="mimo"
    ask_secret "MIMO API key" "" MIMO_KEY
    LLM_ENV_VARS="MIMO_API_KEY=${MIMO_KEY}"
    LLM_KEY_HELP=""
    ;;
  5|openai)
    LLM="openai"
    ask_secret "OpenAI API key" "" OPENAI_KEY
    LLM_ENV_VARS="OPENAI_API_KEY=${OPENAI_KEY}"
    LLM_KEY_HELP=""
    ;;
  6|openai-compatible|openai_compatible)
    LLM="openai"
    ask_secret "API key (leave empty for no-key endpoints)" "" OPENAI_KEY
    ask "Base URL" "http://localhost:8000/v1" OPENAI_URL
    ask "Model name" "gpt-4o-mini" OPENAI_MODEL
    LLM_ENV_VARS="OPENAI_API_KEY=${OPENAI_KEY}
OPENAI_BASE_URL=${OPENAI_URL}
OPENAI_MODEL=${OPENAI_MODEL}"
    LLM_KEY_HELP=""
    ;;
  *)
    echo "  Invalid choice, defaulting to none"
    LLM=""
    LLM_ENV_VARS=""
    LLM_KEY_HELP=""
    ;;
esac

# ─── Question 2: Embeddings ───────────────────────────────────────────────────
echo ""
ask "Enable semantic embeddings via Ollama?" "n" OLLAMA
OLLAMA=$(echo "$OLLAMA" | tr '[:upper:]' '[:lower:]')

OLLAMA_SERVICE=""
OLLAMA_URL="http://localhost:11434"
if [ "$OLLAMA" = "y" ]; then
  OLLAMA_SERVICE=$(cat <<YAML
  ollama:
    image: ollama/ollama:latest
    ports: ["11434:11434"]
    volumes:
      - ollama_data:/root/.ollama
    healthcheck:
      test: ["CMD-SHELL", "ollama list | grep -q nomic-embed-text"]
      interval: 30s
      timeout: 10s
      retries: 5
YAML
  )
fi

# ─── Question 3: Database ────────────────────────────────────────────────────
echo ""
ask "Database?" "sqlite" DB
DB=$(echo "$DB" | tr '[:upper:]' '[:lower:]')

DB_VOLUME=""
DB_SERVICE=""
DATABASE_URL=""
case "$DB" in
  postgres|pg)
    DB="postgres"
    ask "Postgres host" "localhost" PG_HOST
    ask "Postgres port" "5432" PG_PORT
    ask "Postgres database" "acs_prod" PG_NAME
    ask "Postgres user" "postgres" PG_USER
    ask_secret "Postgres password (blank generates a strong secret)" "" PG_PASS
    if [ -z "$PG_PASS" ]; then PG_PASS="$(generate_secret)"; fi
    DATABASE_URL="ecto://${PG_USER}:${PG_PASS}@${PG_HOST}:${PG_PORT}/${PG_NAME}"
    DB_SERVICE=$(cat <<YAML
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: "${PG_NAME}"
      POSTGRES_USER: "${PG_USER}"
      POSTGRES_PASSWORD: "${PG_PASS}"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready"]
      interval: 10s
      timeout: 5s
      retries: 5
YAML
    )
    DB_VOLUME="  postgres_data:"
    ;;
  *)
    DB="sqlite"
    ;;
esac

# ─── Question 4: Log Streaming ────────────────────────────────────────────────
echo ""
echo "How should apps stream logs to ACS?"
echo "  1) none       — No log streaming"
echo "  2) fluent-bit — Stream all Docker container logs automatically (no code changes)"
echo "  3) manual     — I'll add log shipping to each app (needs minor code per app)"
echo ""
ask "Enter number or name" "1" LOG_STREAM
LOG_STREAM=$(echo "$LOG_STREAM" | tr '[:upper:]' '[:lower:]')

FLUENT_SERVICE=""
case "$LOG_STREAM" in
  2|fluent-bit|fluentbit|fb)
    FB_SRC="${SCRIPT_DIR}/../docker/fluent-bit"
    if [ -d "$FB_SRC" ]; then
      cp "$FB_SRC/fluent-bit.conf" "$OUT_DIR/fluent-bit.conf"
      cp "$FB_SRC/parsers.conf" "$OUT_DIR/parsers.conf"
      echo "  ✓ fluent-bit.conf copied"
    fi
    FLUENT_SERVICE=$(cat <<YAML
  fluent-bit:
    image: cr.fluentbit.io/fluent/fluent-bit:3.1
    container_name: acs_fluent_bit
    restart: unless-stopped
    environment:
      LOG_INGEST_KEY: \${LOG_INGEST_KEY}
    volumes:
      - ./fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro
      - ./parsers.conf:/fluent-bit/etc/parsers.conf:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
    depends_on:
      steward_acs:
        condition: service_started
YAML
    )
    echo "  ✓ Fluent Bit configured — all Docker container logs will ship to ACS"
    ;;
  *)
    # Manual or none — no Fluent Bit
    ;;
esac

# ─── Generate secrets ─────────────────────────────────────────────────────────
SECRET_KEY_BASE=$(generate_secret)
MCP_API_KEY="acs_$(generate_secret)"
SERVICE_API_KEY="acs_svc_$(generate_secret)"
LOG_INGEST_KEY="acs_log_$(generate_secret)"

# ─── Write steward.env ────────────────────────────────────────────────────────
ENV_FILE="${OUT_DIR}/steward.env"
cat > "$ENV_FILE" <<ENV
# ─── Steward ACS Configuration ──────────────────────────
# Generated by bin/setup.sh — contains secrets; never commit
# ────────────────────────────────────────────────────────

# Core
SECRET_KEY_BASE=${SECRET_KEY_BASE}
MCP_API_KEY=${MCP_API_KEY}
SERVICE_API_KEY=${SERVICE_API_KEY}
LOG_INGEST_KEY=${LOG_INGEST_KEY}
PORT=4001

# LLM Provider
ENABLED_LLM_PROVIDERS=${LLM}
${LLM_ENV_VARS}
${LLM_KEY_HELP}

# Embeddings
$( [ "$OLLAMA" = "y" ] && echo "OLLAMA_URL=${OLLAMA_URL}" || echo "# OLLAMA_URL= (disabled — SQLite FTS fallback)" )

# Database
$( [ "$DB" = "postgres" ] && echo "DATABASE_URL=${DATABASE_URL}" || echo "# DATABASE_URL= (using SQLite)" )
$( [ "$DB" = "sqlite" ] && echo "DATABASE_PATH=./var/acs.sqlite" || echo "# DATABASE_PATH=./var/acs.sqlite" )

# Optional
# ACS_ORG_NAME=default
ACS_DEVELOPER_NAME=${ACS_DEVELOPER_NAME}
# ADMIN_EMAILS=
ENV

chmod 600 "$ENV_FILE"
echo "  ✓ steward.env written with mode 600"

# ─── Write steward.docker-compose.yml ─────────────────────────────────────────
COMPOSE_FILE="${OUT_DIR}/steward.docker-compose.yml"
cat > "$COMPOSE_FILE" <<YAML
version: "3.9"

services:
  steward_acs:
    image: naharemete/steward_acs:latest
    ports:
      - "\${PORT:-4001}:4001"
    env_file:
      - steward.env
    volumes:
      - acs_data:/app/priv
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4001/mcp/health"]
      interval: 30s
      timeout: 5s
      start_period: 10s
      retries: 3
${OLLAMA_SERVICE}
${DB_SERVICE}
${FLUENT_SERVICE}

volumes:
  acs_data:
${DB_VOLUME}
$( [ "$OLLAMA" = "y" ] && echo "  ollama_data:" || true )
YAML

echo "  ✓ steward.docker-compose.yml written"

# ─── Write AGENTS_ACS.md ─────────────────────────────────────────────────────
ACS_FILE="${OUT_DIR}/AGENTS_ACS.md"
cat > "$ACS_FILE" <<ACSMD
# ACS Agent Instructions (local — not committed)

This file is gitignored. Non-ACS agents never see it.

## Startup
At the start of every session:
  1. acs_get_present_status(agent_id: "") — register (returns assigned_agent_id; use "${ACS_DEVELOPER_NAME}" if set)
  2. acs_create_work / acs_claim_work — get task + guidance packet

Then follow the guidance packet: lock files, save memories, release when done.
ACSMD

echo "  ✓ AGENTS_ACS.md written"
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  Done. Run:                                     ║"
echo "║                                                  ║"
echo "║    docker compose --env-file steward.env -f steward.docker-compose.yml up -d                          ║"
echo "║                                                  ║"
echo "║  Coding identity: ${ACS_DEVELOPER_NAME}          ║"
echo "║  (Settings → Coding identity, or acs_dev_ key)   ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
