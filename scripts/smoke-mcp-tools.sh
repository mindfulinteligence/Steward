#!/usr/bin/env bash
# smoke-mcp-tools.sh — deterministic MCP tool smoke over the wire.
#
# Boots nothing; talks to a live ACS MCP endpoint (default local dev on :4001)
# via the streamable HTTP transport (POST /mcp/v1/messages). Enumerates every
# tool from tools/list and calls each with curated args, failing (exit non-zero)
# on any tool that crashes (the generic "Tool execution failed" from
# ToolRegistry.safe_execute), transport failure, or JSON-RPC error.
#
# Stateful chains run in dependency order with captured IDs (task slug, spec
# path, memory id, developer name, authority slug, app name). Tools whose test
# args deliberately produce a clean structured error are listed in EXPECT_ERROR
# and PASS when isError:true. No LLM involved — deterministic, CI-safe.
#
# See also:
#   scripts/call_all_tools.exs        (in-process equivalent)
#   scripts/smoke-chat-tools.sh       (prod chat-surface SSE smoke)
#
# Env:
#   PUBLIC_URL    ACS base URL (default http://127.0.0.1:4001)
#   SMOKE_API_KEY API key (fallback MCP_API_KEY). Required.
#   SKIP_TOOLS    comma-separated tool names to skip
#   EXPECTED_TOOLS comma-separated exact expected tool list; if set, tools/list
#                 must match exactly (surfaces missing/new tools).
set -euo pipefail

PUBLIC_URL="${PUBLIC_URL:-http://127.0.0.1:4001}"
KEY="${SMOKE_API_KEY:-${MCP_API_KEY:-}}"
SKIP="${SKIP_TOOLS:-}"
EXPECTED="${EXPECTED_TOOLS:-}"
ENDPOINT="$PUBLIC_URL/mcp/v1/messages"
RUN_ID="tool-smoke-$(date +%s)"

[[ -n "$KEY" ]] || { echo "ERROR: SMOKE_API_KEY (or MCP_API_KEY) required" >&2; exit 2; }

echo "== smoke-mcp-tools: $PUBLIC_URL (run $RUN_ID) =="

# --- health gate -------------------------------------------------------------
health="$(curl -fsS --max-time 15 "$PUBLIC_URL/mcp/health" || true)"
if ! echo "$health" | grep -q '"status": *"healthy"'; then
  echo "ERROR: $PUBLIC_URL/mcp/health not healthy: $health" >&2
  exit 2
fi

# --- JSON-RPC helper ---------------------------------------------------------
rpc() { # $1 id, $2 method, $3 params json
  curl -sS --max-time 30 -X POST "$ENDPOINT" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -H "x-api-key: $KEY" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"$2\",\"params\":$3}"
}

# --- initialize + tools/list -------------------------------------------------
init="$(rpc 1 initialize '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke-mcp-tools","version":"1"}}')"
echo "$init" | grep -q '"result"' || { echo "ERROR: initialize failed: $init" >&2; exit 2; }

rpc 2 notifications/initialized '{}' >/dev/null 2>&1 || true

toolresp="$(rpc 3 tools/list '{}')"
if ! echo "$toolresp" | grep -q '"tools"'; then
  echo "ERROR: tools/list failed: $toolresp" >&2
  exit 2
fi

# tools array: bare names from tools/list, sorted.
mapfile -t TOOLS < <(echo "$toolresp" | jq -r '.result.tools[].name' | sort)
echo "tools/list returned ${#TOOLS[@]} tools"

if [[ -n "$EXPECTED" ]]; then
  IFS=',' read -ra EXP <<< "$EXPECTED"
  exp_json="$(printf '%s\n' "${EXP[@]}" | jq -R . | jq -s .)"
  got_json="$(printf '%s\n' "${TOOLS[@]}" | jq -R . | jq -s .)"
  if [[ "$exp_json" != "$got_json" ]]; then
    echo "ERROR: tool set mismatch" >&2
    echo "  expected: $exp_json" >&2
    echo "  got:      $got_json" >&2
    exit 2
  fi
  echo "tool set matches expected (${#TOOLS[@]})"
fi

# --- counters ----------------------------------------------------------------
ok=0; fail=0; skipped=0
declare -a FAILED=()

# --- classification ----------------------------------------------------------
# result() reads a tools/call response and echoes: OK | ERROR:<reason> | CRASH:<text>
# CRASH = the generic "Tool execution failed" swallowed by ToolRegistry.safe_execute
# (lib/acs/mcp/tool_registry.ex:849-859) — that is always a bug.
result() {
  local resp="$1" text
  if echo "$resp" | grep -q '"error"'; then
    echo "ERROR:jsonrpc $(echo "$resp" | jq -c '.error // .' | head -c 200)"
  elif echo "$resp" | grep -q '"isError":true'; then
    text="$(echo "$resp" | jq -r '.result.content[0].text // .' | head -c 200)"
    if echo "$text" | grep -q "Tool execution failed"; then
      echo "CRASH:$text"
    else
      echo "ERROR:$text"
    fi
  else
    echo "OK"
  fi
}

