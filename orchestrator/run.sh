#!/usr/bin/env bash
# run.sh: drives the full state machine end to end. CLEANUP always runs,
# even on failure (trap), unless SKIP_CLEANUP=1 is set (useful for debugging
# a specific step against a live Coolify instance).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

STEPS=(
  00_bootstrap.sh
  01_create_repo.sh
  02_start_coolify.sh
  03_bootstrap_coolify.sh
  04_create_app.sh
  05_baseline_deploy.sh
  06_auto_deploy_test.sh
  07_failed_build_test.sh
  08_env_test.sh
  09_health_test.sh
  10_rollback_test.sh
  11_pr_preview_test.sh
  12_report.sh
)

cleanup_and_exit() {
  local code=$?
  if [ "${SKIP_CLEANUP:-0}" != "1" ]; then
    bash ./99_cleanup.sh
  else
    echo "SKIP_CLEANUP=1 set — leaving all resources running for inspection" >&2
  fi
  exit "$code"
}
trap cleanup_and_exit EXIT

for step in "${STEPS[@]}"; do
  echo "=== running $step ===" >&2
  bash "./$step"
done
