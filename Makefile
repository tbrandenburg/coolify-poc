SHELL := /bin/bash
ORCH := orchestrator

.PHONY: help install run stop test lint build clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

install: ## Verify required local tooling (git, gh, docker, curl, jq) is present
	@bash $(ORCH)/00_bootstrap.sh

run: ## Run the full state machine end to end (bootstrap -> report -> cleanup)
	@bash $(ORCH)/run.sh

stop: ## Destroy every resource the agent created (Coolify stack, GitHub repo best-effort, temp files)
	@bash $(ORCH)/99_cleanup.sh

test: build ## Build the hello-world test app image locally as a fast pre-flight check
	@echo "Local Docker build OK. Full integration tests run as part of 'make run' against a live Coolify instance."

lint: ## Shellcheck every orchestrator script
	@shellcheck -S warning -e SC1090 -e SC1091 $(ORCH)/*.sh

build: ## Build the hello-world test app's Docker image locally (sanity check before pushing to Coolify)
	@docker build -t coolify-poc-app:local ./app

clean: ## Remove local run state and artifacts (does NOT touch remote/Coolify resources — use 'make stop' first)
	@rm -rf .agent/state.json .agent/resources.json .agent/secrets.env .agent/work
	@rm -rf artifacts/deployments/* artifacts/http/* artifacts/screenshots/* artifacts/report.json artifacts/report.md
	@echo "Local state and artifacts cleared."
