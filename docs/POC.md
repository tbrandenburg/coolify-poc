# Coolify Autonomous Smoke-Test POC

## Goal

Build a GitHub-driven, self-verifying agent prototype that, starting from a
single externally supplied credential (`GH_TOKEN`), autonomously:

1. Creates a disposable GitHub test repository containing a tiny hello-world
   Docker app.
2. Starts a disposable, local Coolify instance via Docker.
3. Bootstraps a short-lived Coolify API token (Coolify's protected API needs
   its own bearer token; `GH_TOKEN` cannot be used for it).
4. Creates a Coolify application from the public GitHub repo via API.
5. Drives a sequence of deployments (baseline, update, broken build, unhealthy
   version, rollback) purely through Git commits + Coolify API calls.
6. Verifies every step with HTTP/API assertions (never "looks right").
7. Exercises the one credential it actually has (`GH_TOKEN`) by opening and
   closing a real GitHub PR.
8. Emits a machine-readable + human-readable report with evidence.
9. Cleans up every resource it created (GitHub repo, Coolify app/project,
   Coolify token, Docker stack, temp files) — even on failure.

## Non-goals (explicitly out of scope for v1)

- GitHub App / webhook-based auto-deploy and native PR Preview Deployments.
  These require Coolify to be reachable from GitHub.com over a public
  endpoint (tunnel or public host). Out of scope for a local-only agent with
  zero extra credentials. Tracked as a v2 follow-up.
- GitHub Actions calling Coolify's API. Same public-reachability problem when
  Coolify only runs on localhost. The orchestrator itself plays the role of
  "the thing that calls Coolify after a Git push" instead.

## Credential lifecycle

```
GH_TOKEN (supplied, external)
      │
      ▼
Agent launches disposable local Coolify (Docker)
      │
      ▼
Agent bootstraps a local Coolify admin account + API token
      │
      ▼
temporary COOLIFY_TOKEN (memory / gitignored temp file only)
      │
      ▼
all remaining Coolify automation
      │
      ▼
destroyed together with the Coolify instance at CLEANUP
```

`GH_TOKEN` is never a Coolify credential — Coolify's protected API requires
its own bearer token, and self-hosted instances must have API access enabled
first. A fully autonomous run therefore *acquires* a second, disposable
credential during BOOTSTRAP_COOLIFY. It does not extend or reuse the GitHub
token for Coolify.

## State machine

```
BOOTSTRAP → CREATE_REPO → START_COOLIFY → BOOTSTRAP_COOLIFY → CREATE_APP
  → BASELINE_DEPLOY → AUTO_DEPLOY_TEST → FAILED_BUILD_TEST → ENV_TEST
  → HEALTH_TEST → ROLLBACK_TEST → PR_PREVIEW_TEST → REPORT → CLEANUP
```

State is persisted to `.agent/state.json` after every transition so the run
is resumable/inspectable, and every created external resource is recorded in
`.agent/resources.json` so CLEANUP is deterministic instead of best-effort.

## Test application

Minimal Node.js app, four routes:

- `/` — HTML identifying the deployed version
- `/health` — configurable 200/500 via env var
- `/info` — JSON: `{version, environment, message, healthy}`
- `/crash` — optional controlled failure endpoint

This gives the agent machine-readable assertions instead of visual
inspection.

## Environment notes discovered during this run

- Host already has a container bound to `0.0.0.0:8000` (an unrelated Zuul
  POC stack: `zuul-poc-logs-1`). Coolify's default UI/proxy port is also
  8000, so the local Coolify stack in this environment must be reconfigured
  to a non-conflicting port (e.g. `8010`) via `.env` before `docker compose
  up`. This is host-run-specific, not a Coolify limitation.
- Host: 2 CPUs / ~7.3 GiB RAM / 41G free disk. Coolify's dev compose stack
  (Postgres, Redis, soketi, coolify app) is expected to fit but leaves little
  headroom for running much else in parallel.
- Tools available and verified on this host: `docker` 29.7.2 (compose v5),
  `gh` 2.45.0 (already authenticated, scopes: repo, workflow, read:org, gist,
  read:packages, delete:packages), `git`, `curl`, `jq`.

