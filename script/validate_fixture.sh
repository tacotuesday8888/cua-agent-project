#!/usr/bin/env bash
set -euo pipefail

INCLUDE_SCREENSHOT=false
for arg in "$@"; do
  case "$arg" in
    --include-screenshot)
      INCLUDE_SCREENSHOT=true
      ;;
    *)
      echo "usage: $0 [--include-screenshot]" >&2
      exit 2
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_PATH="$ROOT_DIR/AutopilotKit"
LOG_DIR="$ROOT_DIR/.build"
FIXTURE_LOG="$LOG_DIR/autopilot-fixture.log"

mkdir -p "$LOG_DIR"

print_fixture_log() {
  if [ -s "$FIXTURE_LOG" ]; then
    echo "" >&2
    echo "---- AutopilotFixtureApp log ----" >&2
    tail -200 "$FIXTURE_LOG" >&2 || true
    echo "---------------------------------" >&2
  fi
}

swift run --package-path "$PACKAGE_PATH" AutopilotFixtureApp >"$FIXTURE_LOG" 2>&1 &
FIXTURE_PID=$!

cleanup() {
  if kill -0 "$FIXTURE_PID" >/dev/null 2>&1; then
    kill "$FIXTURE_PID" >/dev/null 2>&1 || true
    wait "$FIXTURE_PID" >/dev/null 2>&1 || true
  fi
}

on_error() {
  local status=$?
  echo "Fixture validation failed with exit status $status." >&2
  print_fixture_log
  exit "$status"
}

trap cleanup EXIT
trap on_error ERR

sleep 2
if ! kill -0 "$FIXTURE_PID" >/dev/null 2>&1; then
  echo "AutopilotFixtureApp exited before validation could start." >&2
  print_fixture_log
  exit 1
fi

swift run --package-path "$PACKAGE_PATH" AutopilotSmokeCLI --app AutopilotFixtureApp
swift run --package-path "$PACKAGE_PATH" AutopilotSmokeCLI --app AutopilotFixtureApp --agent-loop

if [ "$INCLUDE_SCREENSHOT" = true ]; then
  swift run --package-path "$PACKAGE_PATH" AutopilotSmokeCLI --app AutopilotFixtureApp --include-screenshot
fi
