#!/usr/bin/env bash
# 06_auto_deploy_test.sh: prove that a Git commit -> Coolify deploy -> new
# version is actually being served, end to end.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition BASELINE_DEPLOY AUTO_DEPLOY_TEST

APP_DOMAIN="$(state_get app_domain)"

log "Bumping app to v2 in the test repo"
DOCKERFILE="$WORK_DIR/repo/Dockerfile"
if grep -q '^ENV VERSION=' "$DOCKERFILE"; then
  sed -i 's/^ENV VERSION=.*/ENV VERSION=v2/' "$DOCKERFILE"
else
  echo 'ENV VERSION=v2' >> "$DOCKERFILE"
fi
COMMIT_SHA="$(git_commit_and_push "chore: bump to v2")"
state_set last_commit_sha "$COMMIT_SHA"
state_set app_version "v2"
log "Pushed v2 as commit $COMMIT_SHA"

RESULT="$(deploy_and_wait)"
DEPLOYMENT_UUID="${RESULT%%|*}"
DEPLOY_STATUS="${RESULT##*|}"
coolify_api GET "/deployments/$DEPLOYMENT_UUID" > "$ARTIFACTS_DIR/deployments/update-v2.json"

HTTP_INFO="$(curl -fsS "$APP_DOMAIN/info")"
VERSION="$(echo "$HTTP_INFO" | jq -r '.version')"
echo "$HTTP_INFO" > "$ARTIFACTS_DIR/http/update_v2_info.json"

STATUS="failed"
[ "$DEPLOY_STATUS" = "finished" ] && [ "$VERSION" = "v2" ] && STATUS="passed"

record_test "update" "$STATUS" "$(jq -n \
  --arg deployment_uuid "$DEPLOYMENT_UUID" \
  --arg coolify_status "$DEPLOY_STATUS" \
  --arg git_commit "$COMMIT_SHA" \
  --arg version "$VERSION" \
  '{deployment_uuid:$deployment_uuid, coolify_status:$coolify_status, git_commit:$git_commit, version:$version}')"

[ "$STATUS" = "passed" ] || fail "update (v2) test failed: deploy=$DEPLOY_STATUS version=$VERSION"

log "v2 deployment verified: git_commit=$COMMIT_SHA version=$VERSION"
