# Makefile for Kai project
# Provides test targets to run integration tests

.PHONY: test test-preflight test-main test-all clean

test: test-preflight test-main

test-main:
	@echo "Running main integration tests..."
	@bash -lc '\
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then \
	  docker compose up --build --abort-on-container-exit --exit-code-from tester; \
	elif command -v docker-compose >/dev/null 2>&1; then \
	  docker-compose up --build --abort-on-container-exit --exit-code-from tester; \
	else \
	  echo "Docker Compose not found. Install Docker Compose and try again."; exit 1; \
	fi'

test-preflight:
	@echo "Running preflight checks..."
	@bash -lc 'bash tests/check_executables.sh'

test-all: test-main
	@echo ""
	@echo "==============================================="
	@echo "All tests completed successfully!"
	@echo "==============================================="

clean:
	@echo "Stopping and removing test containers (if any)..."
	@bash -lc '\
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then \
	  docker compose down --remove-orphans || true; \
	elif command -v docker-compose >/dev/null 2>&1; then \
	  docker-compose down --remove-orphans || true; \
	else \
	  true; \
	fi'