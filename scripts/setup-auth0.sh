#!/usr/bin/env bash
# Configure Auth0 tenant for MCP connectors — Claude, ChatGPT, OpenCode + any via EXTRA_CONNECTOR_CALLBACKS.
#
# Required env:
#   AUTH0_M2M_CLIENT_ID      Machine-to-Machine app client ID
#   AUTH0_M2M_CLIENT_SECRET  Machine-to-Machine app client secret
#
# Optional env:
#   AUTH0_DOMAIN               default: dev-jw5wgp2b.us.auth0.com
#   AUTH0_AUDIENCE             default: https://prod.stewardacs.xyz/mcp/sse
#   AUTH0_USER_EMAIL           create this user if set (passwordless email connection)
#   AUTH0_USER_PASSWORD        ignored for passwordless; only used if AUTH0_DB_CONNECTION is a DB conn
#   AUTH0_DB_CONNECTION        default: email (passwordless OTP via New Universal Login)
#   SKIP_CLAUDE_APP            set to 1 to skip manual Claude OAuth app creation
#   OAUTH_FIXED_DCR_CLIENT_ID   ACS fixed DCR Auth0 app — connector callbacks are synced here (see registry)
#   EXTRA_CONNECTOR_CALLBACKS   space-separated extra redirect URIs for any connector (CHATGPT_EXTRA_CALLBACKS alias)
#
# Login model (Claude/ChatGPT Connectors + Steward web):
#   New Universal Login + Identifier First. Email passwordless OTP and/or
#   Google — whichever connections are enabled on the client. ACS relinks by
#   verified email when Auth0 `sub` differs across connections. True Auth0
#   "magic links" require Classic Login and are not used here.
#
# Fixed DCR note (universal rule):
#   ACS `/oidc/register` returns OAUTH_FIXED_DCR_CLIENT_ID for every connector,
#   but Auth0 validates redirect_uri against that app's Allowed Callback URLs —
#   the DCR-echoed redirect_uris are ignored. So EVERY connector's redirect URI
#   must be in the Connector Callback Registry below. Add new URIs there (or via
#   EXTRA_CONNECTOR_CALLBACKS) and re-run; use --check to verify before connecting.
#
set -euo pipefail

# --check / -c: verify connector callbacks are allowlisted; make no changes.
CHECK_ONLY="${CHECK_ONLY:-0}"
if [[ "$#" -gt 0 ]]; then
  for a in "$@"; do
    case "$a" in
      --check|-c) CHECK_ONLY=1 ;;
    esac
  done
fi

DOMAIN="${AUTH0_DOMAIN:-dev-jw5wgp2b.us.auth0.com}"
AUDIENCE="${AUTH0_AUDIENCE:-https://prod.stewardacs.xyz/mcp/sse}"
MGMT_AUDIENCE="https://${DOMAIN}/api/v2/"
DB_CONNECTION="${AUTH0_DB_CONNECTION:-email}"
# ── Connector Callback Registry (universal) ──────────────────────────────────
# Every connector that uses the fixed DCR client must have its redirect URI here.
# To add a new connector: add its callback to this registry (or pass it ad-hoc
# via EXTRA_CONNECTOR_CALLBACKS) and re-run this script — Auth0 is updated for
# ALL fixed/connector apps in one pass.
CLAUDE_CALLBACK="https://claude.ai/api/mcp/auth_callback"
# OpenCode remote MCP OAuth redirect (fixed port 19876, path /mcp/oauth/callback).
OPENCODE_CALLBACK="http://127.0.0.1:19876/mcp/oauth/callback"
# ACS OAuth broker callback (lib/acs/mcp/oauth/broker.ex). The broker accepts
# ANY client redirect_uri and relays the Auth0 handshake through this single
# per-host callback, so new connectors need NO Auth0 registration. Set
# BROKER_CALLBACK for each tenant host, e.g. https://anantha.stewardacs.xyz/oauth/callback.
BROKER_CALLBACK="${BROKER_CALLBACK:-https://anantha.stewardacs.xyz/oauth/callback}"
# ChatGPT connector + Apps manage redirects (OpenAI docs / Auth0 MCP guides).
# Per-app Apps SDK URLs look like https://chatgpt.com/connector/oauth/{id} —
# Auth0 has no path wildcards; pass those via EXTRA_CONNECTOR_CALLBACKS.
CHATGPT_CALLBACKS=(
  "https://chatgpt.com/connector_platform_oauth_redirect"
  "https://platform.openai.com/apps-manage/oauth"
)
# shellcheck disable=SC2206
EXTRA_CONNECTOR_CALLBACKS=( ${EXTRA_CONNECTOR_CALLBACKS:-} ${CHATGPT_EXTRA_CALLBACKS:-} )
CONNECTOR_CALLBACKS=("$CLAUDE_CALLBACK" "$OPENCODE_CALLBACK" "$BROKER_CALLBACK" "${CHATGPT_CALLBACKS[@]}" "${EXTRA_CONNECTOR_CALLBACKS[@]}")

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[auth0]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
fail()  { echo -e "${RED}[fail]${NC} $*" >&2; exit 1; }