record() { # $1 tool, $2 classification, $3 expect_error 0/1
  local tool="$1" cls="$2" exp="$3" status
  if [[ "$cls" == OK ]]; then
    if [[ "$exp" == 1 ]]; then
      fail=$((fail + 1)); FAILED+=("$tool")
      printf '  %-28s FAIL (expected error, got OK)\n' "$tool"
    else
      ok=$((ok + 1)); printf '  %-28s OK\n' "$tool"
    fi
  elif [[ "$cls" == CRASH:* ]]; then
    fail=$((fail + 1)); FAILED+=("$tool")
    printf '  %-28s CRASH (Tool execution failed): %s\n' "$tool" "${cls#CRASH:}"
  else # ERROR:*
    if [[ "$exp" == 1 ]]; then
      ok=$((ok + 1)); printf '  %-28s OK (expected error): %s\n' "$tool" "${cls#ERROR:}"
    else
      fail=$((fail + 1)); FAILED+=("$tool")
      printf '  %-28s ERROR: %s\n' "$tool" "${cls#ERROR:}"
    fi
  fi
}

# --- SKIP set ----------------------------------------------------------------
declare -A SKIP_SET=()
if [[ -n "$SKIP" ]]; then
  IFS=',' read -ra SK <<< "$SKIP"
  for s in "${SK[@]}"; do SKIP_SET["$s"]=1; done
fi

call_tool() { # $1 id, $2 tool, $3 args-json
  rpc "$1" tools/call "{\"name\":\"$2\",\"arguments\":$3}"
}

# jqextract <resp> <jq-path> — parse .result.content[0].text as JSON then apply path
jqextract() {
  echo "$1" | jq -r '.result.content[0].text | fromjson | '"$2" 2>/dev/null || true
}

# --- EXPECT_ERROR tools (clean structured isError is the expected outcome) ----
# Negative tests: args intentionally reference nonexistent state, or the tool is
# OAuth-only and cannot run under an API key. A CRASH here still fails the smoke.
declare -A EXPECT_ERROR=(
  [ack_error_trace]=1
  [resolve_error_trace]=1
  [create_task_from_error_trace]=1
  [set_member_authority_level]=1
  [resolve_user_task]=1
)

id=10

