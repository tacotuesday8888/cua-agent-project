# Release And Distribution Notes

Mac Autopilot should ship local-first until hosted features are real product
requirements. The first practical path is a signed and notarized direct
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
  run history, and provider API-key handling.

Apple reference points:

- Notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Hardened Runtime: https://developer.apple.com/documentation/security/hardened-runtime
- App Sandbox: https://developer.apple.com/documentation/security/app-sandbox
- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/

## Current Build State

- Bundle identifier: `com.langqi.MacAutopilot`.
- Entitlements file exists but is empty.
- Hardened Runtime is enabled in build settings, but local ad-hoc builds may
  disable it.
- The app now has an asset catalog and `AppIcon` set.
- CI builds and package tests do not run TCC-dependent smoke tests.

## Distribution Decision

Default decision for now: direct notarized distribution first.

Do not add accounts, subscriptions, hosted LLM credits, sync, or server-side key
storage until the single-app local agent is validated with real users. If hosted
features are added later, write a backend architecture decision before changing
the agent loop to depend on a server.