## Directory layout

```
coolify-poc/
├── docs/POC.md                 (this file)
├── app/                        (hello-world test app committed to the GH repo)
│   ├── Dockerfile
│   ├── package.json
│   └── server.js
├── orchestrator/                (the state-machine driver, runs on the host)
│   ├── lib.sh
│   ├── 00_bootstrap.sh
│   ├── 01_create_repo.sh
│   ├── 02_start_coolify.sh
│   ├── 03_bootstrap_coolify.sh
│   ├── 04_create_app.sh
│   ├── 05_baseline_deploy.sh
│   ├── 06_auto_deploy_test.sh
│   ├── 07_failed_build_test.sh
│   ├── 08_env_test.sh
│   ├── 09_health_test.sh
│   ├── 10_rollback_test.sh
│   ├── 11_pr_preview_test.sh
│   ├── 12_report.sh
│   ├── 99_cleanup.sh
│   └── run.sh                  (drives the state machine end to end)
├── .agent/
│   ├── state.json              (current state + discovered UUIDs, gitignored secrets)
│   └── resources.json          (everything created, for deterministic cleanup)
└── artifacts/
    ├── report.json
    ├── report.md
    ├── deployments/*.log
    ├── http/assertions.json
    └── screenshots/*.png       (evidence)
```

## Declarative test matrix

```yaml
tests:
  - name: baseline
    commit: good-v1
    expect: {deployment: success, http_status: 200, version: v1}
  - name: update
    commit: good-v2
    expect: {deployment: success, version: v2}
  - name: broken-build
    commit: broken-build
    expect: {deployment: failed, serving_version: v2}
  - name: unhealthy
    commit: unhealthy-v3
    expect: {health: unhealthy}
  - name: rollback
    commit: bad-v4
    action: rollback
    expect: {serving_version: v3}
  - name: pr-lifecycle
    action: open-close-pr
    expect: {pr_opened: true, pr_closed: true}
```

## Evidence policy

Every test step must record, not just claim, its result:

```json
{
  "test": "failed-build",
  "status": "passed",
  "git_commit": "2ab187d",
  "deployment_uuid": "xyz123",
  "coolify_status": "failed",
  "http_status": 200,
  "running_version": "v2"
}
```

Aggregated into `artifacts/report.json` / `artifacts/report.md`, with raw
deployment logs and HTTP assertion dumps kept alongside for audit.

## Cleanup

Tracked in `.agent/resources.json`:

```json
{
  "github_repo": "coolify-agent-smoke-<id>",
  "github_prs": [1],
  "coolify_project_uuid": "...",
  "coolify_application_uuid": "...",
  "coolify_token_created": true,
  "docker_project": "coolify-poc-<id>"
}
```

CLEANUP runs even on failure (trap-based in `run.sh`):
close PR → delete GitHub repo → delete Coolify app/project →
`docker compose down -v` → revoke/forget temp Coolify token →
remove temp working directory.

## Results (last executed run)

**9/9 tests passed.** Full machine-readable evidence in `artifacts/report.json`
/ `artifacts/report.md`, raw Coolify deployment logs in
`artifacts/deployments/*.json`, raw HTTP assertions in `artifacts/http/*.json`,
and visual evidence in `artifacts/screenshots/*.png` (Coolify app config page,
Coolify deployments list, the deployed hello-world app's `/` and `/info`
pages, and the opened-then-closed GitHub PR).

| Test | Result |
|---|---|
| baseline (v1 deploy) | ✅ |
| update (v2 via git push) | ✅ |
| broken-build | ✅ |
| env vars (two distinct values) | ✅ |
| unhealthy (500 health check) | ✅ |
| health-recovery | ✅ |
| rollback | ✅ |
| pr-lifecycle | ✅ |

Cleanup: Coolify application, project, API token, the full local Coolify
Docker stack (containers, volumes, network, orphaned proxy/sentinel
containers), and the local working directory were all destroyed. The GitHub
test repo could **not** be auto-deleted — see "Known limitations" below.

### Real-world corrections discovered while building this (the plan above was written before running anything against a real Coolify)

