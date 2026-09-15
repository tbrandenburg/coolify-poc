#!/usr/bin/env bash
# 09_health_test.sh: deploy a version whose /health endpoint returns 500.
# Real Coolify behavior (verified against actual deployment logs, not
# assumed): it builds and starts the new container, polls /health via its
# own internal Docker healthcheck, sees the real 500, and after N failed
# attempts marks the new container unhealthy, AUTOMATICALLY ROLLS BACK to
# the previous good container, and marks the deployment "failed". So the
# correct assertion is: deployment fails, and the app keeps serving the
# PREVIOUS good version throughout (not the broken one). Then restore a
# healthy version and verify a normal deploy succeeds again.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition ENV_TEST HEALTH_TEST

APPLICATION_UUID="$(state_get application_uuid)"
APP_DOMAIN="$(state_get app_domain)"

PRE_INFO="$(curl -fsS "$APP_DOMAIN/info")"
PRE_MESSAGE="$(echo "$PRE_INFO" | jq -r '.message')"

log "Deploying unhealthy version (HEALTHY=false) — expecting Coolify to detect the real 500 and roll back"
coolify_api PATCH "/applications/$APPLICATION_UUID/envs/bulk" '{"data":[{"key":"HEALTHY","value":"false"}]}' >/dev/null
RESULT="$(deploy_and_wait)"
DEPLOYMENT_UUID="${RESULT%%|*}"
DEPLOY_STATUS="${RESULT##*|}"
coolify_api GET "/deployments/$DEPLOYMENT_UUID" > "$ARTIFACTS_DIR/deployments/unhealthy.json"

ROOT_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$APP_DOMAIN/")"
HEALTH_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$APP_DOMAIN/health")"
POST_INFO="$(curl -fsS "$APP_DOMAIN/info")"
POST_MESSAGE="$(echo "$POST_INFO" | jq -r '.message')"
echo "{\"root_http_status\":\"$ROOT_CODE\",\"health_http_status\":\"$HEALTH_CODE\",\"pre_message\":\"$PRE_MESSAGE\",\"post_message\":\"$POST_MESSAGE\"}" > "$ARTIFACTS_DIR/http/unhealthy_info.json"

STATUS="failed"
# Coolify must (a) report the deployment itself as failed, and (b) have kept
# serving the previously-good container throughout, proven by / and /health
# both still responding 200 and the pre-existing message being unchanged.
if [ "$DEPLOY_STATUS" = "failed" ] && [ "$ROOT_CODE" = "200" ] && [ "$HEALTH_CODE" = "200" ] && [ "$POST_MESSAGE" = "$PRE_MESSAGE" ]; then
  STATUS="passed"
fi
record_test "unhealthy" "$STATUS" "$(jq -n \
  --arg deployment_uuid "$DEPLOYMENT_UUID" \
  --arg coolify_status "$DEPLOY_STATUS" \
  --arg root_http_status "$ROOT_CODE" \
  --arg health_http_status "$HEALTH_CODE" \
  --arg serving_message "$POST_MESSAGE" \
  '{deployment_uuid:$deployment_uuid, coolify_status:$coolify_status, root_http_status:$root_http_status, health_http_status:$health_http_status, serving_message:$serving_message, note:"Coolify auto-rolled back the unhealthy container; the previously-good container kept serving throughout"}')"
[ "$STATUS" = "passed" ] || fail "unhealthy test failed: deploy=$DEPLOY_STATUS root=$ROOT_CODE health=$HEALTH_CODE pre_msg=$PRE_MESSAGE post_msg=$POST_MESSAGE"
log "Unhealthy version correctly rejected by Coolify: deploy=$DEPLOY_STATUS, previous container kept serving (/=$ROOT_CODE /health=$HEALTH_CODE, message unchanged)"

log "Restoring healthy version (HEALTHY=true) to prove a normal deploy still succeeds afterwards"
coolify_api PATCH "/applications/$APPLICATION_UUID/envs/bulk" '{"data":[{"key":"HEALTHY","value":"true"}]}' >/dev/null
RESULT="$(deploy_and_wait)"
DEPLOYMENT_UUID="${RESULT%%|*}"
DEPLOY_STATUS="${RESULT##*|}"
coolify_api GET "/deployments/$DEPLOYMENT_UUID" > "$ARTIFACTS_DIR/deployments/health-recovery.json"

HEALTH_CODE_AFTER="$(curl -s -o /dev/null -w '%{http_code}' "$APP_DOMAIN/health")"
echo "{\"health_http_status\":\"$HEALTH_CODE_AFTER\"}" > "$ARTIFACTS_DIR/http/health_recovery_info.json"

STATUS="failed"
[ "$DEPLOY_STATUS" = "finished" ] && [ "$HEALTH_CODE_AFTER" = "200" ] && STATUS="passed"
record_test "health-recovery" "$STATUS" "$(jq -n \
  --arg deployment_uuid "$DEPLOYMENT_UUID" \
  --arg coolify_status "$DEPLOY_STATUS" \
  --arg health_http_status "$HEALTH_CODE_AFTER" \
  '{deployment_uuid:$deployment_uuid, coolify_status:$coolify_status, health_http_status:$health_http_status}')"
[ "$STATUS" = "passed" ] || fail "health recovery test failed: health=$HEALTH_CODE_AFTER deploy=$DEPLOY_STATUS"

log "Health recovery verified: /health -> $HEALTH_CODE_AFTER"

