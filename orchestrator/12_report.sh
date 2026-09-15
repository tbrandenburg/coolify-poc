#!/usr/bin/env bash
# 12_report.sh: aggregate artifacts/report.json (deduped to the latest result
# per test name) into a human-readable artifacts/report.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition PR_PREVIEW_TEST REPORT

REPORT_JSON="$ARTIFACTS_DIR/report.json"
[ -f "$REPORT_JSON" ] || fail "no report.json found; did any test steps run?"

# Dedupe: keep only the last recorded result per test name (reruns replace
# earlier attempts, e.g. a script bug fixed mid-run).
DEDUPED="$(jq '{tests: (.tests | group_by(.test) | map(.[-1]))}' "$REPORT_JSON")"
echo "$DEDUPED" > "$REPORT_JSON"

TOTAL="$(echo "$DEDUPED" | jq '.tests | length')"
PASSED="$(echo "$DEDUPED" | jq '[.tests[] | select(.status=="passed")] | length')"
FAILED="$(echo "$DEDUPED" | jq '[.tests[] | select(.status!="passed")] | length')"

{
  echo "# Coolify Autonomous Smoke-Test Report"
  echo
  echo "Run ID: $(state_get run_id)"
  echo "Repo: https://github.com/$(state_get repo_full)"
  echo "Coolify: $(state_get coolify_url) (application $(state_get application_uuid))"
  echo
  echo "**Result: $PASSED/$TOTAL tests passed**"
  echo
  echo "| Test | Status | Details |"
  echo "|---|---|---|"
  echo "$DEDUPED" | jq -r '.tests[] | "| \(.test) | \(if .status=="passed" then "✅ PASS" else "❌ FAIL" end) | \(. | del(.test,.status) | tojson) |"'
  echo
  echo "Raw evidence: \`artifacts/deployments/*.json\` (full Coolify deployment logs), \`artifacts/http/*.json\` (raw HTTP assertions)."
} > "$ARTIFACTS_DIR/report.md"

log "Report written: $PASSED/$TOTAL passed -> artifacts/report.md"
[ "$FAILED" -eq 0 ] || fail "$FAILED test(s) failed — see artifacts/report.md"