1. **Dev seed's default server target doesn't work with `scripts/dev-instances`.**
   Coolify's dev database seeder pre-creates a `localhost` server pointing at
   a hardcoded hostname (`coolify-testing-host`) that only exists in the
   single-instance `docker-compose.dev.yml` topology. `scripts/dev-instances`
   (the tool actually meant for running isolated dev stacks, used here to
   avoid port conflicts) uses a different compose file/network. Fix: start
   the optional `testing-host` profile service and repoint the seeded
   server's IP at its real DNS name, then trigger `POST
   /servers/{uuid}/validate` and poll until `settings.is_reachable` /
   `is_usable` are both true. Encapsulated in `03_bootstrap_coolify.sh`.
2. **`gh repo create --clone` takes a boolean flag, not a path.** Fixed by
   splitting into `gh repo create` + `gh repo clone`.
3. **Health-check failures don't produce a "deployed but unhealthy" app** —
   they produce a **failed deployment with an automatic rollback**. Coolify
   builds and starts the new container, polls its own Docker healthcheck
   against `/health`, observes the real 500, exhausts its retry budget, marks
   the new container unhealthy, rolls back to the previous good container,
   and reports the deployment itself as `failed`. Verified directly from the
   deployment's own log stream (`docker inspect ... State.Health.Log`
   entries showing `wget: server returned error: HTTP/1.1 500`, followed by
   `New container is not healthy, rolling back to the old container.`). This
   is stronger production-safety behavior than originally assumed in the
   plan, and the test (`09_health_test.sh`) was corrected to assert it.
4. **Host-specific port collisions**: this host already had unrelated
   containers bound to 8000, 5173, 6001, 9000, 9001 (a Zuul CI POC stack, and
   `scripts/dev-instances`' own instance "a"). Solved by using dev-instance
   **"b"** (port 8001 and offset ports), not by hand-editing `.env`.
5. **Frontend asset permission drift.** Coolify's dev instance runs a
   root-owned build inside a container against a host bind-mount; a first
   failed attempt left `node_modules` root-owned, which then made a
   host-side `npm run build` fail with `EACCES`. This only affects the UI
   (needed for the evidence screenshots); the API — which is all the
   automation actually depends on — was unaffected throughout. Fixed with a
   throwaway `docker run --rm -v ...:/w alpine chown -R $(id -u):$(id -g)
   /w/node_modules`.

### Known limitations

- **GitHub repo auto-deletion**: the `gh` token used in this environment was
  pre-authenticated without the `delete_repo` OAuth scope, and upgrading a
  token's scopes (`gh auth refresh -s delete_repo`) requires an interactive
  browser authorization step that cannot be completed in a non-interactive
  agent session. `99_cleanup.sh` attempts deletion, logs a clear warning
  on failure, and continues cleaning up everything else rather than
  aborting. **Manual step still required after a run**: `gh auth refresh -h
  github.com -s delete_repo && gh repo delete <repo> --yes`, or delete the
  repo from the GitHub UI. In a real deployment of this agent, the initial
  `GH_TOKEN` should be scoped with `delete_repo` up front to make cleanup
  fully autonomous.
- **v1 does not exercise Coolify's native GitHub-App auto-deploy/preview
  deployments** (by design — see "Non-goals" above). `AUTO_DEPLOY_TEST` and
  the PR test instead prove the two decomposed halves that don't require a
  public webhook endpoint: (a) a Git push deterministically becomes a new
  deployment when the orchestrator calls the deploy API, and (b) the agent
  can drive a full GitHub PR lifecycle with only `GH_TOKEN`.

## v1 scope actually executed by this prototype

1. Create disposable GitHub repo
2. Commit hello-world Docker app
3. Launch disposable local Coolify
4. Bootstrap temporary Coolify API credentials
5. Create public-Git application via API
6. Deploy v1, verify HTTP
7. Push/deploy v2, verify
8. Push broken build, verify deployment fails and v2 survives
9. Push unhealthy version, verify health failure; restore healthy version
10. Push bad-but-healthy version, roll back, verify old version served
11. Open/close a GitHub PR as the GitHub-side lifecycle test
12. Emit JSON/Markdown report with screenshots as evidence
13. Destroy everything
