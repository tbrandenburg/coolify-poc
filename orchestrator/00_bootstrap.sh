#!/usr/bin/env bash
# 00_bootstrap.sh: verify tooling and credentials before doing anything else.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

state_init
transition NEW BOOTSTRAP

require_cmd git
require_cmd gh
require_cmd docker
require_cmd curl
require_cmd jq

docker compose version >/dev/null 2>&1 || fail "docker compose plugin not available"

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated; a GH_TOKEN-equivalent login is required"

GH_LOGIN="$(gh api user -q .login)"
[ -n "$GH_LOGIN" ] || fail "could not determine GitHub login"
state_set github_login "$GH_LOGIN"
log "Authenticated to GitHub as $GH_LOGIN"

RUN_ID="$(date +%s)-$RANDOM"
state_set run_id "$RUN_ID"
log "Run ID: $RUN_ID"

log "Bootstrap OK"
