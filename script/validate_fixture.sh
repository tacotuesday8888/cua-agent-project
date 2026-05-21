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

swift run --package-path "$PACKAGE_PATH" AutopilotFixtureApp >"$FIXTURE_LOG" 2>&1 &
FIXTURE_PID=$!

cleanup() {
  kill "$FIXTURE_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 2

swift run --package-path "$PACKAGE_PATH" AutopilotSmokeCLI --app AutopilotFixtureApp
swift run --package-path "$PACKAGE_PATH" AutopilotSmokeCLI --app AutopilotFixtureApp --agent-loop

if [ "$INCLUDE_SCREENSHOT" = true ]; then
  swift run --package-path "$PACKAGE_PATH" AutopilotSmokeCLI --app AutopilotFixtureApp --include-screenshot
fi
