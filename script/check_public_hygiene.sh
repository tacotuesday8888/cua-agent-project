#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failures=0

fail() {
    printf 'public hygiene: %s\n' "$1" >&2
    failures=$((failures + 1))
}

require_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        fail "missing required public-readiness file: $path"
    fi
}

require_file README.md
require_file docs/ARCHITECTURE.md
require_file docs/VALIDATION.md
require_file docs/RELEASE.md
require_file PRIVACY.md
require_file SECURITY.md
require_file CONTRIBUTING.md
require_file LICENSE
require_file .github/pull_request_template.md
require_file .github/dependabot.yml

while IFS= read -r -d '' path; do
    [[ -e "$path" ]] || continue
    case "$path" in
        .DS_Store|*/.DS_Store)
            fail "tracked Finder metadata: $path"
            ;;
        .env|.env.*|*/.env|*/.env.*)
            if [[ "$path" != ".env.example" && "$path" != */.env.example ]]; then
                fail "tracked environment file: $path"
            fi
            ;;
        .codex/*|.claude/*|.firebase/*)
            fail "tracked local tool/deploy state: $path"
            ;;
        .build/*|*/.build/*|DerivedData/*|*/DerivedData/*|*/xcuserdata/*|*.xcuserstate|*.xcarchive|*.xcresult|*.dSYM|*.dSYM/*)
            fail "tracked build or Xcode user state: $path"
            ;;
        *.app|*.app/*|*.dmg|*.pkg|*.ipa)
            fail "tracked release artifact: $path"
            ;;
        *.notarization-log|*.notarytool-log|*.notary.json)
            fail "tracked notarization log or history artifact: $path"
            ;;
        node_modules/*|*/node_modules/*|backend/lib/*)
            fail "tracked generated dependency/build output: $path"
            ;;
        *.pem|*.key|*.p8|*.p12|*.cer|*.crt|*.mobileprovision|*.provisionprofile|*.p12.base64|*.p8.base64|*.key.base64|*.cer.base64|*.crt.base64|*.mobileprovision.base64|*.provisionprofile.base64|*.keychain-db)
            fail "tracked credential, certificate, or provisioning file: $path"
            ;;
    esac
done < <(git ls-files -z)

secret_pattern='(-----BEGIN (RSA |EC |OPENSSH |PRIVATE )?PRIVATE KEY-----|sk-proj-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{32,}|github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,})'
while IFS= read -r -d '' path; do
    [[ -f "$path" ]] || continue
    case "$path" in
        *.png|*.jpg|*.jpeg|*.gif|*.pdf|*.zip|*.ico|*.icns|*.xcassets/*|backend/package-lock.json)
            continue
            ;;
    esac
    if grep -IEq "$secret_pattern" "$path" 2>/dev/null; then
        fail "possible secret material found in tracked file: $path"
    fi
done < <(git ls-files -z)

if [[ -f MacAutopilot/GoogleService-Info.plist ]]; then
    if grep -Eq 'CLIENT_SECRET|PRIVATE_KEY|SERVICE_ACCOUNT|REFRESH_TOKEN' MacAutopilot/GoogleService-Info.plist; then
        fail "Firebase client plist contains a server-side credential marker"
    fi
fi

if (( failures > 0 )); then
    exit 1
fi

printf 'public hygiene: ok\n'
