#!/usr/bin/env bash
# Deterministic deploy: build once, tag by Git SHA, push, cut over in one SSH.
#
# Usage:
#   SERVER=ubuntu@HOST ./scripts/deploy.sh              # full build+push+cutover
#   ./scripts/deploy.sh --push-only                     # build+push only (CI)
#   SERVER=ubuntu@HOST ./scripts/deploy.sh --resume     # cutover only (image already pushed)
#   SERVER=ubuntu@HOST ./scripts/deploy.sh --rollback   # pin previous tag and cut over
#
# Env:
#   ALLOW_DIRTY=1   allow dirty tree (forces unique tag + --no-cache)
#   SKIP_SMOKE=1    skip public health / optional DCR / chat tools smoke
#   PUBLIC_URL=     override smoke base URL (default: MCP_PUBLIC_URL from remote .env)
#   SMOKE_API_KEY=  developer key for chat tools/list smoke (skipped if unset)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REGISTRY="${REGISTRY:-naharemete/steward_acs}"
SERVER="${SERVER:-}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.multitenant.yml}"
CADDY_FILE="${CADDY_FILE:-Caddyfile.multitenant}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/steward_acs}"
MODE="deploy"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
SKIP_SMOKE="${SKIP_SMOKE:-0}"
HEALTH_WAIT_SECONDS="${HEALTH_WAIT_SECONDS:-300}"
FORCE_NO_CACHE="${FORCE_NO_CACHE:-0}"
BUILD_NO_CACHE=()
if [[ "$FORCE_NO_CACHE" == "1" ]]; then
  BUILD_NO_CACHE=(--no-cache)
fi

for arg in "$@"; do
  case "$arg" in
    --push-only) MODE="push-only" ;;
    --resume) MODE="resume" ;;
    --rollback) MODE="rollback" ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $arg (use --push-only, --resume, --rollback, or --help)" >&2
      exit 1
      ;;
  esac
done

if [[ "$MODE" != "push-only" && -z "$SERVER" ]]; then
  echo "ERROR: SERVER must be set (e.g. SERVER=ubuntu@139.99.89.23)" >&2
  exit 1
fi

info() { echo "[deploy] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

DIRTY=0
if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
  DIRTY=1
fi

GIT_SHA="${GIT_SHA:-$(git rev-parse --short=12 HEAD)}"
DIRTY_FLAG="clean"

case "$MODE" in
  deploy|push-only)
    if [[ "$DIRTY" -eq 1 && "$ALLOW_DIRTY" != "1" ]]; then
      die "refusing dirty working tree (commit first, or ALLOW_DIRTY=1 for a one-off hotfix)"
    fi
    if [[ "$DIRTY" -eq 1 ]]; then
      DIRTY_FLAG="dirty"
      ACS_IMAGE_TAG="${ACS_IMAGE_TAG:-${GIT_SHA}-dirty-$(date -u +%Y%m%d%H%M%S)}"
      BUILD_NO_CACHE=(--no-cache)
      info "ALLOW_DIRTY=1: tagging ${ACS_IMAGE_TAG} and building with --no-cache"
    else
      ACS_IMAGE_TAG="${ACS_IMAGE_TAG:-$GIT_SHA}"
      if [[ "$FORCE_NO_CACHE" == "1" ]]; then
        info "FORCE_NO_CACHE=1: building ${ACS_IMAGE_TAG} with --no-cache"
      fi
    fi
    ;;
  resume|rollback)
    ACS_IMAGE_TAG="${ACS_IMAGE_TAG:-}"
    ;;
esac

COMPOSE_ARGS=(-f "${COMPOSE_FILE}")
if [[ "${WITH_POSTGRES:-false}" == "true" ]]; then
  COMPOSE_ARGS+=(-f docker-compose.postgres.yml)
fi
WITH_POSTGRES="${WITH_POSTGRES:-false}"

