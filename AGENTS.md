# AGENTS.md

## Purpose of this repo

This repo is a **prototype**, not a product: it proves that an autonomous
agent, starting from a single externally supplied credential (`GH_TOKEN`),
can drive a real, self-hosted CI/CD loop end to end and verify every step
with HTTP/API evidence instead of "looks right."

Concretely, it:

1. Creates a disposable GitHub repo and commits a tiny 4-route Node app.
2. Boots a disposable local Coolify instance via Docker.
3. Bootstraps its own short-lived Coolify API token (Coolify's protected API
   is a separate credential from `GH_TOKEN` and must be enabled/created
   locally — see `docs/POC.md` for why).
4. Creates a Coolify project + application from the public repo via API.
5. Drives and verifies a full deployment lifecycle: baseline deploy,
   Git-push-driven redeploy, a deliberately broken build, env var changes,
   a health-check failure + auto-rollback, an explicit deployment rollback,
   and a real GitHub PR open/close lifecycle.
6. Emits a machine-readable + human-readable report with raw deployment
   logs, raw HTTP assertions, and screenshots as evidence.
7. Tears down every resource it created.

Read [`docs/POC.md`](docs/POC.md) first — it has the full state machine,
design rationale, and (importantly) a list of real-world corrections
discovered while building this against an actual Coolify instance. Don't
trust assumptions in that doc that aren't backed by the "Results" section;
prefer what's proven to have actually happened.

## Repo layout

```
app/            the hello-world test app deployed BY the orchestrator (/, /health, /info, /crash)
orchestrator/   the state-machine driver — this is the actual "agent" code
docs/POC.md     design doc + state machine + discovered real-world corrections
artifacts/      evidence from the last run: report.json/md, deployment logs, HTTP assertions, screenshots
```

`app/` is not this repo's product — it's disposable fixture content that
gets pushed into a *separate*, throwaway GitHub repo created at runtime
(`orchestrator/01_create_repo.sh`). Don't confuse changes to `app/` with
changes to the orchestrator; `app/` only matters insofar as it needs to keep
exercising `/health`, `/info`, `VERSION`, `MESSAGE`, `HEALTHY` the way the
test scripts expect.

## Make targets

| Target | What it does |
|---|---|
| `make install` | Verifies `git`, `gh`, `docker`, `curl`, `jq` are present and `gh` is authenticated. Run this first. |
| `make run` | Runs the full state machine end to end (`orchestrator/run.sh`): bootstrap → create repo → start Coolify → bootstrap Coolify → create app → all test steps → report → cleanup. Cleanup runs even on failure (trap). |
| `make stop` | Runs `orchestrator/99_cleanup.sh` directly — destroys every tracked resource (Coolify app/project/token, Docker stack, orphaned Coolify proxy/sentinel containers, temp files). Use this if a run was interrupted or you were debugging with `SKIP_CLEANUP=1`. |
| `make test` | Fast local sanity check only (builds the app's Docker image). The real integration tests are the state machine steps run via `make run` — there is no separate unit test suite. |
| `make lint` | `shellcheck -S warning -e SC1090 -e SC1091` across every `orchestrator/*.sh`. Must stay clean. |
| `make build` | Builds `app/`'s Docker image locally as `coolify-poc-app:local` — a quick way to catch a broken Dockerfile before it ever reaches Coolify. |
| `make clean` | Clears local run state and `artifacts/` only. Does **not** touch anything remote/live — always run `make stop` first if a Coolify instance might still be running. |

## How to develop here

### Running a single step in isolation

Each `orchestrator/NN_*.sh` script is runnable standalone as long as the
steps before it have already run (state is persisted in `.agent/state.json`,
resources tracked in `.agent/resources.json`, secrets in the gitignored
`.agent/secrets.env`). This is the normal way to iterate on one step:

```bash
bash orchestrator/00_bootstrap.sh
bash orchestrator/01_create_repo.sh
bash orchestrator/02_start_coolify.sh
bash orchestrator/03_bootstrap_coolify.sh
# ...iterate on, say, 09_health_test.sh directly, rerunning it as needed...
bash orchestrator/09_health_test.sh
```

Scripts warn (but don't abort) if the recorded state doesn't match what
they expect, so re-running a step after fixing a bug is normal and safe.

To debug against a live Coolify instance without tearing it down at the end:

```bash
SKIP_CLEANUP=1 make run
```

Then inspect state directly:

```bash
cat .agent/state.json | jq .
cat .agent/resources.json | jq .
source .agent/secrets.env   # COOLIFY_TOKEN — never commit or log this
```

When done, always `make stop` to avoid leaking Docker containers/volumes or
Coolify resources between runs.

### Adding a new test step

1. Add `orchestrator/NN_your_test.sh` following the existing pattern:
   `transition <PREV_STATE> <NEW_STATE>`, do the work, call
   `record_test "<name>" "<passed|failed>" "<json details>"`, and `fail`
   loudly on any unexpected result (never silently continue past a broken
   assertion).
2. Reuse the shared helpers in `orchestrator/lib.sh`:
   `coolify_api`, `deploy_and_wait`, `git_commit_and_push`, `wait_for_http`,
   `record_test`, `resources_set`/`resources_append` (for anything that must
   be cleaned up later), `state_set`/`state_get`.
3. Wire it into `STEPS=(...)` in `orchestrator/run.sh`, in the right
   position, and update the state machine diagram in `docs/POC.md`.
4. Track any new external resource you create in `.agent/resources.json`
   (via `resources_set`/`resources_append`) and add its teardown to
   `orchestrator/99_cleanup.sh` — cleanup must stay best-effort (log a
   warning and continue) rather than aborting halfway.
5. Run `make lint` before committing.

### Evidence discipline

Every test must produce and check real evidence — an HTTP status code, a
Coolify deployment status, a JSON field from `/info` — never an assumption.
If you find Coolify (or anything else) doesn't behave the way you expected,
that's a signal to **fix the test's assertions to match observed reality**,
not to loosen them until they pass. `docs/POC.md`'s "Real-world corrections"
section exists for exactly this reason — add to it when you find another one.

### Known environment quirks worth knowing before you touch `02_start_coolify.sh` / `03_bootstrap_coolify.sh`

- Coolify's dev seeder pre-creates a `localhost` server whose IP only
  resolves inside the single-instance `docker-compose.dev.yml` topology.
  We use `scripts/dev-instances` (isolated compose project) instead, which
  needs the optional `testing-host` profile explicitly started and the
  server's IP repointed at it — already handled in
  `03_bootstrap_coolify.sh`, but do not "simplify" this away.
- Coolify creates a proxy + sentinel container **outside** the
  docker-compose project scope. `docker compose down` will not remove them;
  `99_cleanup.sh` removes them explicitly by name/network. If you change how
  Coolify is started, re-verify this still gets cleaned up (`docker ps -a`
  should show zero `coolify-*` containers after `make stop`).
- This host may already have unrelated services bound to Coolify's default
  ports (8000, 5173, 6001, 9000, 9001). We use dev-instance **"b"**
  (port 8001 and offset ports) rather than "a" — don't hardcode port 8000
  anywhere new.

## Secrets

The only credential you provide is `GH_TOKEN` (via an authenticated `gh`
CLI). The Coolify API token is bootstrapped locally at runtime and lives
only in the gitignored `.agent/secrets.env` and in Coolify's own database
inside the disposable containers — never commit it, never print it in full
in logs, and make sure it's destroyed by `99_cleanup.sh` along with the
Coolify instance itself.
