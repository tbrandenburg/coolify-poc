#!/usr/bin/env bash
# 02_start_coolify.sh: clone Coolify and start its official isolated dev
# instance ("b") via scripts/dev-instances. This handles APP_KEY generation,
# migrations, and non-default ports for us instead of hand-rolling them.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition CREATE_REPO START_COOLIFY

COOLIFY_DIR="$WORK_DIR/coolify"
INSTANCE="b"           # avoids port 8000, already bound by an unrelated stack on this host
COOLIFY_PORT="8001"

if [ ! -d "$COOLIFY_DIR/.git" ]; then
  log "Cloning coollabsio/coolify (shallow)"
  git clone --depth 1 https://github.com/coollabsio/coolify.git "$COOLIFY_DIR" >/dev/null
fi

cd "$COOLIFY_DIR"

log "Starting Coolify dev instance '$INSTANCE' via scripts/dev-instances (this builds frontend assets + runs migrations, can take several minutes on first run)"
./scripts/dev-instances up "$INSTANCE"

state_set coolify_dir "$COOLIFY_DIR"
state_set coolify_instance "$INSTANCE"
state_set coolify_url "http://localhost:$COOLIFY_PORT"
state_set coolify_port "$COOLIFY_PORT"
resources_set docker_project "coolify-$INSTANCE"

log "Waiting for Coolify HTTP endpoint at http://localhost:$COOLIFY_PORT ..."
wait_for_http "http://localhost:$COOLIFY_PORT" 600 5

log "Coolify is reachable"