# --- SETUP PHASE: create state, capture returned IDs -------------------------
# Runs in dependency order so dependent tools always have real state to act on.
setup() {
  local cls
  # create_org requires both name and slug (slug: lowercase letters/numbers/hyphens).
  id=$((id + 1)); resp="$(call_tool "$id" create_org "{\"name\":\"smoke-$RUN_ID\",\"slug\":\"smoke-$RUN_ID\",\"display_name\":\"Tool Smoke Org\"}")"
  cls="$(result "$resp")"; record create_org "$cls" 0
  ORG_SLUG="$(jqextract "$resp" '.slug')"

  # create_work → returned task_id (slugified title) is the real handle.
  id=$((id + 1)); resp="$(call_tool "$id" create_work "{\"agent_id\":\"test_runner\",\"title\":\"Tool smoke task $RUN_ID\"}")"
  cls="$(result "$resp")"; record create_work "$cls" 0
  TASK_ID="$(jqextract "$resp" '.task_id')"

  id=$((id + 1)); resp="$(call_tool "$id" claim_work "{\"agent_id\":\"test_runner\",\"task_id\":\"$TASK_ID\"}")"
  record claim_work "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" lock_file "{\"agent_id\":\"test_runner\",\"task_id\":\"$TASK_ID\",\"file_path\":\"scripts/smoke-mcp-tools.sh\",\"repo_confirmed\":true,\"repo\":\"steward_acs\"}")"
  record lock_file "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" get_locked_files "{}")"
  record get_locked_files "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" unlock_file "{\"agent_id\":\"test_runner\",\"file_path\":\"scripts/smoke-mcp-tools.sh\"}")"
  record unlock_file "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" release_work "{\"agent_id\":\"test_runner\",\"task_id\":\"$TASK_ID\"}")"
  record release_work "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" submit_task_feedback "{\"agent_id\":\"test_runner\",\"task_id\":\"$TASK_ID\",\"guidance_useful\":true}")"
  record submit_task_feedback "$(result "$resp")" 0

  # close_work internally does release + feedback, so it needs a FRESH claimed
  # task (TASK_ID was already released above → task_not_claimed otherwise).
  id=$((id + 1)); resp="$(call_tool "$id" create_work "{\"agent_id\":\"test_runner\",\"title\":\"Tool smoke close task $RUN_ID\"}")"
  cls="$(result "$resp")"; record create_work "$cls" 0
  TASK2_ID="$(jqextract "$resp" '.task_id')"

  id=$((id + 1)); resp="$(call_tool "$id" claim_work "{\"agent_id\":\"test_runner\",\"task_id\":\"$TASK2_ID\"}")"
  record claim_work "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" close_work "{\"agent_id\":\"test_runner\",\"task_id\":\"$TASK2_ID\"}")"
  record close_work "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" list_tasks "{\"agent_id\":\"test_runner\"}")"
  record list_tasks "$(result "$resp")" 0

  # save_memory needs intake_confirmed for a smoke-y body; returns .id (memory handle).
  # Content embeds RUN_ID so repeated runs against the same DB don't trip the
  # similar-memory dedup guard.
  id=$((id + 1)); resp="$(call_tool "$id" save_memory "{\"kind\":\"observation\",\"title\":\"Tool smoke memory $RUN_ID\",\"content\":\"Created by smoke-mcp-tools.sh run $RUN_ID to verify the save_memory tool over the wire. Purpose: assert the tool accepts valid args and returns a memory id.\",\"scope_path\":\"test/tool_smoke\",\"importance\":1,\"tags\":[\"smoke\"],\"intake_confirmed\":true}")"
  cls="$(result "$resp")"; record save_memory "$cls" 0
  MEMORY_ID="$(jqextract "$resp" '.id')"

  id=$((id + 1)); resp="$(call_tool "$id" set_memory_status "{\"memory_id\":\"$MEMORY_ID\",\"status\":\"approved\"}")"
  record set_memory_status "$(result "$resp")" 0

  # update_memory needs an existing memory_id (MEMORY_ID from save_memory above).
  id=$((id + 1)); resp="$(call_tool "$id" update_memory "{\"memory_id\":\"$MEMORY_ID\",\"content\":\"Updated by smoke-mcp-tools.sh run $RUN_ID\"}")"
  record update_memory "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" query_memories "{\"query\":\"Tool smoke memory\",\"limit\":3}")"
  record query_memories "$(result "$resp")" 0

  # spec lifecycle: propose → get → approve → reject (in dependency order).
  id=$((id + 1)); resp="$(call_tool "$id" specs_propose "{\"app\":\"steward_acs\",\"path\":\"test/smoke/$RUN_ID\",\"document_type\":\"spec\",\"title\":\"Tool smoke spec $RUN_ID\",\"purpose\":\"Verify specs_propose over the wire.\",\"content\":\"Smoke spec body.\"}")"
  record specs_propose "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" specs_get "{\"app\":\"steward_acs\",\"path\":\"test/smoke/$RUN_ID\"}")"
  record specs_get "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" specs_approve "{\"app\":\"steward_acs\",\"path\":\"test/smoke/$RUN_ID\",\"reviewer\":\"test_runner\"}")"
  record specs_approve "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" specs_reject "{\"app\":\"steward_acs\",\"path\":\"test/smoke/$RUN_ID\"}")"
  record specs_reject "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" documents_propose "{\"app\":\"steward_acs\",\"path\":\"documents/smoke/$RUN_ID\",\"document_type\":\"knowledge\",\"title\":\"Tool smoke doc $RUN_ID\",\"content\":\"Smoke document body.\"}")"
  record documents_propose "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" query_specs "{\"query\":\"Tool smoke spec\",\"limit\":3}")"
  record query_specs "$(result "$resp")" 0

  # skill_save needs numbered steps (intake) — returns .id.
  id=$((id + 1)); resp="$(call_tool "$id" skill_save "{\"name\":\"smoke-skill-$RUN_ID\",\"description\":\"Tool smoke skill\",\"content\":\"# Steps\\n1. Run the smoke.\\n2. Verify it passed.\\n3. Done.\\n\",\"tags\":[\"smoke\"],\"scope_paths\":[\"test/tool_smoke\"],\"intake_confirmed\":true}")"
  record skill_save "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" skill_get "{\"name\":\"smoke-skill-$RUN_ID\"}")"
  record skill_get "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" skill_audit_status "{}")"
  record skill_audit_status "$(result "$resp")" 0

  # developer key lifecycle: generate → list → revoke (revoke needs developer_name).
  id=$((id + 1)); resp="$(call_tool "$id" generate_developer_key "{\"email\":\"smoke-$RUN_ID@example.com\",\"name\":\"smoke\"}")"
  cls="$(result "$resp")"; record generate_developer_key "$cls" 0
  DEVELOPER_NAME="$(jqextract "$resp" '.developer_name')"

  id=$((id + 1)); resp="$(call_tool "$id" list_developer_keys "{}")"
  record list_developer_keys "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" revoke_developer_key "{\"developer_name\":\"$DEVELOPER_NAME\"}")"
  record revoke_developer_key "$(result "$resp")" 0

  # authority level lifecycle: upsert (sort_order <= 100; derived from RUN_ID so
  # consecutive runs on the same DB don't collide on (org, sort_order) unique) → list → delete.
  RUN_NUM="${RUN_ID##*-}"
  SORT_ORDER=$((10 + (RUN_NUM % 89)))
  id=$((id + 1)); resp="$(call_tool "$id" upsert_authority_level "{\"slug\":\"smoke-level-$RUN_ID\",\"label\":\"Smoke Level\",\"sort_order\":$SORT_ORDER}")"
  record upsert_authority_level "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" list_authority_levels "{}")"
  record list_authority_levels "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" delete_authority_level "{\"slug\":\"smoke-level-$RUN_ID\"}")"
  record delete_authority_level "$(result "$resp")" 0

  # app lifecycle: configure → list → remove.
  id=$((id + 1)); resp="$(call_tool "$id" app_configure "{\"name\":\"smoke-app-$RUN_ID\",\"base_url\":\"http://localhost:9999\"}")"
  record app_configure "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" app_list "{}")"
  record app_list "$(result "$resp")" 0

  id=$((id + 1)); resp="$(call_tool "$id" app_remove "{\"name\":\"smoke-app-$RUN_ID\"}")"
  record app_remove "$(result "$resp")" 0
}

