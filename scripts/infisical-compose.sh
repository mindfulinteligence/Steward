#!/usr/bin/env bash
# Run docker compose with Infisical secrets injected for multi-tenant prod.
#
# Local: do not use this — use plain `.env` + `docker compose` / `mix phx.server`.
# Prod: secrets come from Infisical (project steward_prod / env prod).
#       Non-secret pins (ACS_IMAGE_TAG, hosts) stay in a thin `.env` on the host.
#
# Host setup (once):
#   1. Install Infisical CLI
#   2. Write .infisical.env (mode 600) with:
#        INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=...
#        INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=...
#      (read-only machine identity for this project)
#   3. Keep thin .env with non-secrets only (see .env.multitenant)
#
# Usage (from REMOTE_DIR on the server):
#   ./scripts/infisical-compose.sh -f docker-compose.multitenant.yml up -d
#
# Blank / REPLACE_ME Infisical values are skipped so optional placeholders stay harmless.
set -euo pipefail

INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-6395f4c0-45f2-4f54-802d-26a55bbb9555}"
INFISICAL_ENV="${INFISICAL_ENV:-prod}"
# Optional secret folder path inside the env (e.g. /4sg for the second server).
# Secrets live under env prod by default; a per-server folder (prod//4sg) lets a
# second host override only its own DATABASE_URL / AXIOM_LOGS / tokens while
# sharing the rest, without needing a new Infisical environment.
INFISICAL_PATH="${INFISICAL_PATH:-}"
INFISICAL_HOST_URL="${INFISICAL_HOST_URL:-https://app.infisical.com}"
AGENT_ENV_FILE="${INFISICAL_AGENT_ENV:-.infisical.env}"
SECRETS_FILE="${INFISICAL_SECRETS_FILE:-.env.infisical}"
CONFIG_ENV_FILE="${CONFIG_ENV_FILE:-.env}"

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ -f "$AGENT_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  # Only KEY=VALUE lines; ignore comments/blank
  # shellcheck disable=SC1091
  . "$AGENT_ENV_FILE"
  set +a
fi

command -v infisical >/dev/null 2>&1 || die "infisical CLI not found (install on the prod host)"

[[ -n "${INFISICAL_UNIVERSAL_AUTH_CLIENT_ID:-}" ]] ||
  die "set INFISICAL_UNIVERSAL_AUTH_CLIENT_ID (e.g. in ${AGENT_ENV_FILE})"
[[ -n "${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:-}" ]] ||
  die "set INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET (e.g. in ${AGENT_ENV_FILE})"

export INFISICAL_TOKEN
INFISICAL_TOKEN=$(
  infisical login \
    --method=universal-auth \
    --client-id="${INFISICAL_UNIVERSAL_AUTH_CLIENT_ID}" \
    --client-secret="${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET}" \
    --silent --plain
) || die "infisical login failed"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT HUP INT TERM

infisical export \
  --token="$INFISICAL_TOKEN" \
  --projectId="$INFISICAL_PROJECT_ID" \
  --env="$INFISICAL_ENV" \
  ${INFISICAL_PATH:+--path="$INFISICAL_PATH"} \
  --format=dotenv \
  >"$tmp" || die "infisical export failed"

umask 077
: >"$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

# Keep placeholders in Infisical, but never inject empty / REPLACE_ME into Compose.
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    ''|\#*) continue ;;
  esac
  key=${line%%=*}
  val=${line#*=}
  # Strip surrounding quotes if present
  if [[ "$val" == \"*\" && "$val" == *\" ]]; then
    val=${val:1:-1}
  elif [[ "$val" == \'*\' && "$val" == *\' ]]; then
    val=${val:1:-1}
  fi
  case "$val" in
    ''|REPLACE_ME|replace_me) continue ;;
  esac
  printf '%s=%s\n' "$key" "$val" >>"$SECRETS_FILE"
done <"$tmp"

env_files=()
[[ -f "$CONFIG_ENV_FILE" ]] && env_files+=(--env-file "$CONFIG_ENV_FILE")
env_files+=(--env-file "$SECRETS_FILE")

# Infisical file last so real secrets win over any accidental overlap in thin .env
exec docker compose "${env_files[@]}" "$@"
