# Distribution Checklist

Mac Autopilot is distributed as a signed and notarized macOS app. App Store
distribution requires a separate compatibility review because the product uses
Accessibility control and optional Screen Recording.

## Direct Distribution

Before publishing a build:

- Apple Developer Team configured in Xcode.
- Developer ID Application certificate available locally or in CI.
- Hardened Runtime enabled for release signing.
- App archive exported as a signed `.app` or `.dmg`.
- Notarization submitted and stapled.
- Privacy copy explains Accessibility, Screen Recording, local memory, local run
  history, hosted usage metadata, provider API-key handling, and subscription
  OAuth credentials.
- `PRIVACY.md`, `SECURITY.md`, and `script/check_public_hygiene.sh` are present
  and CI is green before publishing a public repo or public beta link.
- `CONTRIBUTING.md`, `.github/pull_request_template.md`, `.github/dependabot.yml`,
  and `LICENSE` are present so public repo expectations are explicit.

Apple reference points:

- Notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Hardened Runtime: https://developer.apple.com/documentation/security/hardened-runtime
- App Sandbox: https://developer.apple.com/documentation/security/app-sandbox
- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/

## Build State

- Bundle identifier: `com.langqi.MacAutopilot`.
- Entitlements include Keychain access for local provider keys and OAuth
  credentials.
- Hardened Runtime is enabled in build settings, but local ad-hoc builds may
  disable it.
- The app now has an asset catalog and `AppIcon` set.
- CI builds and package tests do not run TCC-dependent smoke tests.

## Validation

Release candidates should pass the validation checklist in
[`docs/VALIDATION.md`](VALIDATION.md), including package tests, app build,
deterministic fixture validation, and any explicitly enabled live-provider
smoke tests.
