#!/usr/bin/env bash
# local-tool-smoke.sh — boot a fresh disposable local ACS, run the MCP tool smoke,
# then tear it down. This is the local test flow that catches tool bugs before they
# ship: every MCP tool is called over the wire and any crash ("Tool execution failed"
# from ToolRegistry.safe_execute) fails the run.
#
# Deterministic: no LLM involved. The app boots with a brand-new SQLite DB so the
# smoke starts from a clean state (create_org / create_work / save_memory / etc.
# all succeed and there are no leftover dedup collisions).
#
# Env:
#   PORT          port for the disposable instance (default 4101)
#   DATABASE_DIR  temp dir for the throwaway DB (default mktemp -d)
#   MCP_API_KEY   key used by both server and smoke (default dev-mcp-key-change-me)
#   SMOKE_API_KEY overrides MCP_API_KEY for the smoke call
#   KEEP          if set, do not tear down (leave server+DB for inspection)
#   MIX_ENV       (default dev)
#
# Usage:
#   ./scripts/local-tool-smoke.sh
#   EXPECTED_TOOLS="$(mix run -e '...')" PORT=4101 ./scripts/local-tool-smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PORT="${PORT:-4101}"
MCP_API_KEY="${MCP_API_KEY:-dev-mcp-key-change-me}"
SMOKE_API_KEY="${SMOKE_API_KEY:-$MCP_API_KEY}"
MIX_ENV="${MIX_ENV:-dev}"
KEEP="${KEEP:-}"

DB_DIR="${DATABASE_DIR:-$(mktemp -d -t acs-smoke.XXXXXX)}"
DATABASE_PATH="$DB_DIR/acs.sqlite"
LOG_FILE="$DB_DIR/server.log"
PUBLIC_URL="http://127.0.0.1:$PORT"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[local-tool-smoke] stopping server (pid $SERVER_PID)"
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "$KEEP" ]]; then
    echo "[local-tool-smoke] KEEP set — leaving DB+log at $DB_DIR and NOT removing it"
  elif [[ -n "${DB_DIR:-}" && -d "$DB_DIR" ]]; then
    rm -rf "$DB_DIR"
  fi
}
trap cleanup EXIT

echo "== local-tool-smoke: fresh instance on $PUBLIC_URL =="
echo "   DB:     $DATABASE_PATH"
echo "   MIX_ENV: $MIX_ENV"

# 1. Migrate a brand-new SQLite DB.
echo "[local-tool-smoke] creating+migrating fresh DB"
DATABASE_PATH="$DATABASE_PATH" MIX_ENV="$MIX_ENV" mix ecto.migrate --quiet 2>&1 | tail -2

# 2. Boot the app on the disposable port.
echo "[local-tool-smoke] booting mix phx.server (pid logged to $LOG_FILE)"
DATABASE_PATH="$DATABASE_PATH" \
PORT="$PORT" \
MCP_API_KEY="$MCP_API_KEY" \
MIX_ENV="$MIX_ENV" \
  nohup mix phx.server >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

# 3. Wait for health.
ready=0
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 "$PUBLIC_URL/mcp/health" 2>/dev/null | grep -q '"status": *"healthy"'; then
    ready=1; break
  fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then
  echo "[local-tool-smoke] ERROR: server did not become healthy on $PUBLIC_URL" >&2
  tail -30 "$LOG_FILE" >&2 || true
  exit 2
fi
echo "[local-tool-smoke] healthy after ${i}s"

# 4. Run the deterministic tool smoke.
PUBLIC_URL="$PUBLIC_URL" SMOKE_API_KEY="$SMOKE_API_KEY" "${SMOKE_SCRIPT:-$ROOT/scripts/smoke-mcp-tools.sh}"

echo "[local-tool-smoke] PASS — all MCP tools exercised cleanly"
