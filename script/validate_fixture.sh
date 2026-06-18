#!/usr/bin/env bash
set -euo pipefail

INCLUDE_SCREENSHOT=false
LIVE_PROVIDER=""
LIVE_ARGS=()
LIVE_ARGS_COUNT=0
STEP_TIMEOUT_SECONDS="${AUTOPILOT_FIXTURE_STEP_TIMEOUT_SECONDS:-240}"
FIXTURE_LAUNCH_ATTEMPTS="${AUTOPILOT_FIXTURE_LAUNCH_ATTEMPTS:-3}"

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
    --help|-h)
      usage
      exit 0
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

case "$FIXTURE_LAUNCH_ATTEMPTS" in
  ""|*[!0-9]*|0)
    echo "AUTOPILOT_FIXTURE_LAUNCH_ATTEMPTS must be a positive integer." >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_PATH="$ROOT_DIR/AutopilotKit"
LOG_DIR="$ROOT_DIR/.build/validation/fixture"
FIXTURE_LOG="$LOG_DIR/autopilot-fixture.log"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
SWIFT_CACHE_PATH="$ROOT_DIR/.build/swiftpm-cache"
SWIFT_CONFIG_PATH="$ROOT_DIR/.build/swiftpm-config"
SWIFT_SECURITY_PATH="$ROOT_DIR/.build/swiftpm-security"
SWIFT_SCRATCH_PATH="$PACKAGE_PATH/.build/fixture-validation"
SWIFT_BIN_DIR="$SWIFT_SCRATCH_PATH/debug"
FIXTURE_BINARY="$SWIFT_BIN_DIR/AutopilotFixtureApp"
SMOKE_BINARY="$SWIFT_BIN_DIR/AutopilotSmokeCLI"
SWIFT_PACKAGE_ARGS=(
  --package-path "$PACKAGE_PATH"
  --cache-path "$SWIFT_CACHE_PATH"
  --config-path "$SWIFT_CONFIG_PATH"
  --security-path "$SWIFT_SECURITY_PATH"
  --scratch-path "$SWIFT_SCRATCH_PATH"
  --manifest-cache local
  --disable-sandbox
)

mkdir -p "$LOG_DIR" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_CACHE_PATH" "$SWIFT_CONFIG_PATH" "$SWIFT_SECURITY_PATH" "$SWIFT_SCRATCH_PATH"

print_fixture_log() {
  if [ -s "$FIXTURE_LOG" ]; then
    echo "" >&2
    echo "---- AutopilotFixtureApp log ----" >&2
    tail -200 "$FIXTURE_LOG" >&2 || true
    echo "---------------------------------" >&2
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  "$@" &
  local pid=$!
  (
    sleep "$seconds"
    if kill -0 "$pid" >/dev/null 2>&1; then
      echo "Command timed out after ${seconds}s: $*" >&2
      kill "$pid" >/dev/null 2>&1 || true
      sleep 2
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
  ) &
  local watchdog=$!
  local status=0
  wait "$pid" || status=$?
  kill "$watchdog" >/dev/null 2>&1 || true
  wait "$watchdog" >/dev/null 2>&1 || true
  return "$status"
}

run_step() {
  local name="$1"
  shift
  echo "== $name =="
  run_with_timeout "$STEP_TIMEOUT_SECONDS" "$@"
  echo "PASS $name"
}

