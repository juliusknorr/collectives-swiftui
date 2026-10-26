.PHONY: help build run test server-up server-test server-down signing-setup

help:
	@printf '%s\n' 'make build        Build the local Mac app bundle' 'make run          Build and open the Mac app (quit an older copy first)' 'make test         Run Swift tests' 'make signing-setup Create a persistent local development signing identity' 'make server-up    Start and seed the local Nextcloud server' 'make server-test  Run integration checks against the running server' 'make server-down  Stop the local server, retaining its data'

build:
	@bash scripts/dev.sh build

run:
	@bash scripts/dev.sh run

test:
	@bash scripts/dev.sh test

server-up:
	@bash dev/setup.sh

server-test:
	@NEXTCLOUD_URL="$${NEXTCLOUD_URL:-http://localhost:$${NEXTCLOUD_PORT:-8080}}" python3 dev/smoke.py

server-down:
	@docker compose -f dev/compose.yaml down

signing-setup:
	@python3 scripts/setup-local-signing.py
