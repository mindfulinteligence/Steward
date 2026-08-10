#!/usr/bin/env bash
# First-time multi-tenant host setup. Idempotent — safe to re-run.
#
# Usage:
#   SERVER=ubuntu@NEW_HOST ./scripts/bootstrap-server.sh
#   SERVER=ubuntu@NEW_HOST ACS_IMAGE_TAG=abc123 ./scripts/bootstrap-server.sh --start
#
# Secrets: Infisical (not a filled .env). After bootstrap:
#   1. Install machine identity into REMOTE_DIR/.infisical.env (mode 600)
#   2. Thin REMOTE_DIR/.env from .env.multitenant (non-secret config)
#   3. SERVER=… ACS_IMAGE_TAG=… ./scripts/bootstrap-server.sh --start
#      or: SERVER=… ./scripts/deploy.sh --resume
set -euo pipefail

SERVER="${SERVER:-}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/steward_acs}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.multitenant.yml}"
CADDY_FILE="${CADDY_FILE:-Caddyfile.multitenant}"
ACS_IMAGE_TAG="${ACS_IMAGE_TAG:-multitenant}"
START=0

for arg in "$@"; do
  case "$arg" in
    --start) START=1 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SERVER" ]]; then
  echo "ERROR: SERVER must be set (e.g. SERVER=ubuntu@203.0.113.10)" >&2
  exit 1
fi

info() { echo "[bootstrap] $*"; }

info "Installing Docker Engine + Compose plugin on ${SERVER} (noop if present)"
ssh "${SERVER}" 'bash -s' <<'REMOTE'
set -euo pipefail
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER" || true
fi
docker version >/dev/null
docker compose version >/dev/null

if ! command -v infisical >/dev/null 2>&1; then
  curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash
  sudo apt-get install -y infisical
fi
infisical --version >/dev/null
REMOTE

info "Creating ${REMOTE_DIR} and syncing compose + Infisical wrapper"
ssh "${SERVER}" "mkdir -p '${REMOTE_DIR}/priv' '${REMOTE_DIR}/certs' '${REMOTE_DIR}/scripts/lib' '${REMOTE_DIR}/caddy'"
scp "${COMPOSE_FILE}" "${CADDY_FILE}" "${SERVER}:${REMOTE_DIR}/"
scp scripts/infisical-compose.sh "${SERVER}:${REMOTE_DIR}/scripts/"
scp scripts/lib/acs_bluegreen.sh "${SERVER}:${REMOTE_DIR}/scripts/lib/"
scp caddy/acs_upstream.caddyfile "${SERVER}:${REMOTE_DIR}/caddy/"
ssh "${SERVER}" "chmod 755 '${REMOTE_DIR}/scripts/infisical-compose.sh'"
if [[ -f docker-compose.postgres.yml ]]; then
  scp docker-compose.postgres.yml "${SERVER}:${REMOTE_DIR}/"
fi
if [[ -f priv/orgs.yaml ]]; then
  scp priv/orgs.yaml "${SERVER}:${REMOTE_DIR}/priv/orgs.yaml"
fi
if [[ -d otel ]]; then
  scp -r otel "${SERVER}:${REMOTE_DIR}/"
fi

if ssh "${SERVER}" "test -f '${REMOTE_DIR}/.env'"; then
  info "Remote thin .env already present — leaving it"
else
  info "Seeding thin .env from .env.multitenant (non-secret config only)"
  scp .env.multitenant "${SERVER}:${REMOTE_DIR}/.env"
  ssh "${SERVER}" "chmod 600 '${REMOTE_DIR}/.env'"
fi

# Pin image tag for first pull
ssh "${SERVER}" "cd '${REMOTE_DIR}' &&
  if grep -q '^ACS_IMAGE_TAG=' .env 2>/dev/null; then
    sed -i 's/^ACS_IMAGE_TAG=.*/ACS_IMAGE_TAG=${ACS_IMAGE_TAG}/' .env
  else
    echo 'ACS_IMAGE_TAG=${ACS_IMAGE_TAG}' >> .env
  fi"

info "Bootstrap files ready on ${SERVER}:${REMOTE_DIR}"
info "Required before --start:"
info "  1. Write ${REMOTE_DIR}/.infisical.env (mode 600) with INFISICAL_UNIVERSAL_AUTH_CLIENT_ID/_SECRET"
info "  2. Confirm Infisical prod secrets are filled (placeholders REPLACE_ME are skipped)"
info "  3. Open 80/443, DNS → host"

if [[ "$START" -eq 1 ]]; then
  info "Starting stack with ACS_IMAGE_TAG=${ACS_IMAGE_TAG}"
  if ! ssh "${SERVER}" "test -f '${REMOTE_DIR}/.infisical.env'"; then
    echo "ERROR: ${REMOTE_DIR}/.infisical.env missing — add machine identity first" >&2
    exit 1
  fi
  SERVER="${SERVER}" REMOTE_DIR="${REMOTE_DIR}" ACS_IMAGE_TAG="${ACS_IMAGE_TAG}" \
    ./scripts/deploy.sh --resume
else
  info "When Infisical agent env is ready: SERVER=${SERVER} ACS_IMAGE_TAG=${ACS_IMAGE_TAG} ./scripts/bootstrap-server.sh --start"
  info "Or ongoing updates: SERVER=${SERVER} ./scripts/deploy.sh"
fi
