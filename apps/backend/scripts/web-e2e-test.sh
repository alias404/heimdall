#!/bin/bash

set -e  # Exit on any error

# Runs docker compose test commands from the project root using the shared bin script.
# Uses a subshell so the working directory change doesn't affect the parent script.
docker_compose() {
    (cd ../../ && ./bin/docker-compose-test.sh "$@")
}

# Cleanup function that will be called on script exit or interrupt
cleanup() {
    echo ""
    echo "═══════════════════════════════════════"
    echo "🧹 CLEANUP (Force quit)"
    echo "═══════════════════════════════════════"
    echo ""
    docker_compose down || true
    echo ""
    echo "✅ Cleanup completed"
    exit 0
}

# Prints a preflight failure with an optional hint and exits before any Docker work starts.
precheck_fail() {
    echo "" >&2
    echo "❌ PRECHECK FAILED: $1" >&2
    [ -n "$2" ] && echo "   👉 $2" >&2
    echo "" >&2
    exit 1
}

# Fails the precheck if the given CLI is not on PATH.
require_cli() {
    if ! command -v "$1" >/dev/null 2>&1; then
        precheck_fail "'$1' CLI not found on PATH." "$2"
    fi
}

# Verifies every CLI the run depends on before any containers are started.
precheck_clis() {
    require_cli go "Install Go: https://go.dev/doc/install"
    require_cli make "Install Xcode Command Line Tools: xcode-select --install"
    # Used by the 'pg-goose' make target to run migrations.
    require_cli goose "Install with: go install github.com/pressly/goose/v3/cmd/goose@latest (and make sure \$(go env GOPATH)/bin is on PATH)"
}

# Verifies Docker is usable so failures are explained instead of surfacing as raw compose errors.
precheck_docker() {
    require_cli docker "Install Docker Desktop: https://docs.docker.com/get-docker/"

    if ! docker compose version >/dev/null 2>&1; then
        precheck_fail "Docker Compose v2 is not available ('docker compose')." "Update Docker Desktop or install the compose plugin."
    fi

    # Use the same stripped environment as bin/docker-compose-test.sh so we probe
    # the exact daemon compose will talk to.
    if ! env -i PATH="$PATH" docker info >/dev/null 2>&1; then
        precheck_fail "Docker daemon is not running or not reachable." "Start Docker Desktop (or your Docker engine) and re-run."
    fi
}

echo ""
echo "═══════════════════════════════════════"
echo "🔍 PRECHECKS"
echo "═══════════════════════════════════════"
precheck_clis
echo "✅ Required CLIs found!"
precheck_docker
echo "✅ Docker is ready!"

# Set up signal traps to catch Ctrl+C (SIGINT) and SIGTERM
trap cleanup SIGINT SIGTERM

# Clean environment and start docker compose with test configuration
echo ""
echo "═══════════════════════════════════════"
echo "🐳 DOCKER SETUP"
echo "═══════════════════════════════════════"
docker_compose up -d --build

# Wait for postgres service to be ready
echo ""
echo "⏳ Waiting for postgres to be healthy..."
while ! docker_compose ps postgres --format "table {{.Service}}\t{{.Status}}" | grep -q "healthy"; do
    echo "   Still waiting..."
    sleep 2
done
echo "✅ Postgres is ready!"

# Wait for Redis to be ready
echo ""
echo "⏳ Waiting for Redis to be healthy..."
while ! docker_compose ps redis --format "table {{.Service}}\t{{.Status}}" | grep -q "healthy"; do
    echo "   Still waiting..."
    sleep 2
done
echo "✅ Redis is ready!"

# Run database migrations
echo ""
echo "═══════════════════════════════════════"
echo "📄 DATABASE MIGRATIONS"
echo "═══════════════════════════════════════"
echo ""
make ENV_FILE=".env.test" pg-goose up

echo ""
echo "═══════════════════════════════════════"
echo "🧪 RUNNING TESTS"
echo "═══════════════════════════════════════"
echo ""
set +e  # Don't exit on test failure, we want to clean up first
go test ./tests/web -v
test_status=$?
set -e

echo ""
echo "═══════════════════════════════════════"
echo "🧹 CLEANUP"
echo "═══════════════════════════════════════"
docker_compose down
echo ""

# Clear the trap since we're doing normal cleanup
trap - SIGINT SIGTERM

echo ""
echo "═══════════════════════════════════════"
# Exit with the test status
if [ $test_status -eq 0 ]; then
    echo "🎉 All tests passed!"
    exit 0
else
    echo "💥 Tests failed!"
    exit 1
fi