# Optional: read M2M creds from certs/Oauth.md
if [[ -f certs/Oauth.md ]]; then
  if [[ -z "${AUTH0_M2M_CLIENT_ID:-}" ]]; then
    AUTH0_M2M_CLIENT_ID=$(python3 -c "import re; t=open('certs/Oauth.md').read(); m=re.search(r'\"client_id\":\"([^\"]+)\"', t); print(m.group(1) if m else '')")
  fi
  if [[ -z "${AUTH0_M2M_CLIENT_SECRET:-}" ]]; then
    AUTH0_M2M_CLIENT_SECRET=$(python3 -c "import re; t=open('certs/Oauth.md').read(); m=re.search(r'\"client_secret\":\"([^\"]+)\"', t); print(m.group(1) if m else '')")
  fi
fi

[[ -n "${AUTH0_M2M_CLIENT_ID:-}" ]] || fail "Set AUTH0_M2M_CLIENT_ID (or add to certs/Oauth.md)"
[[ -n "${AUTH0_M2M_CLIENT_SECRET:-}" ]] || fail "Set AUTH0_M2M_CLIENT_SECRET (or add to certs/Oauth.md)"

api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --fail-with-body -X "$method" \
    "https://${DOMAIN}/api/v2${path}" \
    -H "authorization: Bearer ${MGMT_TOKEN}" \
    -H "content-type: application/json" \
    "$@"
}

