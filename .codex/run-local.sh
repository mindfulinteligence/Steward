#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

set -a
[ ! -f .env ] || source .env
set +a

export INFISICAL_UNIVERSAL_AUTH_CLIENT_ID="$(<.opencode/infisical-client-id)"
export INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET="$(<.opencode/infisical-client-secret)"

export CODEX_HOME="$project_root/.codex"
exec codex "$@"