# --- MAIN LOOP: stateless / read-only / negative-test tools ------------------
# Every tool already exercised in the setup phase is marked done so the loop
# covers only what setup did not touch (explicitly ordering them here).
declare -A DONE=()
for t in create_org create_work claim_work lock_file get_locked_files unlock_file \
         release_work submit_task_feedback close_work list_tasks save_memory \
         set_memory_status query_memories specs_propose specs_get specs_approve \
         specs_reject documents_propose query_specs skill_save skill_get \
         skill_audit_status generate_developer_key list_developer_keys \
         revoke_developer_key upsert_authority_level list_authority_levels \
         delete_authority_level app_configure app_list app_remove update_memory; do
  DONE["$t"]=1
done

main_loop() {
  local tool args resp cls exp
  for tool in "${TOOLS[@]}"; do
    if [[ -n "${DONE[$tool]:-}" ]]; then continue; fi
    if [[ -n "${SKIP_SET[$tool]:-}" ]]; then
      skipped=$((skipped + 1)); printf '  %-28s SKIP\n' "$tool"; continue
    fi
    args="$(echo "$ARGS_JSON" | jq -c --arg t "$tool" '.[$t] // {}')"
    id=$((id + 1)); resp="$(call_tool "$id" "$tool" "$args")"
    cls="$(result "$resp")"
    exp="${EXPECT_ERROR[$tool]:-0}"
    record "$tool" "$cls" "$exp"
  done
}

# Args for the remaining stateless/read-only/negative tools.
ARGS_JSON='{
  "ack_error_trace": {"trace_id": "__nonexistent__"},
  "ask": {"limit": 3},
  "config_lookup": {},
  "connection_diagnostic": {},
  "create_task_from_error_trace": {"trace_id": "__nonexistent__"},
  "generate_guidance_packet": {},
  "get_logs": {"limit": 3, "mode": "summary"},
  "get_person_status": {"name": "smoke"},
  "get_present_status": {},
  "get_started": {},
  "help": {},
  "list_error_traces": {"limit": 3},
  "list_orgs": {},
  "list_plugins": {},
  "memory_health_check": {},
  "query": {"sql": "SELECT 1", "purpose": "tool smoke"},
  "resolve_error_trace": {"trace_id": "__nonexistent__"},
  "resolve_user_task": {"agent_id": "test_runner", "task_id": "__nonexistent__", "outcome": "dismiss"},
  "set_member_authority_level": {"email": "smoke-'$RUN_ID'@example.com", "rank": "standard"},
  "set_person_status": {"name": "smoke", "status": "Engineer"},
  "time": {"action": "get"}
}'

setup
main_loop

echo ""
echo "== SUMMARY: total=$((ok + fail + skipped)) ok=$ok fail=$fail skipped=$skipped =="
if [[ "$fail" -gt 0 ]]; then
  echo "FAILED tools: ${FAILED[*]}" >&2
  exit 1
fi
echo "ALL TOOLS OK"
