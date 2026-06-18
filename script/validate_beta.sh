#!/usr/bin/env bash
set -euo pipefail

INCLUDE_SCREENSHOT=false
SKIP_SWIFT_TESTS=false
LIVE_PROVIDER=""
LIVE_ARGS=()
LIVE_ARGS_COUNT=0
FIXTURE_LAUNCH_ATTEMPTS="${AUTOPILOT_FIXTURE_LAUNCH_ATTEMPTS:-3}"

usage() {
  cat >&2 <<'USAGE'
usage: ./script/validate_beta.sh [--include-screenshot] [--skip-swift-tests] [--live-provider openai|anthropic] [--api-key-env NAME] [--model MODEL] [--max-steps N]

Runs the local beta validation pack:
  - Swift package tests, unless --skip-swift-tests is set
  - deterministic fixture driver validation
  - committed JSON validation scenarios with reports
  - optional live provider fixture smoke when --live-provider is set

Reports are written under .build/validation/beta-<timestamp>.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --include-screenshot)
      INCLUDE_SCREENSHOT=true
      ;;
    --skip-swift-tests)
      SKIP_SWIFT_TESTS=true
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
SCENARIO_DIR="$ROOT_DIR/docs/validation/scenarios"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="${AUTOPILOT_VALIDATION_DIR:-$ROOT_DIR/.build/validation/beta-$STAMP}"
case "$REPORT_DIR" in
  /*)
    ;;
  *)
    REPORT_DIR="$ROOT_DIR/$REPORT_DIR"
    ;;
esac
case "$REPORT_DIR/" in
  "$ROOT_DIR/.build/"*)
    ;;
  "$ROOT_DIR/"*)
    echo "AUTOPILOT_VALIDATION_DIR inside the repo must be under .build so private validation reports stay untracked." >&2
    echo "Use a path outside the repo, or leave AUTOPILOT_VALIDATION_DIR unset." >&2
    exit 2
    ;;
esac
SUMMARY="$REPORT_DIR/summary.txt"
FIXTURE_LOG="$REPORT_DIR/autopilot-fixture.log"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
SWIFT_CACHE_PATH="$ROOT_DIR/.build/swiftpm-cache"
SWIFT_CONFIG_PATH="$ROOT_DIR/.build/swiftpm-config"
SWIFT_SECURITY_PATH="$ROOT_DIR/.build/swiftpm-security"
SWIFT_SCRATCH_PATH="$PACKAGE_PATH/.build"
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

mkdir -p "$REPORT_DIR"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
mkdir -p "$SWIFT_CACHE_PATH" "$SWIFT_CONFIG_PATH" "$SWIFT_SECURITY_PATH" "$SWIFT_SCRATCH_PATH"
: >"$SUMMARY"

log_summary() {
  echo "$*" | tee -a "$SUMMARY"
}

run_step() {
  local name="$1"
  shift
  local log="$REPORT_DIR/$name.log"

  log_summary "== $name =="
  if "$@" >"$log" 2>&1; then
    log_summary "PASS $name"
  else
    local status=$?
    log_summary "FAIL $name (exit $status)"
    echo "Step '$name' failed with exit $status." >&2
    echo "Private validation details were kept in: $log" >&2
    echo "Set AUTOPILOT_VALIDATION_PRINT_FAILURE_LOGS=1 to echo the last 120 log lines locally." >&2
    if [ "${AUTOPILOT_VALIDATION_PRINT_FAILURE_LOGS:-0}" = "1" ]; then
      echo "" >&2
      echo "---- $name log ----" >&2
      tail -120 "$log" >&2 || true
      echo "-------------------" >&2
    fi
    exit "$status"
  fi
}

wait_for_fixture_app() {
  local log="$REPORT_DIR/fixture-readiness.log"
  local attempts=10

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
    log_summary "fixture-app launch attempt $attempt/$FIXTURE_LAUNCH_ATTEMPTS"
    {
      echo "== launch attempt $attempt/$FIXTURE_LAUNCH_ATTEMPTS =="
      date
    } >>"$FIXTURE_LOG"

    "$FIXTURE_BINARY" >>"$FIXTURE_LOG" 2>&1 &
    FIXTURE_PID=$!

    if wait_for_fixture_app; then
      log_summary "PASS fixture-app"
      return 0
    fi

    LAST_FIXTURE_READINESS_STATUS=$?
    stop_fixture_process
    stop_existing_fixture_apps

    if [ "$attempt" -lt "$FIXTURE_LAUNCH_ATTEMPTS" ]; then
      if [ "$LAST_FIXTURE_READINESS_STATUS" -eq 2 ]; then
        log_summary "fixture-app exited before readiness; retrying launch"
      else
        log_summary "fixture-app was not visible before readiness timeout; retrying launch"
      fi
      sleep 1
    fi
  done

  return "$LAST_FIXTURE_READINESS_STATUS"
}
trap cleanup EXIT

if [ "$SKIP_SWIFT_TESTS" = false ]; then
  run_step swift-package-tests swift test "${SWIFT_PACKAGE_ARGS[@]}"
fi

run_step build-fixture-app swift build "${SWIFT_PACKAGE_ARGS[@]}" --product AutopilotFixtureApp
run_step build-smoke-cli swift build "${SWIFT_PACKAGE_ARGS[@]}" --product AutopilotSmokeCLI

stop_existing_fixture_apps

log_summary "== fixture-app =="
if launch_fixture_app; then
  :
else
  log_summary "FAIL fixture-app"
  if [ "$LAST_FIXTURE_READINESS_STATUS" -eq 2 ]; then
    echo "AutopilotFixtureApp exited before validation could start." >&2
  else
    echo "AutopilotFixtureApp did not become visible to the smoke runner." >&2
    echo "Private readiness details were kept in: $REPORT_DIR/fixture-readiness.log" >&2
  fi
  echo "Private fixture details were kept in: $FIXTURE_LOG" >&2
  if [ "${AUTOPILOT_VALIDATION_PRINT_FAILURE_LOGS:-0}" = "1" ]; then
    echo "" >&2
    echo "---- fixture app log ----" >&2
    tail -120 "$FIXTURE_LOG" >&2 || true
    echo "-------------------------" >&2
  fi
  exit 1
fi

run_step fixture-driver-smoke \
  "$SMOKE_BINARY" --app AutopilotFixtureApp

run_step fixture-agent-loop \
  "$SMOKE_BINARY" --app AutopilotFixtureApp --agent-loop

if [ "$INCLUDE_SCREENSHOT" = true ]; then
  run_step fixture-screenshot-smoke \
    "$SMOKE_BINARY" --app AutopilotFixtureApp --include-screenshot
fi

for scenario in "$SCENARIO_DIR"/*.json; do
  [ -e "$scenario" ] || continue
  scenario_id="$(basename "$scenario" .json)"
  run_step "scenario-$scenario_id" \
    "$SMOKE_BINARY" \
      --scenario "$scenario" \
      --record-trajectory "$REPORT_DIR/trajectories/$scenario_id" \
      --report-json "$REPORT_DIR/$scenario_id-report.json"
done

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

log_summary ""
log_summary "Beta validation reports: $REPORT_DIR"
