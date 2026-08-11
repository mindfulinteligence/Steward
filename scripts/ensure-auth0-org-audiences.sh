# Ensure Auth0 resource servers + third-party grants exist for each org MCP URL.
# Usage:
#   BASE_DOMAIN=stewardacs.xyz ./scripts/ensure-auth0-org-audiences.sh
#   EXTRA_ORG_SLUGS="anantha other" ./scripts/ensure-auth0-org-audiences.sh
#
# Reads slug list from priv/orgs.yaml plus EXTRA_ORG_SLUGS (space-separated).
# Self-serve orgs live in the DB and are NOT in yaml — prefer ACS provisioning
# (AUTH0_MGMT_* → Acs.Auth0.OrgAudience) so new orgs get audiences automatically.
set -euo pipefail

DOMAIN="${AUTH0_DOMAIN:-dev-jw5wgp2b.us.auth0.com}"
BASE_DOMAIN="${BASE_DOMAIN:-stewardacs.xyz}"
ORGS_FILE="${ORGS_FILE:-priv/orgs.yaml}"
EXTRA_ORG_SLUGS="${EXTRA_ORG_SLUGS:-}"
M2M_ID="${AUTH0_MGMT_CLIENT_ID:-${AUTH0_M2M_CLIENT_ID:-}}"
M2M_SECRET="${AUTH0_MGMT_CLIENT_SECRET:-${AUTH0_M2M_CLIENT_SECRET:-}}"
MGMT_AUDIENCE="https://${DOMAIN}/api/v2/"
FIXED_DCR_ID="${OAUTH_FIXED_DCR_CLIENT_ID:-}"

[[ -n "$M2M_ID" && -n "$M2M_SECRET" ]] || { echo "Set AUTH0_MGMT_CLIENT_ID/SECRET" >&2; exit 1; }
[[ -f "$ORGS_FILE" ]] || { echo "Missing $ORGS_FILE" >&2; exit 1; }

api() {
  curl -sS --fail-with-body -X "$1" "https://${DOMAIN}/api/v2$2" \
    -H "authorization: Bearer ${MGMT_TOKEN}" \
    -H "content-type: application/json" \
    "${@:3}"
}

MGMT_TOKEN=$(curl -sS --fail-with-body -X POST "https://${DOMAIN}/oauth/token" \
  -H "content-type: application/json" \
  -d "{\"client_id\":\"${M2M_ID}\",\"client_secret\":\"${M2M_SECRET}\",\"audience\":\"${MGMT_AUDIENCE}\",\"grant_type\":\"client_credentials\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

while read -r SLUG AUDIENCE; do
  echo "[auth0] ensuring API ${AUDIENCE}"
  MCP_API_ID=$(api GET /resource-servers | python3 -c "
import sys, json
aud = sys.argv[1]
for rs in json.load(sys.stdin):
    if rs.get('identifier') == aud:
        print(rs['id']); break
" "$AUDIENCE")

  if [[ -z "$MCP_API_ID" ]]; then
    MCP_API_ID=$(api POST /resource-servers -d "{
      \"name\": \"Steward ACS MCP (${AUDIENCE})\",
      \"identifier\": \"${AUDIENCE}\",
      \"signing_alg\": \"RS256\",
      \"token_lifetime\": 604800,
      \"scopes\": [{\"value\": \"mcp:tools\", \"description\": \"Call Steward ACS MCP tools\"}]
    }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    echo "  created id=${MCP_API_ID}"
  else
    echo "  exists id=${MCP_API_ID}"
  fi

  api PATCH "/resource-servers/${MCP_API_ID}" -d '{
    "enforce_policies": true,
    "token_dialect": "access_token_authz"
  }' >/dev/null

  ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${AUDIENCE}'))")
  HAS_DEFAULT=$(api GET "/client-grants?audience=${ENCODED}" | python3 -c "
import sys, json
aud = sys.argv[1]
for g in json.load(sys.stdin):
    if g.get('default_for') == 'third_party_clients' and g.get('audience') == aud:
        print('yes'); break
else:
    print('no')
" "$AUDIENCE")

  if [[ "$HAS_DEFAULT" != "yes" ]]; then
    api POST /client-grants -d "{
      \"default_for\": \"third_party_clients\",
      \"audience\": \"${AUDIENCE}\",
      \"scope\": [\"mcp:tools\"],
      \"subject_type\": \"user\"
    }" >/dev/null
    echo "  added third-party grant"
  fi

  # MCP User / claude_mcp roles must include mcp:tools on THIS audience or
  # connector tokens for tenant hosts fail ACS oidc_role checks.
  for ROLE_NAME in "MCP User" "claude_mcp"; do
    ROLE_ID=$(api GET "/roles?name_filter=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$ROLE_NAME")" | python3 -c "
import sys, json
want = sys.argv[1]
for r in json.load(sys.stdin):
    if r.get('name') == want:
        print(r['id']); break
" "$ROLE_NAME" 2>/dev/null || true)
    if [[ -n "$ROLE_ID" ]]; then
      api POST "/roles/${ROLE_ID}/permissions" -d "{
        \"permissions\": [{
          \"resource_server_identifier\": \"${AUDIENCE}\",
          \"permission_name\": \"mcp:tools\"
        }]
      }" >/dev/null 2>&1 || true
      echo "  ensured ${ROLE_NAME} has mcp:tools on audience"
    fi
  done

  # The broker relays every connector through the fixed DCR Auth0 client, so
  # Auth0 validates each org's broker callback against that client's allowlist.
  # Without this, connectors pointed at this org host fail with "Callback URL
  # mismatch" at /authorize. Additive merge — other callbacks are never removed.
  if [[ -n "$FIXED_DCR_ID" ]]; then
    CALLBACK="https://${SLUG}.${BASE_DOMAIN}/oauth/callback"
    CURRENT=$(api GET "/clients/${FIXED_DCR_ID}?fields=callbacks&include_fields=true" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('callbacks') or []))")
    MISSING=$(python3 -c "
import json, sys
have = set(json.loads(sys.argv[1]))
print('yes' if sys.argv[2] in have else 'no')
" "$CURRENT" "$CALLBACK")
    if [[ "$MISSING" != "yes" ]]; then
      DESIRED=$(python3 -c "
import json, sys
have = set(json.loads(sys.argv[1]))
have.add(sys.argv[2])
print(json.dumps(sorted(have)))
" "$CURRENT" "$CALLBACK")
      api PATCH "/clients/${FIXED_DCR_ID}" -d "{\"callbacks\": ${DESIRED}}" >/dev/null
      echo "  added broker callback ${CALLBACK} to fixed DCR client ${FIXED_DCR_ID}"
    else
      echo "  broker callback ${CALLBACK} already allowlisted"
    fi
  fi
done < <(python3 - "$ORGS_FILE" "$BASE_DOMAIN" "$EXTRA_ORG_SLUGS" <<'PY'
import sys
import yaml

orgs_file, base, extra = sys.argv[1], sys.argv[2], sys.argv[3]
with open(orgs_file) as f:
    orgs = yaml.safe_load(f).get("orgs", {})
slugs = list(orgs.keys())
slugs += [s for s in extra.split() if s]
# stable unique
seen = set()
for slug in slugs:
    if slug in seen:
        continue
    seen.add(slug)
    print(f"{slug} https://{slug}.{base}/mcp/sse")
PY
)

echo "Done."
