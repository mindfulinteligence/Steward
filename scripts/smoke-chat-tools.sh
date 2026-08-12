#!/usr/bin/env bash
# Assert prod chat MCP advertises exactly CoreToolRoles.chat_surface/0.
#
# Usage:
#   PUBLIC_URL=https://… SMOKE_API_KEY=acs_dev_… EXPECTED_CHAT_TOOLS=ask,get_started,… \
#     ./scripts/smoke-chat-tools.sh
#
# Env:
#   PUBLIC_URL            base URL (required)
#   SMOKE_API_KEY         developer/API key with collaborator+ (required; skip if unset when ALLOW_SKIP=1)
#   EXPECTED_CHAT_TOOLS   comma-separated names from running release chat_surface/0 (required)
#   ALLOW_SKIP=1          exit 0 when SMOKE_API_KEY unset (deploy default)
#   SKIP_CODING_CHECK=1   skip /mcp/coding/sse divergence check
set -euo pipefail

PUBLIC_URL="${PUBLIC_URL:-}"
PUBLIC_URL="${PUBLIC_URL%/}"
SMOKE_API_KEY="${SMOKE_API_KEY:-}"
EXPECTED_CHAT_TOOLS="${EXPECTED_CHAT_TOOLS:-}"
ALLOW_SKIP="${ALLOW_SKIP:-0}"
SKIP_CODING_CHECK="${SKIP_CODING_CHECK:-0}"

info() { echo "[smoke-chat-tools] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

if [[ -z "$SMOKE_API_KEY" ]]; then
  if [[ "$ALLOW_SKIP" == "1" ]]; then
    info "SMOKE_API_KEY unset — skipping chat tools/list smoke"
    exit 0
  fi
  die "SMOKE_API_KEY required (developer key for /mcp/chat/sse)"
fi

[[ -n "$PUBLIC_URL" ]] || die "PUBLIC_URL required"
[[ -n "$EXPECTED_CHAT_TOOLS" ]] || die "EXPECTED_CHAT_TOOLS required (comma-separated chat_surface names)"

SSE_FILE=""
SSE_PID=""
cleanup() {
  if [[ -n "${SSE_PID}" ]]; then
    kill "$SSE_PID" 2>/dev/null || true
    wait "$SSE_PID" 2>/dev/null || true
  fi
  if [[ -n "${SSE_FILE}" && -f "${SSE_FILE}" ]]; then
    rm -f "$SSE_FILE"
  fi
}
trap cleanup EXIT

auth_hdr=(-H "Authorization: Bearer ${SMOKE_API_KEY}" -H "Accept: application/json, text/event-stream")

# Sets globals SSE_FILE/SSE_PID and writes session id into nameref $2.
# Must not run under command substitution — that would lose the SSE curl child.
open_sse() {
  local path="$1"
  local -n _session_out="$2"
  SSE_FILE=$(mktemp)
  curl -NsS --max-time 90 "${auth_hdr[@]}" "${PUBLIC_URL}${path}" >"$SSE_FILE" &
  SSE_PID=$!

  # Do not name this local "session" — nameref $2 is often also "session"
  # and bash circular namerefs silently break the hand-off.
  local found=""
  for _ in $(seq 1 50); do
    if ! kill -0 "$SSE_PID" 2>/dev/null; then
      die "SSE ${path} exited early: $(head -c 400 "$SSE_FILE" 2>/dev/null || true)"
    fi
    found=$(grep -oE 'session_id=[A-Za-z0-9_.:-]+' "$SSE_FILE" 2>/dev/null | head -1 | cut -d= -f2 || true)
    if [[ -n "$found" ]]; then
      _session_out="$found"
      return 0
    fi
    sleep 0.2
  done
  die "timed out waiting for SSE endpoint on ${path}"
}

close_sse() {
  if [[ -n "${SSE_PID}" ]]; then
    kill "$SSE_PID" 2>/dev/null || true
    wait "$SSE_PID" 2>/dev/null || true
    SSE_PID=""
  fi
  if [[ -n "${SSE_FILE}" && -f "${SSE_FILE}" ]]; then
    rm -f "$SSE_FILE"
    SSE_FILE=""
  fi
}

post_rpc() {
  local session_id="$1"
  local body="$2"
  curl -fsS --max-time 30 -X POST \
    "${auth_hdr[@]}" \
    -H "content-type: application/json" \
    -d "$body" \
    "${PUBLIC_URL}/mcp/messages?session_id=${session_id}" >/dev/null
}

wait_rpc_result() {
  local rpc_id="$1"
  local deadline=$((SECONDS + 20))
  local rc
  while (( SECONDS < deadline )); do
    set +e
    python3 - "$SSE_FILE" "$rpc_id" <<'PY'
import json, re, sys
path, want_id = sys.argv[1], int(sys.argv[2])
text = open(path, "r", errors="replace").read()
for raw in re.findall(r"(?m)^data:\s*(.+)$", text):
    raw = raw.strip()
    if not raw or raw == "[DONE]":
        continue
    try:
        msg = json.loads(raw)
    except json.JSONDecodeError:
        continue
    if msg.get("id") == want_id and "result" in msg:
        print(json.dumps(msg["result"]))
        sys.exit(0)
    if msg.get("id") == want_id and "error" in msg:
        print(json.dumps(msg["error"]), file=sys.stderr)
        sys.exit(2)
sys.exit(1)
PY
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      return 0
    fi
    if [[ $rc -eq 2 ]]; then
      die "JSON-RPC id=${rpc_id} returned error"
    fi
    sleep 0.2
  done
  die "timed out waiting for JSON-RPC id=${rpc_id} on SSE stream"
}

# Bounded retry around a full tools/list SSE round-trip so a transient
# boot-time block in the server (e.g. ToolRegistry warmup) does not fail the
# cutover job on a one-off 5xx / JSON-RPC error.
#   LIST_RETRIES        max attempts (default 3)
#   LIST_RETRY_DELAY    seconds between attempts (default 10)
run_list_tools() {
  local path="$1"
  local client_name="$2"
  local retries="${LIST_RETRIES:-3}"
  local delay="${LIST_RETRY_DELAY:-10}"
  local attempt
  for attempt in $(seq 1 "$retries"); do
    info "tools/list via ${path} (attempt ${attempt}/${retries})"
    if result=$(list_tools_via_sse "$path" "$client_name"); then
      echo "$result"
      return 0
    fi
    if (( attempt < retries )); then
      info "tools/list via ${path} failed (attempt ${attempt}); retrying in ${delay}s"
      sleep "$delay"
    fi
  done
  die "tools/list via ${path} failed after ${retries} attempts"
}

list_tools_via_sse() {
  local path="$1"
  local client_name="$2"
  local session=""
  open_sse "$path" session

  post_rpc "$session" "$(python3 - <<PY
import json
print(json.dumps({
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {"name": "${client_name}", "version": "0.0.1"}
  }
}))
PY
)"
  wait_rpc_result 1 >/dev/null

  post_rpc "$session" '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' || true

  post_rpc "$session" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  local result
  result=$(wait_rpc_result 2)
  close_sse
  echo "$result"
}

