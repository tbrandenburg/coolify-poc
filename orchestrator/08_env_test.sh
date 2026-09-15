#!/usr/bin/env bash
# 08_env_test.sh: set application env vars purely through the Coolify API,
# redeploy, and prove the new values are actually served (twice, to prove
# it's not a fluke / cached value).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition FAILED_BUILD_TEST ENV_TEST

APPLICATION_UUID="$(state_get application_uuid)"
APP_DOMAIN="$(state_get app_domain)"

set_envs_and_verify() {
  local message_value="$1" expected_message="$2" test_name="$3"
  coolify_api PATCH "/applications/$APPLICATION_UUID/envs/bulk" "$(jq -n --arg m "$message_value" '{data:[{key:"MESSAGE", value:$m}, {key:"ENVIRONMENT", value:"production"}]}')" >/dev/null

  local result deployment_uuid deploy_status
  result="$(deploy_and_wait)"
  deployment_uuid="${result%%|*}"
  deploy_status="${result##*|}"
  coolify_api GET "/deployments/$deployment_uuid" > "$ARTIFACTS_DIR/deployments/env-$test_name.json"

  local http_info actual_message
  http_info="$(curl -fsS "$APP_DOMAIN/info")"
  actual_message="$(echo "$http_info" | jq -r '.message')"
  echo "$http_info" > "$ARTIFACTS_DIR/http/env_${test_name}_info.json"

  local status="failed"
  [ "$deploy_status" = "finished" ] && [ "$actual_message" = "$expected_message" ] && status="passed"

  record_test "env-$test_name" "$status" "$(jq -n \
    --arg deployment_uuid "$deployment_uuid" \
    --arg coolify_status "$deploy_status" \
    --arg expected "$expected_message" \
    --arg actual "$actual_message" \
    '{deployment_uuid:$deployment_uuid, coolify_status:$coolify_status, expected_message:$expected, actual_message:$actual}')"

  [ "$status" = "passed" ] || fail "env test '$test_name' failed: expected='$expected_message' actual='$actual_message' deploy=$deploy_status"
  log "env test '$test_name' verified: message='$actual_message'"
}

set_envs_and_verify "hello-from-agent" "hello-from-agent" "first"
set_envs_and_verify "updated-by-agent" "updated-by-agent" "second"

log "Environment variable test suite passed (two distinct values, both served correctly)"
