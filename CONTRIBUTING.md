# Contributing

Mac Autopilot is public source-available code, not an open-source project unless
a future license says otherwise. Keep changes small, reviewable, and aligned
with the local-first beta boundary.

## Before Opening A PR

Run the checks that match your change:

```sh
./script/check_public_hygiene.sh
swift test --package-path AutopilotKit
xcodebuild -project MacAutopilot.xcodeproj -scheme MacAutopilot -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
cd backend && npm run typecheck && npm test && npm run build
```

Run `./script/validate_beta.sh` when touching the agent loop, Accessibility
driver, approval gates, workflow execution, validation scenarios, or release
readiness.

## Privacy And Secrets

Do not include real provider keys, OAuth tokens, `.env` files, certificates,
provisioning profiles, service-account JSON, screenshots, private app content,
Accessibility-tree dumps, or validation reports in commits, issues, or PRs.
Validation output belongs under `.build/validation` and may contain private UI
or task text.

## Beta Boundary

Keep the current beta honest: one target app at a time, one run at a time,
local-first memory/history/workflows, Keychain credentials, Hosted Basic and
BYOK provider paths, and approval-gated write/destructive actions.