# --- build + push (deploy / push-only) ---
if [[ "$MODE" == "deploy" || "$MODE" == "push-only" ]]; then
  info "Building ${REGISTRY}:${ACS_IMAGE_TAG} (git=${GIT_SHA} dirty=${DIRTY_FLAG})"
  docker build \
    "${BUILD_NO_CACHE[@]}" \
    --target release \
    --build-arg REPO_ADAPTER=postgres \
    --build-arg GIT_SHA="${GIT_SHA}" \
    --build-arg GIT_DIRTY="${DIRTY_FLAG}" \
    --build-arg SECRET_KEY_BASE="${SECRET_KEY_BASE:-build_time_secret_key_base_not_used_at_runtime}" \
    -t "${REGISTRY}:${ACS_IMAGE_TAG}" \
    -t "${REGISTRY}:multitenant" \
    .

  info "Pushing ${REGISTRY}:${ACS_IMAGE_TAG} and :multitenant"
  docker push "${REGISTRY}:${ACS_IMAGE_TAG}"
  docker push "${REGISTRY}:multitenant"

  if [[ "$MODE" == "push-only" ]]; then
    info "push-only done tag=${ACS_IMAGE_TAG}"
    echo "ACS_IMAGE_TAG=${ACS_IMAGE_TAG}"
    exit 0
  fi
fi

# --- sync compose/caddy (deploy + resume; rollback keeps remote compose) ---
if [[ "$MODE" != "rollback" ]]; then
  info "Syncing compose/caddy bundle to ${SERVER}:${REMOTE_DIR}"
  ssh "${SERVER}" "mkdir -p '${REMOTE_DIR}/priv' '${REMOTE_DIR}/scripts/lib' '${REMOTE_DIR}/caddy'"
  scp "${COMPOSE_FILE}" "${CADDY_FILE}" "${SERVER}:${REMOTE_DIR}/"
  scp scripts/infisical-compose.sh "${SERVER}:${REMOTE_DIR}/scripts/"
  scp scripts/lib/acs_bluegreen.sh "${SERVER}:${REMOTE_DIR}/scripts/lib/"
  # Upstream snippet: only seed if missing so we do not clobber the live blue/green pointer.
  ssh "${SERVER}" "test -f '${REMOTE_DIR}/caddy/acs_upstream.caddyfile'" || \
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
fi

# --- remote blue/green cutover (pull idle slot → healthy → Caddy reload → stop old) ---
# Pass flags as separate argv (never a leading "-f …" string — ssh/bash can resplit it).
# shellcheck disable=SC2029
CUTOVER=$(ssh "${SERVER}" bash -s -- \
  "$MODE" "$REMOTE_DIR" "$COMPOSE_FILE" "$WITH_POSTGRES" "${ACS_IMAGE_TAG:-}" "$HEALTH_WAIT_SECONDS" <<'REMOTE'
set -euo pipefail
MODE="$1"
REMOTE_DIR="$2"
COMPOSE_FILE="$3"
WITH_POSTGRES="$4"
ACS_IMAGE_TAG="${5:-}"
HEALTH_WAIT_SECONDS="${6:-300}"

cd "$REMOTE_DIR"
# shellcheck source=scripts/lib/acs_bluegreen.sh
source ./scripts/lib/acs_bluegreen.sh

COMPOSE_ARGS=(-f "$COMPOSE_FILE")
if [[ "$WITH_POSTGRES" == "true" ]]; then
  COMPOSE_ARGS+=(-f docker-compose.postgres.yml)
fi

compose() {
  if [[ -x ./scripts/infisical-compose.sh ]]; then
    ./scripts/infisical-compose.sh "${COMPOSE_ARGS[@]}" "$@"
  else
    echo "ERROR: scripts/infisical-compose.sh missing — sync deploy bundle" >&2
    exit 1
  fi
}

env_get() {
  local key="$1"
  [[ -f .env ]] || return 1
  grep -E "^${key}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true
}

env_set() {
  local key="$1" val="$2"
  touch .env
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

wait_healthy() {
  local name="$1" status=starting
  local attempts=$((HEALTH_WAIT_SECONDS / 2))
  for _ in $(seq 1 "$attempts"); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo starting)
    [[ "$status" == "healthy" ]] && break
    sleep 2
  done
  echo "$status"
}

report_unhealthy() {
  local name="$1"
  echo "ERROR: ${name} did not become healthy within ${HEALTH_WAIT_SECONDS}s" >&2
  docker inspect -f 'container={{.Name}} state={{.State.Status}} exit={{.State.ExitCode}} health={{.State.Health.Status}}' "$name" 2>/dev/null || true
  docker inspect -f '{{range .State.Health.Log}}{{printf "health exit=%d output=%s\\n" .ExitCode .Output}}{{end}}' "$name" 2>/dev/null || true
  docker logs --tail 120 "$name" 2>&1 || true
}

current_tag="$(env_get ACS_IMAGE_TAG || true)"
prev_tag="$(env_get ACS_IMAGE_TAG_PREV || true)"

case "$MODE" in
  rollback)
    [[ -n "$prev_tag" ]] || { echo "ERROR: ACS_IMAGE_TAG_PREV missing; nothing to roll back to" >&2; exit 1; }
    ACS_IMAGE_TAG="$prev_tag"
    echo "[remote] rollback to ACS_IMAGE_TAG=${ACS_IMAGE_TAG} (was ${current_tag:-none})"
    ;;
  resume)
    if [[ -z "$ACS_IMAGE_TAG" ]]; then
      ACS_IMAGE_TAG="$current_tag"
    fi
    [[ -n "$ACS_IMAGE_TAG" ]] || { echo "ERROR: no ACS_IMAGE_TAG for --resume (set ACS_IMAGE_TAG= or pin .env)" >&2; exit 1; }
    echo "[remote] resume cutover ACS_IMAGE_TAG=${ACS_IMAGE_TAG}"
    ;;
  deploy)
    [[ -n "$ACS_IMAGE_TAG" ]] || { echo "ERROR: ACS_IMAGE_TAG empty" >&2; exit 1; }
    echo "[remote] deploy cutover ACS_IMAGE_TAG=${ACS_IMAGE_TAG}"
    ;;
