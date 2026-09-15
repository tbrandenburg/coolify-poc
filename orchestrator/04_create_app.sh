#!/usr/bin/env bash
# 04_create_app.sh: create a dedicated Coolify project/environment and an
# application from the public GitHub repo, entirely via the API. Every UUID
# is discovered from Coolify's own responses, never hard-coded.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition BOOTSTRAP_COOLIFY CREATE_APP

source "$SECRETS_FILE"
COOLIFY_URL="$(state_get coolify_url)"
REPO_FULL="$(state_get repo_full)"
BRANCH="$(state_get repo_default_branch)"

api() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -fsS -X "$method" -H "Authorization: Bearer $COOLIFY_TOKEN" -H "Content-Type: application/json" \
      "$COOLIFY_URL/api/v1$path" -d "$data"
  else
    curl -fsS -X "$method" -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1$path"
  fi
}

log "Discovering server UUID"
SERVER_UUID="$(api GET /servers | jq -r '.[0].uuid')"
[ -n "$SERVER_UUID" ] && [ "$SERVER_UUID" != "null" ] || fail "no Coolify server found"
state_set server_uuid "$SERVER_UUID"

log "Creating project 'autonomous-prototype' (idempotent-ish: reuses if already present)"
EXISTING_PROJECT_UUID="$(api GET /projects | jq -r '.[] | select(.name=="autonomous-prototype") | .uuid' | head -1)"
if [ -n "$EXISTING_PROJECT_UUID" ]; then
  PROJECT_UUID="$EXISTING_PROJECT_UUID"
  log "Reusing existing project $PROJECT_UUID"
else
  PROJECT_UUID="$(api POST /projects '{"name":"autonomous-prototype","description":"Created by the coolify-poc agent"}' | jq -r '.uuid')"
  log "Created project $PROJECT_UUID"
fi
resources_set coolify_project_uuid "$PROJECT_UUID"
state_set project_uuid "$PROJECT_UUID"

log "Discovering environment UUID for project $PROJECT_UUID"
ENVIRONMENT_UUID="$(api GET "/projects/$PROJECT_UUID" | jq -r '.environments[] | select(.name=="production") | .uuid' | head -1)"
[ -n "$ENVIRONMENT_UUID" ] && [ "$ENVIRONMENT_UUID" != "null" ] || fail "no production environment found in project $PROJECT_UUID"
state_set environment_uuid "$ENVIRONMENT_UUID"

log "Creating application 'hello-world' from https://github.com/$REPO_FULL (branch $BRANCH)"
APP_PAYLOAD=$(cat <<EOF
{
  "project_uuid": "$PROJECT_UUID",
  "environment_uuid": "$ENVIRONMENT_UUID",
  "server_uuid": "$SERVER_UUID",
  "git_repository": "https://github.com/$REPO_FULL",
  "git_branch": "$BRANCH",
  "build_pack": "dockerfile",
  "name": "hello-world",
  "ports_exposes": "3000",
  "health_check_enabled": true,
  "health_check_path": "/health",
  "is_auto_deploy_enabled": true
}
EOF
)
APP_RESPONSE="$(api POST /applications/public "$APP_PAYLOAD")"
APPLICATION_UUID="$(echo "$APP_RESPONSE" | jq -r '.uuid')"
APP_DOMAIN="$(echo "$APP_RESPONSE" | jq -r '.domains')"
[ -n "$APPLICATION_UUID" ] && [ "$APPLICATION_UUID" != "null" ] || fail "application creation failed: $APP_RESPONSE"

resources_set coolify_application_uuid "$APPLICATION_UUID"
state_set application_uuid "$APPLICATION_UUID"
state_set app_domain "$APP_DOMAIN"

log "Application created: uuid=$APPLICATION_UUID domain=$APP_DOMAIN"