# Sync the Connector Callback Registry onto an Auth0 app (fixed DCR + connector apps).
# In CHECK_ONLY mode it reports missing callbacks instead of PATCHing.
ensure_connector_callbacks() {
  local cid="$1" label="$2"
  [[ -n "$cid" ]] || return 0
  local current missing
  current=$(api GET "/clients/${cid}?fields=callbacks&include_fields=true" | python3 -c "
import sys, json
print(json.dumps(json.load(sys.stdin).get('callbacks') or []))
")
  missing=$(python3 -c "
import json, sys
have = set(json.loads(sys.argv[1]))
want = [u for u in sys.argv[2:] if u]
missing = sorted(set(want) - have)
if missing:
    print('\\n'.join(missing))
" "$current" "${CONNECTOR_CALLBACKS[@]}")
  if [[ -n "$missing" ]]; then
    if [[ "$CHECK_ONLY" == "1" ]]; then
      info "CHECK: ${label} (${cid}) is missing callbacks:"
      echo "$missing" | sed 's/^/    - /'
      return 1
    fi
    local desired
    desired=$(python3 -c "
import json, sys
have = set(json.loads(sys.argv[1]))
want = [u for u in sys.argv[2:] if u]
print(json.dumps(sorted(have | set(want))))
" "$current" "${CONNECTOR_CALLBACKS[@]}")
    api PATCH "/clients/${cid}" -d "{\"callbacks\": ${desired}}" >/dev/null
    ok "Synced callbacks on ${label} (${cid}): $(echo "$missing" | tr '\n' ' ')"
  else
    ok "Callbacks up-to-date on ${label} (${cid})"
  fi
}

# Client IDs that must carry the registry: fixed DCR + known connector apps.
connector_client_ids() {
  local fixed="${OAUTH_FIXED_DCR_CLIENT_ID:-}"
  api GET "/clients?fields=client_id,name&include_fields=true&per_page=100" | python3 -c "
import sys, json
names = {'Claude.ai MCP', 'steward_acs_mcp'}
fixed = sys.argv[1]
seen = set()
for c in json.load(sys.stdin):
    cid = c.get('client_id') or ''
    if (c.get('name') in names or (fixed and cid == fixed)) and cid not in seen:
        seen.add(cid)
        print(cid)
if fixed and fixed not in seen:
    print(fixed)
" "$fixed"
}

info "Fetching Management API token..."
TOKEN_RESP=$(curl -sS --fail-with-body -X POST "https://${DOMAIN}/oauth/token" \
  -H "content-type: application/json" \
  -d "{
    \"client_id\": \"${AUTH0_M2M_CLIENT_ID}\",
    \"client_secret\": \"${AUTH0_M2M_CLIENT_SECRET}\",
    \"audience\": \"${MGMT_AUDIENCE}\",
    \"grant_type\": \"client_credentials\"
  }") || fail "Could not get Management API token — check M2M client id/secret and API authorization"

MGMT_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
ok "Management API token obtained"

if [[ "$CHECK_ONLY" == "1" ]]; then
  missing=0
  for CID in $(connector_client_ids); do
    NAME=$(api GET "/clients/${CID}?fields=name&include_fields=true" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name') or 'fixed-dcr')")
    ensure_connector_callbacks "$CID" "$NAME" || missing=1
  done
  echo ""
  if [[ "$missing" == "1" ]]; then
    fail "Connector callbacks missing (see above) — run ./scripts/setup-auth0.sh (no --check) to sync"
  fi
  ok "All connector callbacks are allowlisted"
  exit 0
fi

info "Enabling Dynamic Client Registration (DCR)..."
api PATCH /tenants/settings -d '{"flags":{"enable_dynamic_client_registration":true}}' >/dev/null
ok "DCR enabled"

info "Enabling Identifier First (required for passwordless email on New Universal Login)..."
api PATCH /prompts -d '{"universal_login_experience":"new","identifier_first":true}' >/dev/null
ok "Identifier First enabled"

DCR_TEST=$(curl -sS -X POST "https://${DOMAIN}/oidc/register" \
  -H "content-type: application/json" \
  -d "{\"client_name\":\"acs-setup-test\",\"redirect_uris\":[\"${CLAUDE_CALLBACK}\"]}" || true)
if echo "$DCR_TEST" | grep -q '"client_id"'; then
  ok "DCR registration test passed"
elif echo "$DCR_TEST" | grep -q 'too_many_entities'; then
  ok "DCR enabled (tenant at DCR client limit — delete old test apps in Auth0 if needed)"
else
  fail "DCR still failing: $DCR_TEST"
fi

info "Finding MCP API (audience: ${AUDIENCE})..."
MCP_API_ID=$(api GET /resource-servers | python3 -c "
import sys, json
aud = sys.argv[1]
for rs in json.load(sys.stdin):
    if rs.get('identifier') == aud:
        print(rs['id'])
        break
" "$AUDIENCE")

if [[ -z "$MCP_API_ID" ]]; then
  info "Creating MCP API..."
  MCP_API_ID=$(api POST /resource-servers -d "{
    \"name\": \"Steward ACS MCP\",
    \"identifier\": \"${AUDIENCE}\",
    \"signing_alg\": \"RS256\",
    \"token_lifetime\": 604800
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  ok "Created MCP API id=${MCP_API_ID}"
else
  ok "Found MCP API id=${MCP_API_ID}"
fi

info "Enabling RBAC + permissions in access token..."
api PATCH "/resource-servers/${MCP_API_ID}" -d '{
  "enforce_policies": true,
  "token_dialect": "access_token_authz"
}' >/dev/null
ok "RBAC enabled (token_dialect=access_token_authz)"

info "Ensuring mcp:tools permission exists..."
RS_INFO=$(api GET "/resource-servers/${MCP_API_ID}")
HAS_SCOPE=$(echo "$RS_INFO" | python3 -c "
import sys, json
rs = json.load(sys.stdin)
scopes = rs.get('scopes') or []
print('yes' if any(s.get('value') == 'mcp:tools' for s in scopes) else 'no')
")
if [[ "$HAS_SCOPE" == "yes" ]]; then
  ok "Permission mcp:tools already exists"
else
  SCOPES_JSON=$(echo "$RS_INFO" | python3 -c "
import sys, json
rs = json.load(sys.stdin)
scopes = rs.get('scopes') or []
scopes.append({'value': 'mcp:tools', 'description': 'Call Steward ACS MCP tools'})
print(json.dumps({'scopes': scopes}))
")
  api PATCH "/resource-servers/${MCP_API_ID}" -d "$SCOPES_JSON" >/dev/null
  ok "Added permission mcp:tools via PATCH"
fi

info "Ensuring MCP User role..."
ROLES=$(api GET /roles?name_filter=MCP%20User)
ROLE_ID=$(echo "$ROLES" | python3 -c "
import sys, json
roles = json.load(sys.stdin)
for r in roles:
    if r.get('name') == 'MCP User':
        print(r['id'])
        break
" || true)

if [[ -z "$ROLE_ID" ]]; then
  ROLE_ID=$(api POST /roles -d '{"name":"MCP User","description":"Can use Steward MCP tools via Claude"}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  ok "Created role MCP User id=${ROLE_ID}"
else
  ok "Found role MCP User id=${ROLE_ID}"
fi

info "Assigning mcp:tools to MCP User role..."
api POST "/roles/${ROLE_ID}/permissions" -d "{
  \"permissions\": [{
    \"resource_server_identifier\": \"${AUDIENCE}\",
    \"permission_name\": \"mcp:tools\"
  }]
}" >/dev/null 2>&1 || true
ok "Role permission assigned (or already present)"

info "Configuring default third-party API access (required for DCR Claude clients)..."
EXISTING_GRANTS=$(api GET "/client-grants?audience=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${AUDIENCE}'))")" 2>/dev/null || echo "[]")
HAS_DEFAULT=$(echo "$EXISTING_GRANTS" | python3 -c "
import sys, json
grants = json.load(sys.stdin) if sys.stdin.readable() else []
for g in grants:
    if g.get('default_for') == 'third_party_clients' and g.get('audience') == sys.argv[1]:
        print('yes'); break
else:
    print('no')
" "$AUDIENCE" 2>/dev/null || echo "no")

if [[ "$HAS_DEFAULT" == "yes" ]]; then
  ok "Default third-party client grant already exists"
else
  api POST /client-grants -d "{
    \"default_for\": \"third_party_clients\",
    \"audience\": \"${AUDIENCE}\",
    \"scope\": [\"mcp:tools\"],
    \"subject_type\": \"user\"
  }" >/dev/null
  ok "Created default third-party grant for ${AUDIENCE}"
fi

# Per-app grants for known Claude OAuth clients
for CLAUDE_CID in $(api GET "/clients?fields=client_id,name&include_fields=true&per_page=100" | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    n = (c.get('name') or '').lower()
    if 'claude' in n:
        print(c['client_id'])
"); do
  HAS_GRANT=$(echo "$EXISTING_GRANTS" | python3 -c "
import sys, json
cid, aud = sys.argv[1], sys.argv[2]
grants = json.load(sys.stdin) if sys.stdin.readable() else []
print('yes' if any(g.get('client_id')==cid and g.get('audience')==aud for g in grants) else 'no')
" "$CLAUDE_CID" "$AUDIENCE" 2>/dev/null || echo "no")
  if [[ "$HAS_GRANT" != "yes" ]]; then
    api POST /client-grants -d "{
      \"client_id\": \"${CLAUDE_CID}\",
      \"audience\": \"${AUDIENCE}\",
      \"scope\": [\"mcp:tools\"],
      \"subject_type\": \"user\"
    }" >/dev/null 2>&1 || true
    ok "Granted MCP API access to client ${CLAUDE_CID}"
  fi
done

if [[ -n "${AUTH0_USER_EMAIL:-}" ]]; then
  ORG_META="${AUTH0_USER_ORG:-default}"
  ROLE_META="${AUTH0_USER_ROLE:-collaborator}"
  info "Creating passwordless user ${AUTH0_USER_EMAIL} on connection ${DB_CONNECTION} (org=${ORG_META})..."
  if [[ "$DB_CONNECTION" == "email" || "$DB_CONNECTION" == "sms" ]]; then
    USER_JSON=$(api POST /users -d "{
      \"email\": \"${AUTH0_USER_EMAIL}\",
      \"connection\": \"${DB_CONNECTION}\",
      \"email_verified\": true,
      \"app_metadata\": {\"org\": \"${ORG_META}\", \"role\": \"${ROLE_META}\"}
    }" 2>/dev/null || true)
  else
    [[ -n "${AUTH0_USER_PASSWORD:-}" ]] || fail "Set AUTH0_USER_PASSWORD when AUTH0_DB_CONNECTION is a database connection"
    USER_JSON=$(api POST /users -d "{
      \"email\": \"${AUTH0_USER_EMAIL}\",
      \"password\": \"${AUTH0_USER_PASSWORD}\",
      \"connection\": \"${DB_CONNECTION}\",
      \"email_verified\": true
    }" 2>/dev/null || true)
  fi

  USER_ID=$(echo "$USER_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('user_id',''))" 2>/dev/null || true)

  if [[ -z "$USER_ID" ]]; then
    USER_ID=$(api GET "/users-by-email?email=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${AUTH0_USER_EMAIL}'))")" \
      | python3 -c "import sys,json; u=json.load(sys.stdin); print(u[0]['user_id'] if u else '')")
    api PATCH "/users/${USER_ID}" -d "{\"app_metadata\":{\"org\":\"${ORG_META}\",\"role\":\"${ROLE_META}\"}}" >/dev/null 2>&1 || true
    ok "User already exists id=${USER_ID} (org=${ORG_META})"
  else
    ok "Created user id=${USER_ID}"
  fi

  api POST "/users/${USER_ID}/roles" -d "{\"roles\": [\"${ROLE_ID}\"]}" >/dev/null
  ok "Assigned MCP User role to ${AUTH0_USER_EMAIL}"
fi

if [[ "${SKIP_CLAUDE_APP:-}" != "1" ]]; then
  info "Creating Claude.ai OAuth app (manual Client ID fallback)..."
  EXISTING=$(api GET /clients?fields=client_id,name 2>/dev/null | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    if c.get('name') == 'Claude.ai MCP':
        print(c['client_id'])
        break
" || true)

  CALLBACKS_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "${CONNECTOR_CALLBACKS[@]}")

  if [[ -n "$EXISTING" ]]; then
    CLAUDE_CLIENT_ID="$EXISTING"
    ok "Claude.ai MCP app already exists client_id=${CLAUDE_CLIENT_ID}"
  else
    CLAUDE_CLIENT_ID=$(api POST /clients -d "{
      \"name\": \"Claude.ai MCP\",
      \"app_type\": \"regular_web\",
      \"callbacks\": ${CALLBACKS_JSON},
      \"grant_types\": [\"authorization_code\", \"refresh_token\"],
      \"token_endpoint_auth_method\": \"none\",
      \"oidc_conformant\": true
    }" | python3 -c "import sys,json; print(json.load(sys.stdin)['client_id'])")
    ok "Created Claude.ai MCP app client_id=${CLAUDE_CLIENT_ID}"
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Claude/ChatGPT Connector OAuth Client ID (if DCR fails):"
  echo " ${CLAUDE_CLIENT_ID}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

info "Syncing connector callbacks on fixed/connector Auth0 apps..."
for CID in $(connector_client_ids); do
  NAME=$(api GET "/clients/${CID}?fields=name&include_fields=true" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name') or 'fixed-dcr')")
  ensure_connector_callbacks "$CID" "$NAME"
done

# After Claude apps exist: wire passwordless email, demote password DB
CLAUDE_IDS=$(api GET "/clients?fields=client_id,name&include_fields=true&per_page=100" | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    n = (c.get('name') or '')
    if n in ('Claude.ai MCP', 'steward_acs_mcp'):
        print(c['client_id'])
")

info "Configuring passwordless email connection for Claude (domain-level + first-party apps)..."
EMAIL_CONN=$(api GET "/connections?strategy=email" | python3 -c "
import sys, json
conns = json.load(sys.stdin)
print(conns[0]['id'] if conns else '')
" 2>/dev/null || true)

if [[ -n "$EMAIL_CONN" ]]; then
  ENABLED_JSON=$(api GET "/connections/${EMAIL_CONN}" | python3 -c "
import sys, json
conn = json.load(sys.stdin)
clients = set(conn.get('enabled_clients') or [])
for cid in '''${CLAUDE_IDS}'''.split():
    if cid:
        clients.add(cid)
print(json.dumps({'is_domain_connection': True, 'enabled_clients': sorted(clients)}))
")
  api PATCH "/connections/${EMAIL_CONN}" -d "$ENABLED_JSON" >/dev/null
  ok "Email passwordless connection is domain-level and enabled for Claude apps"
else
  info "No email passwordless connection found — create one in Auth0 Dashboard (Authentication → Passwordless → Email)"
fi

info "Demoting Username-Password-Authentication (Claude should use email OTP, not passwords)..."
DB_CONN=$(api GET "/connections?name=Username-Password-Authentication" | python3 -c "
import sys, json
conns = json.load(sys.stdin)
print(conns[0]['id'] if conns else '')
" 2>/dev/null || true)
if [[ -n "$DB_CONN" ]]; then
  PATCH_JSON=$(api GET "/connections/${DB_CONN}" | python3 -c "
import sys, json
conn = json.load(sys.stdin)
claude = set('''${CLAUDE_IDS}'''.split())
clients = [c for c in (conn.get('enabled_clients') or []) if c not in claude]
print(json.dumps({'is_domain_connection': False, 'enabled_clients': clients}))
")
  api PATCH "/connections/${DB_CONN}" -d "$PATCH_JSON" >/dev/null
  ok "Database connection demoted (not domain-level; Claude apps removed)"
fi

# Enable Google alongside email OTP for Steward web + MCP connector clients.
# ACS merges identities by verified email when Auth0 creates distinct `sub`s.
WEB_CLIENT_ID="${AUTH0_WEB_CLIENT_ID:-}"
FIXED_DCR_ID="${OAUTH_FIXED_DCR_CLIENT_ID:-}"
info "Enabling google-oauth2 for Steward web + MCP connector clients..."
GOOGLE_CONN=$(api GET "/connections?strategy=google-oauth2" | python3 -c "
import sys, json
conns = json.load(sys.stdin)
print(conns[0]['id'] if conns else '')
" 2>/dev/null || true)
if [[ -n "$GOOGLE_CONN" ]]; then
  PATCH_JSON=$(api GET "/connections/${GOOGLE_CONN}" | python3 -c "
import sys, json
conn = json.load(sys.stdin)
add = set(x for x in '''${CLAUDE_IDS} ${WEB_CLIENT_ID} ${FIXED_DCR_ID}'''.split() if x)
clients = set(conn.get('enabled_clients') or [])
clients.update(add)
print(json.dumps({'enabled_clients': sorted(clients)}))
")
  api PATCH "/connections/${GOOGLE_CONN}" -d "$PATCH_JSON" >/dev/null
  ok "google-oauth2 enabled for Steward web + MCP connector clients"
else
  info "No google-oauth2 connection found — create Google social in Auth0 Dashboard:"
  info "  Authentication → Social → Create Connection → Google"
  info "  Google Cloud OAuth redirect: https://${DOMAIN}/login/callback"
  info "  Enable Apps: Steward web client + OAUTH_FIXED_DCR_CLIENT_ID (+ Claude.ai MCP)"
  info "  Leave AUTH0_CONNECTION unset so Universal Login shows email OTP and Google"
fi

echo ""
ok "Auth0 setup complete for ${DOMAIN}"
echo "  MCP API:     ${AUDIENCE}"
echo "  DCR:         enabled"
echo "  Callbacks:   ${CONNECTOR_CALLBACKS[*]}"
echo "  Login:       Identifier First + email OTP and/or Google (no connection= pin)"
echo "  Identity:    ACS relinks by verified email across Auth0 connections"
echo "  RBAC:        enabled with mcp:tools"
echo ""
echo "Next: Remove + re-add the connector at ${AUDIENCE} and connect."
echo "Users choose email OTP or Google on Universal Login (same verified email)."
echo "New connector callback? EXTRA_CONNECTOR_CALLBACKS='https://<host>/<callback>' ./scripts/setup-auth0.sh"