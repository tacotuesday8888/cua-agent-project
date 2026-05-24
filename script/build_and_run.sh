#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MacAutopilot"
BUNDLE_ID="com.langqi.MacAutopilot"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/MacAutopilot.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/xcode"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# Optional: a stable Apple Development team so TCC grants survive rebuilds.
# Unset (the default) keeps the ad-hoc build CI and teamless machines rely on.
DEV_TEAM="${AUTOPILOT_DEV_TEAM:-}"

usage() {
  cat >&2 <<USAGE
usage: $0 [run|--launch-only|--debug|--logs|--telemetry|--verify]

  run            build, then launch the app (default)
  --launch-only  launch the already-built app WITHOUT rebuilding, so a granted
                 ad-hoc build keeps its Accessibility / Screen Recording grant
  --debug        build, then attach lldb
  --logs         build, launch, stream process logs
  --telemetry    build, launch, stream subsystem telemetry
  --verify       build, launch, confirm the process is running

Set AUTOPILOT_DEV_TEAM=<TeamID> to sign with a stable Apple Development identity
so grants survive rebuilds (default: ad-hoc, as used by CI).
USAGE
}

build_app() {
  local signing_args=()
  if [ -n "$DEV_TEAM" ]; then
    signing_args=(
      "DEVELOPMENT_TEAM=$DEV_TEAM"
      "CODE_SIGN_STYLE=Automatic"
      -allowProvisioningUpdates
    )
  fi
  # ${arr[@]+"${arr[@]}"} expands to nothing when empty without tripping `set -u`
  # on bash 3.2 (the macOS system bash).
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$APP_NAME" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ${signing_args[@]+"${signing_args[@]}"} \
    build
}

require_bundle() {
  if [ ! -d "$APP_BUNDLE" ]; then
    echo "No built app found. Run ./script/build_and_run.sh once, grant permissions, then use --launch-only." >&2
    exit 1
  fi
}

stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

grant_hint() {
  if [ -z "$DEV_TEAM" ]; then
    cat >&2 <<'HINT'
note: macOS ties Accessibility / Screen Recording grants to the app's code
      identity. This ad-hoc build's identity changes when it is rebuilt, which
      drops the grant. After granting once, relaunch WITHOUT rebuilding:
        ./script/build_and_run.sh --launch-only
      (Set AUTOPILOT_DEV_TEAM=<TeamID> to make grants survive rebuilds.)
HINT
  fi
}

# Validate the mode before doing any work, so an unknown mode never builds.
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--launch-only|launch-only|launch) ;;
  *)
    usage
    exit 2
    ;;
esac

# Launch-only never rebuilds, so a granted ad-hoc build keeps its identity.
case "$MODE" in
  --launch-only|launch-only|launch)
    require_bundle
    stop_app
    open_app
    exit 0
    ;;
esac

# Building modes.
stop_app
build_app
grant_hint

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
esac
