#!/usr/bin/env bash
# Confirmation-gated prod rollback wrapper around deploy.sh --rollback.
#
# Prints the current vs previous image tag, requires explicit user confirmation,
# then runs the same blue/green cutover as deploy.sh --rollback.
#
# Usage:
#   SERVER=ubuntu@HOST ./scripts/rollback.sh            # interactive: prompts before acting
#   CONFIRM=yes SERVER=ubuntu@HOST ./scripts/rollback.sh # non-interactive (CI/agent after user approval)
#
# Env:
#   SERVER=       required, e.g. ubuntu@139.99.89.23
#   CONFIRM=yes   skip the interactive prompt (use only AFTER the user has approved)
#   REMOTE_DIR=   default /home/ubuntu/steward_acs
#   PUBLIC_URL=   override smoke base URL (default: MCP_PUBLIC_URL from remote .env)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SERVER="${SERVER:-}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/steward_acs}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.multitenant.yml}"
CONFIRM="${CONFIRM:-}"
PUBLIC_URL="${PUBLIC_URL:-}"

if [[ -z "$SERVER" ]]; then
  echo "ERROR: SERVER must be set (e.g. SERVER=ubuntu@139.99.89.23)" >&2
  exit 1
fi

info() { echo "[rollback] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# --- read current rollback state from the server (presence only, never secrets) ---
# shellcheck disable=SC2029
STATE=$(ssh "$SERVER" bash -s -- "$REMOTE_DIR" <<'REMOTE'
set -euo pipefail
REMOTE_DIR="$1"
cd "$REMOTE_DIR"
env_get() {
  local key="$1"
  [[ -f .env ]] || return 1
  grep -E "^${key}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true
}
current="$(env_get ACS_IMAGE_TAG || true)"
prev="$(env_get ACS_IMAGE_TAG_PREV || true)"
slot="$(env_get ACS_ACTIVE_SLOT || true)"
public_url="$(env_get MCP_PUBLIC_URL || true)"
[[ -f .env ]] || { echo "env_present=no"; exit 0; }
echo "env_present=yes"
echo "current_tag=${current:-}"
echo "prev_tag=${prev:-}"
echo "active_slot=${slot:-}"
echo "public_url=${public_url:-}"
REMOTE
)

env_present=$(echo "$STATE" | awk -F= '/^env_present=/{print $2; exit}')
current_tag=$(echo "$STATE" | awk -F= '/^current_tag=/{print $2; exit}')
prev_tag=$(echo "$STATE" | awk -F= '/^prev_tag=/{print $2; exit}')
active_slot=$(echo "$STATE" | awk -F= '/^active_slot=/{print $2; exit}')
remote_public_url=$(echo "$STATE" | awk -F= '/^public_url=/{print $2; exit}')

if [[ "$env_present" != "yes" ]]; then
  die "no .env on ${SERVER}:${REMOTE_DIR} — nothing to roll back"
fi
if [[ -z "$current_tag" ]]; then
  die "ACS_IMAGE_TAG missing on server — nothing to roll back"
fi
if [[ -z "$prev_tag" ]]; then
  die "ACS_IMAGE_TAG_PREV missing on server — no previous version to roll back to (was this the first deploy?)"
fi

info "current tag  = ${current_tag}"
info "prev tag     = ${prev_tag}"
info "active slot  = ${active_slot:-unknown}"

# --- confirmation gate ---
if [[ "$CONFIRM" == "yes" ]]; then
  info "CONFIRM=yes — proceeding to roll back ${current_tag} → ${prev_tag}"
else
  if [[ ! -t 0 ]]; then
    die "no confirmation: run interactively, or set CONFIRM=yes (only after the user has approved)"
  fi
  echo ""
  echo "This will roll back prod (${SERVER}) from ${current_tag} to ${prev_tag}."
  echo "It pins ACS_IMAGE_TAG to the previous version and does a blue/green cutover."
  echo "DB migrations are NOT rolled back (Neon is forward-only)."
  read -r -p "Roll back prod now? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) info "confirmed — rolling back" ;;
    *) die "rollback cancelled by user" ;;
  esac
fi

# --- execute the real cutover ---
"$ROOT/scripts/deploy.sh" --rollback

# --- post-rollback smoke ---
info "rollback cutover done — tag should now be ${prev_tag}"
PUBLIC_URL="${PUBLIC_URL:-$remote_public_url}"
PUBLIC_URL="${PUBLIC_URL%/}"
if [[ -n "$PUBLIC_URL" ]]; then
  info "smoke GET ${PUBLIC_URL}/mcp/health"
  curl -fsS --max-time 20 "${PUBLIC_URL}/mcp/health" >/dev/null \
    || die "post-rollback health check failed at ${PUBLIC_URL}/mcp/health"
  info "post-rollback health ok"
else
  info "no PUBLIC_URL/MCP_PUBLIC_URL — skipped post-rollback smoke (run scripts/status.sh to verify)"
fi

info "Done. To verify: SERVER=${SERVER} ./scripts/status.sh"
