# Coolify Autonomous Smoke-Test POC

A GitHub-driven, self-verifying agent prototype: starting from a single
externally supplied credential (`GH_TOKEN`), it autonomously creates a test
repo, boots a disposable local Coolify instance, bootstraps its own
short-lived Coolify API token, deploys a small app from that repo through
Coolify's API, and drives + verifies a full deployment lifecycle (baseline
deploy, Git-driven redeploy, broken build, env vars, health-check
failure/rollback, deployment rollback, and a real GitHub PR lifecycle) —
entirely via HTTP/API assertions, never by "looks right."

Full design, state machine, and results (including real corrections found
while building this) are in [`docs/POC.md`](docs/POC.md).

## Why this exists

`GH_TOKEN` is **not** a Coolify credential. Coolify's protected API requires
its own bearer token, and self-hosted instances must have API access
explicitly enabled. This prototype proves an agent can go from "one GitHub
token" to "a fully verified, self-hosted CI/CD loop" by bootstrapping that
second credential itself, on a Coolify instance it just started and fully
controls — and by tearing everything down again afterwards.

## Requirements

- `git`, `gh` (authenticated: `gh auth status`), `docker` with the `compose`
  plugin, `curl`, `jq`
- ~7GB RAM / a few GB disk free (Coolify's dev stack: Postgres, Redis,
  Soketi, the Coolify app itself)
- Outbound network access to GitHub and to pull Docker images

## Quick start

```bash
make install   # verify tooling + GitHub auth
make run       # bootstrap -> create repo -> start Coolify -> deploy -> test -> report -> cleanup
```

`make run` executes the full state machine end to end and **always tears
down everything it created**, even on failure (trap-based cleanup). Results
land in `artifacts/report.md` (human-readable) and `artifacts/report.json`
(machine-readable), with raw deployment logs, raw HTTP assertions, and
screenshots alongside.

To stop early / clean up a run that was interrupted:

```bash
make stop
```

## Makefile targets

| Target | What it does |
|---|---|
| `make install` | Verifies `git`, `gh`, `docker`, `curl`, `jq` are present and `gh` is authenticated |
| `make run` | Runs the full state machine (see `docs/POC.md`) end to end, with automatic cleanup |
| `make stop` | Destroys every resource the agent created (Coolify app/project/token, Docker stack, temp files) |
| `make test` | Fast local sanity check: builds the hello-world app's Docker image (full integration tests run via `make run`) |
| `make lint` | Shellchecks every orchestrator script |
| `make build` | Builds the hello-world test app's Docker image locally |
| `make clean` | Clears local run state/artifacts only (does not touch remote or Coolify resources — run `make stop` first) |

## Layout

```
app/            the 4-route hello-world test app (/, /health, /info, /crash)
orchestrator/   the state-machine driver (00_bootstrap.sh ... 99_cleanup.sh, run.sh)
docs/POC.md     full design doc, state machine, discovered real-world corrections
artifacts/      report.json / report.md, raw deployment logs, raw HTTP assertions, screenshots
```

## Known limitation

Auto-deleting the GitHub test repo requires the `delete_repo` OAuth scope on
`GH_TOKEN`. If the token wasn't pre-scoped with it, `make stop` will log a
clear warning and skip that one step (everything else is still torn down).
See "Known limitations" in `docs/POC.md` for the exact manual follow-up
command.

## License

[MIT](LICENSE)