wait_for_fixture_app() {
  local attempts=10
  local log="$LOG_DIR/fixture-readiness.log"

  for _ in $(seq 1 "$attempts"); do
    if ! kill -0 "$FIXTURE_PID" >/dev/null 2>&1; then
      return 2
    fi
    if "$SMOKE_BINARY" --app AutopilotFixtureApp --check-app-visible >"$log" 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

stop_existing_fixture_apps() {
  pkill -x AutopilotFixtureApp >/dev/null 2>&1 || true
  sleep 1
}

FIXTURE_PID=""
LAST_FIXTURE_READINESS_STATUS=0
cleanup() {
  if [ -n "$FIXTURE_PID" ] && kill -0 "$FIXTURE_PID" >/dev/null 2>&1; then
    kill "$FIXTURE_PID" >/dev/null 2>&1 || true
    wait "$FIXTURE_PID" >/dev/null 2>&1 || true
  fi
  stop_existing_fixture_apps
}

stop_fixture_process() {
  if [ -n "$FIXTURE_PID" ] && kill -0 "$FIXTURE_PID" >/dev/null 2>&1; then
    kill "$FIXTURE_PID" >/dev/null 2>&1 || true
    wait "$FIXTURE_PID" >/dev/null 2>&1 || true
  fi
  FIXTURE_PID=""
}

launch_fixture_app() {
  local attempt

  : >"$FIXTURE_LOG"
  for attempt in $(seq 1 "$FIXTURE_LAUNCH_ATTEMPTS"); do
    echo "Launching AutopilotFixtureApp (attempt $attempt/$FIXTURE_LAUNCH_ATTEMPTS)..."
    {
      echo "== launch attempt $attempt/$FIXTURE_LAUNCH_ATTEMPTS =="
      date
    } >>"$FIXTURE_LOG"

    "$FIXTURE_BINARY" >>"$FIXTURE_LOG" 2>&1 &
    FIXTURE_PID=$!

    if wait_for_fixture_app; then
      echo "PASS fixture-app"
      return 0
    fi

    LAST_FIXTURE_READINESS_STATUS=$?
    stop_fixture_process
    stop_existing_fixture_apps

    if [ "$attempt" -lt "$FIXTURE_LAUNCH_ATTEMPTS" ]; then
      if [ "$LAST_FIXTURE_READINESS_STATUS" -eq 2 ]; then
        echo "AutopilotFixtureApp exited before readiness; retrying launch." >&2
      else
        echo "AutopilotFixtureApp was not visible before readiness timeout; retrying launch." >&2
      fi
      sleep 1
    fi
  done

  return "$LAST_FIXTURE_READINESS_STATUS"
}

on_error() {
  local status=$?
  echo "Fixture validation failed with exit status $status." >&2
  print_fixture_log
  exit "$status"
}

trap cleanup EXIT
trap on_error ERR

run_step build-fixture-app swift build "${SWIFT_PACKAGE_ARGS[@]}" --product AutopilotFixtureApp
run_step build-smoke-cli swift build "${SWIFT_PACKAGE_ARGS[@]}" --product AutopilotSmokeCLI

stop_existing_fixture_apps

if launch_fixture_app; then
  :
else
  if [ "$LAST_FIXTURE_READINESS_STATUS" -eq 2 ]; then
    echo "AutopilotFixtureApp exited before validation could start." >&2
  else
    echo "AutopilotFixtureApp did not become visible to the smoke runner." >&2
    echo "Readiness details were kept in: $LOG_DIR/fixture-readiness.log" >&2
  fi
  print_fixture_log
  exit 1
fi

run_step fixture-driver-smoke "$SMOKE_BINARY" --app AutopilotFixtureApp
run_step fixture-agent-loop "$SMOKE_BINARY" --app AutopilotFixtureApp --agent-loop

if [ "$INCLUDE_SCREENSHOT" = true ]; then
  run_step fixture-screenshot-smoke "$SMOKE_BINARY" --app AutopilotFixtureApp --include-screenshot
fi

if [ -n "$LIVE_PROVIDER" ]; then
  if [ "$LIVE_ARGS_COUNT" -gt 0 ]; then
    run_step "live-provider-$LIVE_PROVIDER" \
      "$SMOKE_BINARY" \
        --app AutopilotFixtureApp \
        --live-provider "$LIVE_PROVIDER" \
        "${LIVE_ARGS[@]}"
  else
    run_step "live-provider-$LIVE_PROVIDER" \
      "$SMOKE_BINARY" \
        --app AutopilotFixtureApp \
        --live-provider "$LIVE_PROVIDER"
  fi
fi
