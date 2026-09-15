#!/usr/bin/env bash
# 11_pr_preview_test.sh: exercise the one credential the agent actually
# started with (GH_TOKEN) end to end: branch, commit, push, open a real PR,
# then close it. Native Coolify GitHub-App preview deployments are out of
# scope for v1 (see docs/POC.md) because they require a public webhook
# endpoint reachable from GitHub.com, which a localhost-only Coolify can't
# provide without a tunnel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition ROLLBACK_TEST PR_PREVIEW_TEST

REPO_FULL="$(state_get repo_full)"
BRANCH_NAME="agent/preview-test"

pushd "$WORK_DIR/repo" >/dev/null
git checkout -b "$BRANCH_NAME"
sed -i "s/^ENV VERSION=.*/ENV VERSION=v4-preview/" Dockerfile
git -c user.name="coolify-poc-agent" -c user.email="agent@example.invalid" \
  commit -am "chore: preview branch for PR lifecycle test" >/dev/null
git push -u origin "$BRANCH_NAME" >/dev/null
popd >/dev/null

log "Opening PR via gh (GH_TOKEN-driven)"
PR_URL="$(gh pr create --repo "$REPO_FULL" --head "$BRANCH_NAME" --base "$(state_get repo_default_branch)" \
  --title "Agent preview lifecycle test" \
  --body "Opened and closed autonomously by the coolify-poc agent to exercise the GH_TOKEN-only credential path (see docs/POC.md, PR_PREVIEW_TEST).")"
PR_NUMBER="$(basename "$PR_URL")"
resources_append github_prs "$PR_NUMBER"
log "Opened PR #$PR_NUMBER: $PR_URL"

PR_STATE_OPEN="$(gh pr view "$PR_NUMBER" --repo "$REPO_FULL" --json state -q .state)"

log "Closing PR #$PR_NUMBER"
gh pr close "$PR_NUMBER" --repo "$REPO_FULL" >/dev/null
PR_STATE_CLOSED="$(gh pr view "$PR_NUMBER" --repo "$REPO_FULL" --json state -q .state)"

STATUS="failed"
[ "$PR_STATE_OPEN" = "OPEN" ] && [ "$PR_STATE_CLOSED" = "CLOSED" ] && STATUS="passed"

record_test "pr-lifecycle" "$STATUS" "$(jq -n \
  --arg pr_number "$PR_NUMBER" \
  --arg pr_url "$PR_URL" \
  --arg opened_state "$PR_STATE_OPEN" \
  --arg closed_state "$PR_STATE_CLOSED" \
  '{pr_number:$pr_number, pr_url:$pr_url, opened_state:$opened_state, closed_state:$closed_state}')"

[ "$STATUS" = "passed" ] || fail "PR lifecycle test failed: opened=$PR_STATE_OPEN closed=$PR_STATE_CLOSED"

log "PR lifecycle verified: #$PR_NUMBER opened ($PR_STATE_OPEN) then closed ($PR_STATE_CLOSED)"
