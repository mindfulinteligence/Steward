#!/usr/bin/env bash
# Self-heal the Ollama embedding model on a Steward ACS host.
#
# Ensures the ollama container is running and the embedding model
# (nomic-embed-text) is pulled. Idempotent: safe to run on every boot
# and from cron. Mirrors the healthcheck in docker-compose.multitenant.yml
# but also repairs (pulls) the model instead of only reporting it missing.
#
# Prerequisites:
#   - Docker access (the ubuntu user is in the docker group on prod hosts)
#   - The compose project dir (defaults to the repo root on the host)
#
# Usage:
#   scripts/ensure-ollama-model.sh              # use defaults
#   REMOTE_DIR=/path scripts/ensure-ollama-model.sh
#
# Install in cron (as the deploy user):
#   @reboot /home/ubuntu/steward_acs/scripts/ensure-ollama-model.sh >> /home/ubuntu/ollama-ensure.log 2>&1
#   */5 * * * * /home/ubuntu/steward_acs/scripts/ensure-ollama-model.sh >> /home/ubuntu/ollama-ensure.log 2>&1

set -uo pipefail

REMOTE_DIR="${REMOTE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTAINER="${OLLAMA_CONTAINER:-ollama}"
MODEL="${OLLAMA_MODEL:-nomic-embed-text}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.multitenant.yml}"

log() { echo "[$(date -Is)] $*"; }

if ! docker info >/dev/null 2>&1; then
  log "docker unavailable (is the daemon up?) — skipping"
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  log "$CONTAINER container not running — starting via compose"
  if [[ -f "$REMOTE_DIR/$COMPOSE_FILE" ]]; then
    docker compose -f "$REMOTE_DIR/$COMPOSE_FILE" up -d ollama
  else
    docker start "$CONTAINER"
  fi
  for _ in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" && break
    sleep 2
  done
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  log "ERROR: $CONTAINER still not running after start attempt"
  exit 1
fi

if ! docker exec "$CONTAINER" ollama list 2>/dev/null | grep -q "^$MODEL"; then
  log "$MODEL missing — pulling"
  docker exec "$CONTAINER" ollama pull "$MODEL"
  if ! docker exec "$CONTAINER" ollama list 2>/dev/null | grep -q "^$MODEL"; then
    log "ERROR: $MODEL still missing after pull"
    exit 1
  fi
  log "$MODEL pulled successfully"
else
  log "$MODEL present"
fi

exit 0
