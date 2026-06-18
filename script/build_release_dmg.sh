#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="MacAutopilot"
PROJECT="MacAutopilot.xcodeproj"
SCHEME="MacAutopilot"
CONFIGURATION="Release"
BUILD_ROOT="$ROOT/.build/release"
ARCHIVE_PATH="$BUILD_ROOT/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_ROOT/export"
STAGE_PATH="$BUILD_ROOT/dmg-stage"
DMG_PATH="$BUILD_ROOT/$APP_NAME.dmg"
EXPORT_OPTIONS="$BUILD_ROOT/ExportOptions.plist"
DRY_RUN=false
SKIP_NOTARIZATION=false

usage() {
  cat >&2 <<'USAGE'
usage: ./script/build_release_dmg.sh [--dry-run] [--skip-notarization]

Builds a direct-distribution Developer ID DMG for Mac Autopilot.

Dry-run mode performs credential-free release readiness checks and prints the
required real signing/notarization inputs. Real mode requires:
  APPLE_TEAM_ID                  Apple Developer Team ID
  DEVELOPER_ID_APPLICATION       Developer ID Application identity name
  NOTARYTOOL_PROFILE             xcrun notarytool keychain profile

Alternatively, real notarization can use:
  APPLE_ID
  APP_SPECIFIC_PASSWORD
  APPLE_TEAM_ID
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --skip-notarization)
      SKIP_NOTARIZATION=true
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

fail() {
  printf 'release: %s\n' "$1" >&2
  exit 1
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [ "$DRY_RUN" = false ]; then
    "$@"
  fi
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

setting_value() {
  local key="$1"
  awk -F '=' -v key="$key" '
    {
      setting = $1
      value = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", setting)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (setting == key) {
        print value
        exit
      }
    }
  '
}

require_tool xcodebuild
require_tool xcrun
require_tool hdiutil
require_tool codesign
require_tool spctl
require_tool security
require_tool plutil

BUILD_SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings)"

bundle_id="$(printf '%s\n' "$BUILD_SETTINGS" | setting_value PRODUCT_BUNDLE_IDENTIFIER)"
hardened_runtime="$(printf '%s\n' "$BUILD_SETTINGS" | setting_value ENABLE_HARDENED_RUNTIME)"
entitlements="$(printf '%s\n' "$BUILD_SETTINGS" | setting_value CODE_SIGN_ENTITLEMENTS)"
wrapper_name="$(printf '%s\n' "$BUILD_SETTINGS" | setting_value WRAPPER_NAME)"

[ "$bundle_id" = "com.langqi.MacAutopilot" ] || fail "unexpected bundle id: ${bundle_id:-missing}"
[ "$hardened_runtime" = "YES" ] || fail "Hardened Runtime must be enabled for Release"
[ -n "$entitlements" ] && [ -f "$entitlements" ] || fail "missing entitlements file: ${entitlements:-unset}"
[ "$wrapper_name" = "$APP_NAME.app" ] || fail "unexpected wrapper name: ${wrapper_name:-missing}"

if ! plutil -extract keychain-access-groups raw "$entitlements" >/dev/null 2>&1; then
  fail "Release entitlements must include the Keychain access group"
fi

printf 'release: bundle id %s\n' "$bundle_id"
printf 'release: entitlements %s\n' "$entitlements"
printf 'release: hardened runtime %s\n' "$hardened_runtime"

if [ "$DRY_RUN" = true ]; then
  cat <<EOF
release: dry run only; no archive, signing, DMG, or notarization was performed.
release: required real-mode environment:
  APPLE_TEAM_ID=<team id>
  DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
  NOTARYTOOL_PROFILE=<xcrun notarytool store-credentials profile>
release: optional alternate notarization environment:
  APPLE_ID=<apple id>
  APP_SPECIFIC_PASSWORD=<app-specific password>
EOF
  exit 0
fi

[ -n "${APPLE_TEAM_ID:-}" ] || fail "APPLE_TEAM_ID is required for real release signing"

if [ -z "${DEVELOPER_ID_APPLICATION:-}" ]; then
  DEVELOPER_ID_APPLICATION="$(
    security find-identity -p codesigning -v |
      awk -F '"' '/Developer ID Application/ { print $2; exit }'
  )"
fi
[ -n "$DEVELOPER_ID_APPLICATION" ] || fail "DEVELOPER_ID_APPLICATION is required or must be available in Keychain"

if [ "$SKIP_NOTARIZATION" = false ]; then
  if [ -z "${NOTARYTOOL_PROFILE:-}" ]; then
    [ -n "${APPLE_ID:-}" ] || fail "NOTARYTOOL_PROFILE or APPLE_ID is required for notarization"
    [ -n "${APP_SPECIFIC_PASSWORD:-}" ] || fail "NOTARYTOOL_PROFILE or APP_SPECIFIC_PASSWORD is required for notarization"
  fi
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$EXPORT_PATH" "$STAGE_PATH"

cat >"$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>$APPLE_TEAM_ID</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>stripSwiftSymbols</key>
  <true/>
</dict>
</plist>
EOF

run xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"

run xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_PATH"

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
[ -d "$APP_PATH" ] || fail "exported app not found at $APP_PATH"

run codesign --verify --deep --strict --verbose=2 "$APP_PATH"
run codesign -dvvv --entitlements :- "$APP_PATH"

cp -R "$APP_PATH" "$STAGE_PATH/"
ln -s /Applications "$STAGE_PATH/Applications"

run hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

run codesign --force --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
run codesign --verify --verbose=2 "$DMG_PATH"

if [ "$SKIP_NOTARIZATION" = false ]; then
  if [ -n "${NOTARYTOOL_PROFILE:-}" ]; then
    run xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  else
    run xcrun notarytool submit "$DMG_PATH" --apple-id "$APPLE_ID" --password "$APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
  fi
  run xcrun stapler staple "$DMG_PATH"
  run xcrun stapler validate "$DMG_PATH"
fi

run spctl -a -vv --type open "$DMG_PATH"
printf 'release: ready DMG %s\n' "$DMG_PATH"