esac

# Remember previous pin before overwriting (skip if same tag / garbage).
if [[ -n "${current_tag:-}" && "$current_tag" != "$ACS_IMAGE_TAG" && "$current_tag" != *.yml && "$current_tag" != *.yaml ]]; then
  env_set ACS_IMAGE_TAG_PREV "$current_tag"
fi
env_set ACS_IMAGE_TAG "$ACS_IMAGE_TAG"

# Active slot: blue|green. Empty = cold start or legacy single container.
ACTIVE_SLOT="$(env_get ACS_ACTIVE_SLOT || true)"
case "${ACTIVE_SLOT}" in
  blue|green) ;;
  *)
    if docker inspect steward_acs >/dev/null 2>&1; then
      ACTIVE_SLOT=""
      echo "[remote] legacy container steward_acs present — first blue/green cutover"
    elif docker inspect steward_acs_blue >/dev/null 2>&1 && \
         [[ "$(docker inspect -f '{{.State.Running}}' steward_acs_blue 2>/dev/null || echo false)" == true ]]; then
      ACTIVE_SLOT="blue"
    elif docker inspect steward_acs_green >/dev/null 2>&1 && \
         [[ "$(docker inspect -f '{{.State.Running}}' steward_acs_green 2>/dev/null || echo false)" == true ]]; then
      ACTIVE_SLOT="green"
    else
      ACTIVE_SLOT=""
      echo "[remote] no active slot — cold start on blue"
    fi
    ;;
esac

if [[ -z "$ACTIVE_SLOT" ]]; then
  NEXT_SLOT="blue"
else
  NEXT_SLOT="$(acs_other_slot "$ACTIVE_SLOT")"
fi
NEXT_SVC="$(acs_service "$NEXT_SLOT")"
NEXT_CTR="$(acs_container "$NEXT_SLOT")"
echo "[remote] blue/green active=${ACTIVE_SLOT:-legacy} next=${NEXT_SLOT}"

echo "[remote] preflight compose config"
ACS_IMAGE_TAG="$ACS_IMAGE_TAG" compose config >/dev/null

echo "[remote] pull ${NEXT_SVC}"
ACS_IMAGE_TAG="$ACS_IMAGE_TAG" compose pull "$NEXT_SVC"

echo "[remote] up ${NEXT_SVC} (idle slot — traffic still on active)"
# Do not --remove-orphans yet: legacy steward_acs / previous slot must keep serving.
ACS_IMAGE_TAG="$ACS_IMAGE_TAG" compose up -d --no-build --no-deps "$NEXT_SVC"

# Host metrics sidecar when COMPOSE_PROFILES includes axiom (see .env.multitenant).
if ACS_IMAGE_TAG="$ACS_IMAGE_TAG" compose config --services 2>/dev/null | grep -qx otel_collector; then
  echo "[remote] up otel_collector"
  ACS_IMAGE_TAG="$ACS_IMAGE_TAG" compose up -d --no-build --pull missing otel_collector
fi

echo "[remote] waiting for ${NEXT_CTR} healthy"
STATUS="$(wait_healthy "$NEXT_CTR")"
if [[ "$STATUS" != "healthy" ]]; then
  report_unhealthy "$NEXT_CTR"
  exit 1
