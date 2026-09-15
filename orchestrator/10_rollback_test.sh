#!/usr/bin/env bash
# 10_rollback_test.sh: deploy v3 (good), then v4 (bad content, but /health
# stays 200 so it deploys clean), then perform a REAL Coolify rollback (not
# a git revert) back to the v3 commit and verify: before=v4, after=v3, while
# Git HEAD stays at v4 the whole time.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition HEALTH_TEST ROLLBACK_TEST

APPLICATION_UUID="$(state_get application_uuid)"
APP_DOMAIN="$(state_get app_domain)"
DOCKERFILE="$WORK_DIR/repo/Dockerfile"

set_version() {
  local v="$1"
  if grep -q '^ENV VERSION=' "$DOCKERFILE"; then
    sed -i "s/^ENV VERSION=.*/ENV VERSION=$v/" "$DOCKERFILE"
  else
    echo "ENV VERSION=$v" >> "$DOCKERFILE"
  fi
}

log "Deploying v3 (good)"
set_version v3
V3_SHA="$(git_commit_and_push "chore: v3 (good)")"
coolify_api PATCH "/applications/$APPLICATION_UUID/envs/bulk" '{"data":[{"key":"MESSAGE","value":"v3-good-release"}]}' >/dev/null
RESULT="$(deploy_and_wait)"
V3_DEPLOYMENT="${RESULT%%|*}"
V3_STATUS="${RESULT##*|}"
coolify_api GET "/deployments/$V3_DEPLOYMENT" > "$ARTIFACTS_DIR/deployments/rollback-v3.json"
[ "$V3_STATUS" = "finished" ] || fail "v3 deploy failed: $V3_STATUS"
V3_INFO="$(curl -fsS "$APP_DOMAIN/info")"
log "v3 deployed: commit=$V3_SHA info=$V3_INFO"

log "Deploying v4 (bad-but-healthy)"
set_version v4
V4_SHA="$(git_commit_and_push "chore: v4 (bad but healthy)")"
coolify_api PATCH "/applications/$APPLICATION_UUID/envs/bulk" '{"data":[{"key":"MESSAGE","value":"This release is intentionally wrong"}]}' >/dev/null
RESULT="$(deploy_and_wait)"
V4_DEPLOYMENT="${RESULT%%|*}"
V4_STATUS="${RESULT##*|}"
coolify_api GET "/deployments/$V4_DEPLOYMENT" > "$ARTIFACTS_DIR/deployments/rollback-v4.json"
[ "$V4_STATUS" = "finished" ] || fail "v4 deploy failed: $V4_STATUS"
V4_INFO="$(curl -fsS "$APP_DOMAIN/info")"
V4_HEALTH="$(curl -s -o /dev/null -w '%{http_code}' "$APP_DOMAIN/health")"
BEFORE_VERSION="$(echo "$V4_INFO" | jq -r '.version')"
log "v4 deployed: commit=$V4_SHA info=$V4_INFO health=$V4_HEALTH"

log "Rolling back to v3 commit ($V3_SHA) via the real Coolify rollback API"
ROLLBACK_RESP="$(coolify_api POST "/applications/$APPLICATION_UUID/rollback" "$(jq -n --arg c "$V3_SHA" '{commit:$c}')")"
echo "$ROLLBACK_RESP" > "$ARTIFACTS_DIR/deployments/rollback-request.json"
ROLLBACK_DEPLOYMENT_UUID="$(echo "$ROLLBACK_RESP" | jq -r '.deployment_uuid // empty')"
[ -n "$ROLLBACK_DEPLOYMENT_UUID" ] || fail "rollback did not return a deployment_uuid: $ROLLBACK_RESP"

ATTEMPTS=0
while true; do
  ROLLBACK_STATUS="$(coolify_api GET "/deployments/$ROLLBACK_DEPLOYMENT_UUID" | jq -r '.status')"
  { [ "$ROLLBACK_STATUS" = "finished" ] || [ "$ROLLBACK_STATUS" = "failed" ]; } && break
  ATTEMPTS=$((ATTEMPTS + 1))
  [ "$ATTEMPTS" -ge 60 ] && fail "rollback deployment did not finish in time (last status: $ROLLBACK_STATUS)"
  sleep 5
done
coolify_api GET "/deployments/$ROLLBACK_DEPLOYMENT_UUID" > "$ARTIFACTS_DIR/deployments/rollback-execute.json"

AFTER_INFO="$(curl -fsS "$APP_DOMAIN/info")"
AFTER_VERSION="$(echo "$AFTER_INFO" | jq -r '.version')"
LOCAL_GIT_HEAD="$(cd "$WORK_DIR/repo" && git rev-parse HEAD)"

echo "$AFTER_INFO" > "$ARTIFACTS_DIR/http/rollback_after_info.json"

STATUS="failed"
if [ "$ROLLBACK_STATUS" = "finished" ] && [ "$BEFORE_VERSION" = "v4" ] && [ "$AFTER_VERSION" = "v3" ] && [ "$LOCAL_GIT_HEAD" = "$V4_SHA" ]; then
  STATUS="passed"
fi

record_test "rollback" "$STATUS" "$(jq -n \
  --arg rollback_deployment_uuid "$ROLLBACK_DEPLOYMENT_UUID" \
  --arg coolify_status "$ROLLBACK_STATUS" \
  --arg before_version "$BEFORE_VERSION" \
  --arg after_version "$AFTER_VERSION" \
  --arg rollback_target_commit "$V3_SHA" \
  --arg git_head "$LOCAL_GIT_HEAD" \
  '{deployment_uuid:$rollback_deployment_uuid, coolify_status:$coolify_status, before_version:$before_version, after_version:$after_version, rollback_target_commit:$rollback_target_commit, git_head_after_rollback:$git_head, note:"git_head_after_rollback intentionally still equals v4 commit — rollback is a Coolify-side container swap, not a git revert"}')"

[ "$STATUS" = "passed" ] || fail "rollback test failed: before=$BEFORE_VERSION after=$AFTER_VERSION git_head=$LOCAL_GIT_HEAD (expected v4) rollback_status=$ROLLBACK_STATUS"

log "Rollback verified: before=v4 after=v3, Git HEAD still at v4 commit ($LOCAL_GIT_HEAD) — proving this was a real deployment rollback, not a git revert"
