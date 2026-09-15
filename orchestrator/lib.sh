#!/usr/bin/env bash
# Shared helpers for the orchestrator state machine.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_DIR="$ROOT_DIR/.agent"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
STATE_FILE="$AGENT_DIR/state.json"
RESOURCES_FILE="$AGENT_DIR/resources.json"
SECRETS_FILE="$AGENT_DIR/secrets.env"   # gitignored, never committed
WORK_DIR="$AGENT_DIR/work"              # local clone of the test repo

mkdir -p "$AGENT_DIR" "$ARTIFACTS_DIR/deployments" "$ARTIFACTS_DIR/http" "$ARTIFACTS_DIR/screenshots"

log() {
  echo "[$(date '+%H:%M:%S')] $*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

state_init() {
  [ -f "$STATE_FILE" ] || echo '{"state":"NEW"}' > "$STATE_FILE"
  [ -f "$RESOURCES_FILE" ] || echo '{}' > "$RESOURCES_FILE"
}

state_set() {
  local key="$1" value="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

state_get() {
  local key="$1"
  jq -r --arg k "$key" '.[$k] // empty' "$STATE_FILE"
}

resources_set() {
  local key="$1" value="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$RESOURCES_FILE" > "$tmp"
  mv "$tmp" "$RESOURCES_FILE"
}

resources_get() {
  local key="$1"
  jq -r --arg k "$key" '.[$k] // empty' "$RESOURCES_FILE"
}

resources_append() {
  local key="$1" value="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$key" --arg v "$value" '.[$k] = ((.[$k] // []) + [$v])' "$RESOURCES_FILE" > "$tmp"
  mv "$tmp" "$RESOURCES_FILE"
}

transition() {
  local from="$1" to="$2"
  local current
  current="$(state_get state)"
  if [ -n "$current" ] && [ "$current" != "$from" ] && [ "$current" != "NEW" ]; then
    log "WARN: expected state $from but found $current (continuing anyway)"
  fi
  state_set state "$to"
  log "STATE -> $to"
}

record_test() {
  # record_test <name> <status: passed|failed> <json-details>
  local name="$1" status="$2" details="$3"
  local file="$ARTIFACTS_DIR/report.json"
  [ -f "$file" ] || echo '{"tests":[]}' > "$file"
  local tmp
  tmp="$(mktemp)"
  jq --arg n "$name" --arg s "$status" --argjson d "$details" \
    '.tests += [{"test":$n,"status":$s} + $d]' "$file" > "$tmp"
  mv "$tmp" "$file"
  log "TEST [$status] $name"
}

wait_for_http() {
  local url="$1" timeout="${2:-120}" interval="${3:-2}"
  local elapsed=0
  while ! curl -fsS -o /dev/null "$url" 2>/dev/null; do
    sleep "$interval"
    elapsed=$((elapsed + interval))
    if [ "$elapsed" -ge "$timeout" ]; then
      fail "timed out waiting for $url after ${timeout}s"
    fi
  done
}

coolify_api() {
  local method="$1" path="$2" data="${3:-}"
  source "$SECRETS_FILE"
  local coolify_url
  coolify_url="$(state_get coolify_url)"
  if [ -n "$data" ]; then
    curl -fsS -X "$method" -H "Authorization: Bearer $COOLIFY_TOKEN" -H "Content-Type: application/json" \
      "$coolify_url/api/v1$path" -d "$data"
  else
    curl -fsS -X "$method" -H "Authorization: Bearer $COOLIFY_TOKEN" "$coolify_url/api/v1$path"
  fi
}

# deploy_and_wait -> prints "<deployment_uuid>|<status>" to stdout.
deploy_and_wait() {
  local application_uuid resp deployment_uuid status attempts=0
  application_uuid="$(state_get application_uuid)"
  resp="$(coolify_api POST "/applications/$application_uuid/start")"
  deployment_uuid="$(echo "$resp" | jq -r '.deployment_uuid')"
  [ -n "$deployment_uuid" ] && [ "$deployment_uuid" != "null" ] || fail "no deployment_uuid in response: $resp"
  log "Deployment queued: $deployment_uuid" >&2
  while true; do
    status="$(coolify_api GET "/deployments/$deployment_uuid" | jq -r '.status')"
    { [ "$status" = "finished" ] || [ "$status" = "failed" ]; } && break
    attempts=$((attempts + 1))
    [ "$attempts" -ge 90 ] && fail "deployment $deployment_uuid did not finish within timeout (last status: $status)"
    sleep 5
  done
  echo "${deployment_uuid}|${status}"
}

# git_commit_and_push <commit_message> -> commits whatever's staged/modified
# in $WORK_DIR/repo and pushes to the default branch, printing the new SHA.
git_commit_and_push() {
  local message="$1"
  pushd "$WORK_DIR/repo" >/dev/null
  git add -A
  git -c user.name="coolify-poc-agent" -c user.email="agent@example.invalid" commit -m "$message" >/dev/null
  git push >/dev/null
  git rev-parse HEAD
  popd >/dev/null
}