fi

# Seed org registry into the data volume when missing (shared volume — either slot).
if ! docker exec "$NEXT_CTR" sh -c 'test -s /data/orgs.yaml' 2>/dev/null; then
  if [[ -f priv/orgs.yaml ]]; then
    docker cp priv/orgs.yaml "${NEXT_CTR}:/data/orgs.yaml" || true
  fi
fi

mkdir -p caddy
acs_write_upstream caddy/acs_upstream.caddyfile "$NEXT_SLOT"

CADDY_HASH="$(acs_caddy_bundle_hash .)"
PREV_CADDY_HASH="$(env_get CADDY_BUNDLE_HASH || true)"
CADDY_RUNNING=0
docker inspect steward_caddy >/dev/null 2>&1 && CADDY_RUNNING=1

if [[ "$CADDY_RUNNING" -eq 0 || "$CADDY_HASH" != "$PREV_CADDY_HASH" ]]; then
  echo "[remote] caddy up (missing or Caddyfile/certs changed)"
  ACS_IMAGE_TAG="$ACS_IMAGE_TAG" compose up -d --no-build --force-recreate caddy
else
  echo "[remote] caddy reload upstream → ${NEXT_CTR} (skip recreate)"
  if ! docker exec steward_caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
    echo "[remote] caddy reload failed — falling back to recreate"
    ACS_IMAGE_TAG="$ACS_IMAGE_TAG" compose up -d --no-build --force-recreate caddy
  fi
fi
env_set CADDY_BUNDLE_HASH "$CADDY_HASH"
env_set ACS_ACTIVE_SLOT "$NEXT_SLOT"

# Stop previous traffic sources after switch.
if [[ -n "$ACTIVE_SLOT" ]]; then
  OLD_SVC="$(acs_service "$ACTIVE_SLOT")"
  echo "[remote] stop previous slot ${OLD_SVC}"
  ACS_IMAGE_TAG="$ACS_IMAGE_TAG" compose stop "$OLD_SVC" || true
fi
if docker inspect steward_acs >/dev/null 2>&1; then
  echo "[remote] remove legacy steward_acs container"
  docker stop steward_acs >/dev/null 2>&1 || true
  docker rm steward_acs >/dev/null 2>&1 || true
fi

# Drop orphans (old single-service name, stopped extras) now that traffic is on next.
ACS_IMAGE_TAG="$ACS_IMAGE_TAG" compose up -d --no-build --remove-orphans --no-deps "$NEXT_SVC" caddy

DIGEST=$(docker inspect -f '{{.Image}}' "$NEXT_CTR")
REV=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$NEXT_CTR" 2>/dev/null || true)
DIRTY_L=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.dirty"}}' "$NEXT_CTR" 2>/dev/null || true)
PUBLIC_URL=$(env_get MCP_PUBLIC_URL || true)
FIXED_DCR=$(env_get OAUTH_FIXED_DCR_CLIENT_ID || true)

echo "REMOTE_DIGEST=${DIGEST}"
echo "REMOTE_HEALTH=${STATUS}"
echo "REMOTE_TAG=${ACS_IMAGE_TAG}"
echo "REMOTE_REV=${REV:-n/a}"
echo "REMOTE_DIRTY=${DIRTY_L:-n/a}"
echo "REMOTE_PUBLIC_URL=${PUBLIC_URL:-}"
echo "REMOTE_FIXED_DCR_SET=$([ -n "${FIXED_DCR:-}" ] && echo yes || echo no)"
echo "REMOTE_FIXED_DCR_ID=${FIXED_DCR:-}"
echo "REMOTE_ACTIVE_SLOT=${NEXT_SLOT}"
echo "REMOTE_ACTIVE_CONTAINER=${NEXT_CTR}"

[[ "$STATUS" == "healthy" ]] || { echo "ERROR: container not healthy (${STATUS})" >&2; exit 1; }
REMOTE
)

info "cutover output:"
echo "$CUTOVER"

