#!/usr/bin/env bash
# 01_create_repo.sh: create a disposable GitHub repo and push the hello-world app.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition BOOTSTRAP CREATE_REPO

RUN_ID="$(state_get run_id)"
[ -n "$RUN_ID" ] || fail "run_id missing; run 00_bootstrap.sh first"

GH_LOGIN="$(state_get github_login)"
REPO_NAME="coolify-agent-smoke-${RUN_ID//[^a-zA-Z0-9]/-}"
REPO_FULL="$GH_LOGIN/$REPO_NAME"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

log "Creating public repo $REPO_FULL"
gh repo create "$REPO_FULL" --public --description "Disposable Coolify agent smoke-test repo (auto-created, auto-deleted)" >/dev/null

resources_set github_repo "$REPO_FULL"

gh repo clone "$REPO_FULL" "$WORK_DIR/repo" >/dev/null

cp -r "$ROOT_DIR/app/." "$WORK_DIR/repo/"

cat > "$WORK_DIR/repo/README.md" <<EOF
# coolify-agent-smoke

Disposable test app created and driven autonomously by the coolify-poc agent
(run id: $RUN_ID). This repo, and every Coolify resource pointing at it, is
deleted at the end of the run.
EOF

mkdir -p "$WORK_DIR/repo/.agent"
echo "{\"run_id\": \"$RUN_ID\"}" > "$WORK_DIR/repo/.agent/state.json"

pushd "$WORK_DIR/repo" >/dev/null
git checkout -b main 2>/dev/null || git checkout main
git add -A
git -c user.name="coolify-poc-agent" -c user.email="agent@example.invalid" \
  commit -m "chore: baseline hello-world app (v1)" >/dev/null
git push -u origin main >/dev/null
COMMIT_SHA="$(git rev-parse HEAD)"
popd >/dev/null

state_set repo_full "$REPO_FULL"
state_set repo_default_branch "main"
state_set last_commit_sha "$COMMIT_SHA"
state_set app_version "v1"

log "Repo created and pushed: https://github.com/$REPO_FULL (commit $COMMIT_SHA)"
