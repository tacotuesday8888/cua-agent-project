# Release And Distribution Notes

Mac Autopilot should ship as a local-first Mac power tool with a small hosted AI
path. The first practical distribution path is a signed and notarized direct
download. A Mac App Store path needs a separate feasibility review because the
product depends on Accessibility control and optional Screen Recording.

## Direct Distribution Baseline

Required before a public build:

- Apple Developer Team configured in Xcode.
- Developer ID Application certificate available locally or in CI.
- Hardened Runtime enabled for release signing.
- App archive exported as a signed `.app` or `.dmg`.
- Notarization submitted and stapled.
- Privacy copy explaining Accessibility, Screen Recording, local memory, local
  run history, hosted usage metadata, provider API-key handling, and subscription
  OAuth credentials.

Apple reference points:

- Notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Hardened Runtime: https://developer.apple.com/documentation/security/hardened-runtime
- App Sandbox: https://developer.apple.com/documentation/security/app-sandbox
- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/

## Current Build State

- Bundle identifier: `com.langqi.MacAutopilot`.
- Entitlements include Keychain access for local provider keys and OAuth
  credentials. The app is intentionally not sandboxed while Accessibility
  control is being validated.
- Hardened Runtime is enabled in build settings, but local ad-hoc builds may
  disable it.
- The app now has an asset catalog and `AppIcon` set.
- CI builds and package tests do not run TCC-dependent smoke tests.

## Distribution Decision

Default decision for now: direct notarized distribution first.

Ship direct notarized distribution first. Mac Autopilot Basic, BYOK, and
subscription account access can ship only after the validation matrix passes and
privacy copy is reviewed. Keep remote sync, multi-app workflows, scheduling,
voice/files, and payment entitlements out of the first user-testable build unless
a separate release decision is made.
