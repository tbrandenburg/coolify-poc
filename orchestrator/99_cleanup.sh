#!/usr/bin/env bash
# 99_cleanup.sh: destroy every resource this agent created, even if earlier
# steps failed. Best-effort per resource — logs a clear WARNING and keeps
# going rather than aborting cleanup halfway.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh

log "Starting cleanup"

REPO_FULL="$(resources_get github_repo)"
PRS="$(jq -r '.github_prs[]? // empty' "$RESOURCES_FILE" 2>/dev/null)"
PROJECT_UUID="$(resources_get coolify_project_uuid)"
APPLICATION_UUID="$(resources_get coolify_application_uuid)"
COOLIFY_DIR="$(state_get coolify_dir)"
COOLIFY_INSTANCE="$(state_get coolify_instance)"

if [ -f "$SECRETS_FILE" ]; then
  source "$SECRETS_FILE"
  COOLIFY_URL="$(state_get coolify_url)"
fi

if [ -n "${COOLIFY_TOKEN:-}" ] && [ -n "${COOLIFY_URL:-}" ]; then
  if [ -n "$APPLICATION_UUID" ]; then
    log "Deleting Coolify application $APPLICATION_UUID"
    curl -s -X DELETE -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications/$APPLICATION_UUID" \
      || log "WARN: failed to delete application $APPLICATION_UUID (continuing)"
  fi
  if [ -n "$PROJECT_UUID" ]; then
    log "Deleting Coolify project $PROJECT_UUID"
    curl -s -X DELETE -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/projects/$PROJECT_UUID" \
      || log "WARN: failed to delete project $PROJECT_UUID (continuing)"
  fi
else
  log "WARN: no Coolify token/URL available — skipping API-level Coolify cleanup"
fi

if [ -n "$PRS" ]; then
  for pr in $PRS; do
    log "Ensuring PR #$pr is closed"
    gh pr close "$pr" --repo "$REPO_FULL" >/dev/null 2>&1 || true
  done
fi

if [ -n "$REPO_FULL" ]; then
  log "Deleting GitHub repo $REPO_FULL"
  if ! gh repo delete "$REPO_FULL" --yes 2>&1; then
    log "WARN: could not delete $REPO_FULL via gh (likely missing 'delete_repo' OAuth scope on this token, which cannot be added non-interactively)."
    log "WARN: manual cleanup required: gh auth refresh -h github.com -s delete_repo && gh repo delete $REPO_FULL --yes"
  fi
fi

if [ -n "$COOLIFY_DIR" ] && [ -d "$COOLIFY_DIR" ] && [ -n "$COOLIFY_INSTANCE" ]; then
  log "Stopping Coolify dev instance '$COOLIFY_INSTANCE' (docker compose down -v)"
  ( cd "$COOLIFY_DIR" && ./scripts/dev-instances down "$COOLIFY_INSTANCE" ) || log "WARN: dev-instances down failed (continuing)"
  # dev-instances down doesn't remove volumes or the optional testing-host
  # profile container; clean those up explicitly so nothing is left behind.
  ( cd "$COOLIFY_DIR" && docker compose -p "coolify-$COOLIFY_INSTANCE" -f docker-compose.dev-multi.yml \
      --env-file ".dev-instances/$COOLIFY_INSTANCE.env" --profile testing-host down -v --remove-orphans ) \
    || log "WARN: full docker compose teardown failed (continuing)"
fi

log "Removing local secrets file"
rm -f "$SECRETS_FILE"

# Coolify's own scheduled jobs create infrastructure containers (its proxy
# and sentinel agent) OUTSIDE the docker-compose project scope, directly on
# the "server" it manages (here: the testing-host container standing in for
# localhost). These survive `docker compose down` and must be removed
# explicitly, or they leak between runs and squat on ports 80/443/8080.
log "Removing Coolify-managed infrastructure containers/network (proxy, sentinel) left outside the compose project"
docker rm -f coolify-proxy coolify-sentinel >/dev/null 2>&1 || true
docker network rm coolify >/dev/null 2>&1 || true
docker volume rm coolify-buildx >/dev/null 2>&1 || true

log "Removing local work directory (cloned repo + Coolify checkout)"
rm -rf "$WORK_DIR"

state_set state "CLEANUP"
log "Cleanup complete. Remaining artifacts kept for evidence: artifacts/, docs/POC.md, .agent/state.json, .agent/resources.json"