REMOTE_HEALTH=$(echo "$CUTOVER" | awk -F= '/^REMOTE_HEALTH=/{print $2; exit}')
REMOTE_TAG=$(echo "$CUTOVER" | awk -F= '/^REMOTE_TAG=/{print $2; exit}')
REMOTE_PUBLIC_URL=$(echo "$CUTOVER" | awk -F= '/^REMOTE_PUBLIC_URL=/{print $2; exit}')
REMOTE_FIXED_DCR_SET=$(echo "$CUTOVER" | awk -F= '/^REMOTE_FIXED_DCR_SET=/{print $2; exit}')
REMOTE_FIXED_DCR_ID=$(echo "$CUTOVER" | awk -F= '/^REMOTE_FIXED_DCR_ID=/{print $2; exit}')
REMOTE_REV=$(echo "$CUTOVER" | awk -F= '/^REMOTE_REV=/{print $2; exit}')
REMOTE_ACTIVE_SLOT=$(echo "$CUTOVER" | awk -F= '/^REMOTE_ACTIVE_SLOT=/{print $2; exit}')
REMOTE_ACTIVE_CONTAINER=$(echo "$CUTOVER" | awk -F= '/^REMOTE_ACTIVE_CONTAINER=/{print $2; exit}')

[[ "$REMOTE_HEALTH" == "healthy" ]] || die "cutover reported unhealthy"

# --- smoke (public) ---
if [[ "$SKIP_SMOKE" == "1" ]]; then
  info "SKIP_SMOKE=1 — skipping public smoke checks"
else
  PUBLIC_URL="${PUBLIC_URL:-$REMOTE_PUBLIC_URL}"
  PUBLIC_URL="${PUBLIC_URL%/}"
  [[ -n "$PUBLIC_URL" ]] || die "no PUBLIC_URL / MCP_PUBLIC_URL for smoke (set PUBLIC_URL=https://…)"

  info "smoke GET ${PUBLIC_URL}/mcp/health"
  curl -fsS --max-time 20 "${PUBLIC_URL}/mcp/health" >/dev/null

  if [[ "$REMOTE_FIXED_DCR_SET" == "yes" && -n "${REMOTE_FIXED_DCR_ID}" ]]; then
    info "smoke POST ${PUBLIC_URL}/oidc/register (expect fixed client)"
    got=$(curl -fsS --max-time 30 -X POST "${PUBLIC_URL}/oidc/register" \
      -H 'content-type: application/json' \
      -d '{"client_name":"deploy-smoke","redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}' \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("client_id",""))')
    if [[ "$got" != "$REMOTE_FIXED_DCR_ID" ]]; then
      die "DCR smoke failed: got client_id=${got:-empty} want ${REMOTE_FIXED_DCR_ID} (Caddy must not proxy /oidc/register to Auth0; compose must pass OAUTH_FIXED_DCR_CLIENT_ID)"
    fi
    info "DCR smoke ok (fixed client)"
  else
    info "OAUTH_FIXED_DCR_CLIENT_ID unset on server — skipping DCR smoke"
  fi

  if [[ -n "${SMOKE_API_KEY:-}" && -n "${REMOTE_ACTIVE_CONTAINER:-}" ]]; then
    info "fetch chat_surface from ${REMOTE_ACTIVE_CONTAINER}"
    EXPECTED_CHAT_TOOLS=$(
      ssh "$SERVER" \
        "docker exec ${REMOTE_ACTIVE_CONTAINER} /app/bin/steward_acs eval 'IO.puts(Enum.join(Acs.MCP.CoreToolRoles.chat_surface(), \",\"))'" \
        | tr -d '\r' | tail -n 1
    )
    [[ -n "$EXPECTED_CHAT_TOOLS" ]] || die "empty chat_surface from release eval"
    PUBLIC_URL="$PUBLIC_URL" SMOKE_API_KEY="$SMOKE_API_KEY" \
      EXPECTED_CHAT_TOOLS="$EXPECTED_CHAT_TOOLS" ALLOW_SKIP=0 \
      "$ROOT/scripts/smoke-chat-tools.sh" \
      || die "chat tools/list smoke failed"
  else
    info "SMOKE_API_KEY or active container unset — skipping chat tools/list smoke"
  fi
fi

info "Deployed tag=${REMOTE_TAG} rev=${REMOTE_REV} health=${REMOTE_HEALTH} slot=${REMOTE_ACTIVE_SLOT:-?} ctr=${REMOTE_ACTIVE_CONTAINER:-?}"
info "Prod path: push/merge to prod → GitHub Actions Deploy (cutover uses this --resume logic)"
info "Rollback: SERVER=${SERVER} ./scripts/deploy.sh --rollback"
info "Resume:   SERVER=${SERVER} ACS_IMAGE_TAG=${REMOTE_TAG} ./scripts/deploy.sh --resume"
