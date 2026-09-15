#!/usr/bin/env bash
# 07_failed_build_test.sh: prove a broken build fails deployment without
# replacing (or taking down) the previously running version.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition AUTO_DEPLOY_TEST FAILED_BUILD_TEST

APP_DOMAIN="$(state_get app_domain)"
DOCKERFILE="$WORK_DIR/repo/Dockerfile"

cp "$DOCKERFILE" "$DOCKERFILE.bak"
echo 'RUN exit 42' >> "$DOCKERFILE"
COMMIT_SHA="$(git_commit_and_push "chore: intentionally broken build")"
log "Pushed broken-build commit $COMMIT_SHA"

RESULT="$(deploy_and_wait)"
DEPLOYMENT_UUID="${RESULT%%|*}"
DEPLOY_STATUS="${RESULT##*|}"
coolify_api GET "/deployments/$DEPLOYMENT_UUID" > "$ARTIFACTS_DIR/deployments/broken-build.json"
log "Broken-build deployment $DEPLOYMENT_UUID finished with status: $DEPLOY_STATUS"

HTTP_INFO="$(curl -fsS "$APP_DOMAIN/info")"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$APP_DOMAIN/info")"
RUNNING_VERSION="$(echo "$HTTP_INFO" | jq -r '.version')"
echo "$HTTP_INFO" > "$ARTIFACTS_DIR/http/broken_build_info.json"

STATUS="failed"
[ "$DEPLOY_STATUS" = "failed" ] && [ "$HTTP_CODE" = "200" ] && [ "$RUNNING_VERSION" = "v2" ] && STATUS="passed"

record_test "broken-build" "$STATUS" "$(jq -n \
  --arg deployment_uuid "$DEPLOYMENT_UUID" \
  --arg coolify_status "$DEPLOY_STATUS" \
  --arg git_commit "$COMMIT_SHA" \
  --arg http_status "$HTTP_CODE" \
  --arg serving_version "$RUNNING_VERSION" \
  '{deployment_uuid:$deployment_uuid, coolify_status:$coolify_status, git_commit:$git_commit, http_status:$http_status, serving_version:$serving_version}')"

log "Reverting broken build"
mv "$DOCKERFILE.bak" "$DOCKERFILE"
git_commit_and_push "chore: revert broken build" >/dev/null

[ "$STATUS" = "passed" ] || fail "broken-build test failed: deploy=$DEPLOY_STATUS http=$HTTP_CODE serving=$RUNNING_VERSION"

log "Broken-build test verified: deployment failed as expected, v2 kept serving (http=$HTTP_CODE)"
