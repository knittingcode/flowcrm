# FlowCRM developer commands. Docker work is done by bin/devenv; this file
# stays compatible with GNU Make 3.81 (the macOS default).
# Variables given on the command line (FLOWCRM_*, SERVICE, TAIL, FOLLOW)
# reach bin/devenv through the environment.

DEVENV := ./bin/devenv

.DEFAULT_GOAL := help
.PHONY: help up down restart status url ports logs doctor test-devenv

help: ## Show this help
	@echo 'Usage: make <target>'
	@echo
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  %-12s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo 'Ports: FLOWCRM_PORT_DEFAULT=8080 FLOWCRM_PORT_RANGE=8080-8099; FLOWCRM_HTTP_PORT forces one port.'
	@echo 'See docs/dev-environment.md.'

up: ## Start the stack on an automatically chosen port and print its URL
	@$(DEVENV) up

down: ## Stop this checkout's containers (volumes and saved port are kept)
	@$(DEVENV) down

restart: ## Stop and start again, preferring the saved port
	@$(DEVENV) restart

status: ## Show container state and the saved port
	@$(DEVENV) status

url: ## Print the verified URL (fails when not running)
	@$(DEVENV) url

ports: ## Show candidate ports and who uses them (read-only)
	@$(DEVENV) ports

logs: ## Show recent logs (SERVICE=edge|state TAIL=200 FOLLOW=1)
	@$(DEVENV) logs

doctor: ## Check prerequisites (read-only)
	@$(DEVENV) doctor

test-devenv: ## Run the allocator unit and real-Docker integration tests
	@tests/devenv/unit.sh
	@tests/devenv/integration.sh