compare_sets() {
  local got_json="$1"
  python3 - "$got_json" "$EXPECTED_CHAT_TOOLS" <<'PY'
import json, sys
result = json.loads(sys.argv[1])
expected = {n.strip() for n in sys.argv[2].split(",") if n.strip()}
tools = result.get("tools") or []
got = {t.get("name") for t in tools if isinstance(t, dict) and t.get("name")}
missing = sorted(expected - got)
extra = sorted(got - expected)
if missing or extra:
    print(f"chat tools/list mismatch: count={len(got)} expected={len(expected)}", file=sys.stderr)
    if missing:
        print("missing: " + ", ".join(missing), file=sys.stderr)
    if extra:
        print("extra: " + ", ".join(extra), file=sys.stderr)
    sys.exit(1)
print(",".join(sorted(got)))
PY
}

info "chat SSE tools/list via ${PUBLIC_URL}/mcp/chat/sse"
CHAT_RESULT=$(run_list_tools "/mcp/chat/sse" "deploy-smoke-chat")
GOT_NAMES=$(compare_sets "$CHAT_RESULT")
info "chat tools/list ok (${GOT_NAMES//,/, })"

if [[ "$SKIP_CODING_CHECK" != "1" ]]; then
  info "coding SSE tools/list divergence check"
  CODING_RESULT=$(run_list_tools "/mcp/coding/sse" "deploy-smoke-coding")
  python3 - "$CODING_RESULT" "$EXPECTED_CHAT_TOOLS" <<'PY'
import json, sys
result = json.loads(sys.argv[1])
chat = {n.strip() for n in sys.argv[2].split(",") if n.strip()}
tools = result.get("tools") or []
got = {t.get("name") for t in tools if isinstance(t, dict) and t.get("name")}
extra = sorted(got - chat)
if not extra:
    print("coding tools/list has no tools outside chat_surface (wrong audience?)", file=sys.stderr)
    sys.exit(1)
print(f"coding has {len(got)} tools; outside chat: {', '.join(extra[:8])}")
PY
  info "coding tools/list diverges from chat (ok)"
fi

info "smoke-chat-tools passed"
