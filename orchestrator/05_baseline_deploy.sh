#!/usr/bin/env bash
# 05_baseline_deploy.sh: trigger the first deployment via the API, poll it to
# completion, and verify the app via real HTTP requests (not "looks right").
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition CREATE_APP BASELINE_DEPLOY

APP_DOMAIN="$(state_get app_domain)"

RESULT="$(deploy_and_wait)"
DEPLOYMENT_UUID="${RESULT%%|*}"
DEPLOY_STATUS="${RESULT##*|}"
log "Baseline deployment $DEPLOYMENT_UUID finished with status: $DEPLOY_STATUS"

coolify_api GET "/deployments/$DEPLOYMENT_UUID" > "$ARTIFACTS_DIR/deployments/baseline.json"

HTTP_INFO="$(curl -fsS "$APP_DOMAIN/info")"
HTTP_HEALTH_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$APP_DOMAIN/health")"
VERSION="$(echo "$HTTP_INFO" | jq -r '.version')"
HEALTHY="$(echo "$HTTP_INFO" | jq -r '.healthy')"

echo "$HTTP_INFO" > "$ARTIFACTS_DIR/http/baseline_info.json"

STATUS="failed"
if [ "$DEPLOY_STATUS" = "finished" ] && [ "$VERSION" = "v1" ] && [ "$HTTP_HEALTH_CODE" = "200" ] && [ "$HEALTHY" = "true" ]; then
  STATUS="passed"
fi

record_test "baseline" "$STATUS" "$(jq -n \
  --arg deployment_uuid "$DEPLOYMENT_UUID" \
  --arg coolify_status "$DEPLOY_STATUS" \
  --arg http_status "$HTTP_HEALTH_CODE" \
  --arg version "$VERSION" \
  '{deployment_uuid:$deployment_uuid, coolify_status:$coolify_status, http_status:$http_status, version:$version}')"

[ "$STATUS" = "passed" ] || fail "baseline deploy test failed (see artifacts/report.json)"

log "Baseline deployment verified: version=$VERSION healthy=$HEALTHY http_status=$HTTP_HEALTH_CODE"
