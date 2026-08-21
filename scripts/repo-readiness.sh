#!/usr/bin/env bash
# Run the repository checks required before pushing or promoting a change.
# Keep this command identical locally and in GitHub Actions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

step() {
  printf '\n== %s ==\n' "$1"
}

step "Check whitespace"
git diff --check

step "Check formatting"
mix format --check-formatted

step "Compile with warnings as errors"
mix compile --warnings-as-errors

step "Run Credo"
mix credo --strict

step "Run tests"
MIX_ENV=test DATABASE_URL="${TEST_DATABASE_URL:-ecto://postgres:postgres@localhost:5432/acs_test}" mix test

step "Build production release"
MIX_ENV=prod \
  REPO_ADAPTER=postgres \
  DATABASE_URL="${RELEASE_DATABASE_URL:-ecto://postgres:ci_release_password@localhost:5432/acs_prod}" \
  PGPASSWORD="${PGPASSWORD:-ci_release_password}" \
  SECRET_KEY_BASE="${SECRET_KEY_BASE:-ci_secret_key_base_for_release_build_only_not_for_production_use_1234567890}" \
  MCP_API_KEY="${MCP_API_KEY:-ci_mcp_key}" \
  ACS_PASSWORD="${ACS_PASSWORD:-ci_dashboard_password}" \
  PHX_HOST="${PHX_HOST:-localhost}" \
  COOKIE_SIGNING_SALT="${COOKIE_SIGNING_SALT:-ci_cookie_signing_salt}" \
  mix deps.get --only prod

MIX_ENV=prod \
  REPO_ADAPTER=postgres \
  DATABASE_URL="${RELEASE_DATABASE_URL:-ecto://postgres:ci_release_password@localhost:5432/acs_prod}" \
  PGPASSWORD="${PGPASSWORD:-ci_release_password}" \
  SECRET_KEY_BASE="${SECRET_KEY_BASE:-ci_secret_key_base_for_release_build_only_not_for_production_use_1234567890}" \
  MCP_API_KEY="${MCP_API_KEY:-ci_mcp_key}" \
  ACS_PASSWORD="${ACS_PASSWORD:-ci_dashboard_password}" \
  PHX_HOST="${PHX_HOST:-localhost}" \
  COOKIE_SIGNING_SALT="${COOKIE_SIGNING_SALT:-ci_cookie_signing_salt}" \
  mix release

step "Run disposable MCP tool smoke"
env -u DATABASE_URL -u TEST_DATABASE_URL -u RELEASE_DATABASE_URL \
  MCP_API_KEY="${SMOKE_MCP_API_KEY:-ci_tool_smoke_key}" \
  PORT="${SMOKE_PORT:-4101}" \
  ./scripts/local-tool-smoke.sh

printf '\nREADY: repository checks passed\n'
