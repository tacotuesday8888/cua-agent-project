#!/usr/bin/env bash
set -euo pipefail

INCLUDE_SCREENSHOT=false
LIVE_PROVIDER=""
LIVE_ARGS=()
LIVE_ARGS_COUNT=0

usage() {
  cat >&2 <<'USAGE'
usage: ./script/validate_fixture.sh [--include-screenshot] [--live-provider openai|anthropic] [--api-key-env NAME] [--model MODEL] [--max-steps N]

Runs the deterministic fixture smoke paths. --live-provider also runs one
fixture AgentSession against the selected provider, using the provider's
environment key or saved MacAutopilot Keychain entry.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --include-screenshot)
      INCLUDE_SCREENSHOT=true
      ;;
    --live-provider)
      shift
      if [ "$#" -eq 0 ]; then
        usage
        exit 2
      fi
      LIVE_PROVIDER="$1"
      ;;
    --api-key-env|--model|--max-steps)
      flag="$1"
      shift
      if [ "$#" -eq 0 ]; then
        usage
        exit 2
      fi
      LIVE_ARGS+=("$flag" "$1")
      LIVE_ARGS_COUNT=$((LIVE_ARGS_COUNT + 2))
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

case "$LIVE_PROVIDER" in
  ""|openai|anthropic)
    ;;
  *)
    usage
    exit 2
    ;;
esac

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

if [ -n "$LIVE_PROVIDER" ]; then
  if [ "$LIVE_ARGS_COUNT" -gt 0 ]; then
    swift run --package-path "$PACKAGE_PATH" AutopilotSmokeCLI \
      --app AutopilotFixtureApp \
      --live-provider "$LIVE_PROVIDER" \
      "${LIVE_ARGS[@]}"
  else
    swift run --package-path "$PACKAGE_PATH" AutopilotSmokeCLI \
      --app AutopilotFixtureApp \
      --live-provider "$LIVE_PROVIDER"
  fi
fi
