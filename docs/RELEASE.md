# Distribution Checklist

Mac Autopilot is distributed as a signed and notarized macOS app. App Store
distribution requires a separate compatibility review because the product uses
Accessibility control and optional Screen Recording.

## Direct Distribution

Before publishing a build:

- Apple Developer Team configured in Xcode.
- Developer ID Application certificate available locally or in CI.
- Hardened Runtime enabled for release signing.
- App archive exported as a signed `.app`.
- Release DMG created, signed, notarized, stapled, and Gatekeeper-checked.
- Notarization submitted and stapled.
- Privacy copy explains Accessibility, Screen Recording, local memory, local run
  history, hosted usage metadata, provider API-key handling, and subscription
  OAuth credentials.
- `PRIVACY.md`, `SECURITY.md`, and `script/check_public_hygiene.sh` are present
  and CI is green before publishing a public repo or public beta link.
- `CONTRIBUTING.md`, `.github/pull_request_template.md`, `.github/dependabot.yml`,
  and `LICENSE` are present so public repo expectations are explicit.

## DMG Release Script

CI runs a credential-free release preflight:

```sh
./script/build_release_dmg.sh --dry-run
```

The dry run verifies the real Xcode Release settings: bundle id
`com.langqi.MacAutopilot`, Hardened Runtime, wrapper name, and committed
entitlements. It does not create archives or touch Apple credentials.

For a real direct-download release, first create a notarytool profile locally:

```sh
xcrun notarytool store-credentials mac-autopilot-notary
```

Then run:

```sh
APPLE_TEAM_ID=TEAMID1234 \
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID1234)" \
NOTARYTOOL_PROFILE=mac-autopilot-notary \
./script/build_release_dmg.sh
```

The script performs:

1. `xcodebuild archive` with Developer ID signing.
2. `xcodebuild -exportArchive` using generated `method=developer-id` export
   options under `.build/release`.
3. `codesign --verify --deep --strict --verbose=2` on the exported `.app`.
4. `codesign -dvvv --entitlements :-` on the exported `.app`.
5. `hdiutil create` for `MacAutopilot.dmg`.
6. `codesign` on the DMG.
7. `xcrun notarytool submit --wait`.
8. `xcrun stapler staple` and `xcrun stapler validate`.
9. `spctl -a -vv --type open` on the final DMG.

If a Developer ID identity is present in Keychain, `DEVELOPER_ID_APPLICATION`
can be omitted and the script will use the first `Developer ID Application`
identity it finds. Notarization can also use `APPLE_ID`,
`APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID` instead of a keychain profile, but
the keychain profile is the preferred local flow.

## GitHub Release Workflow

After Apple Developer ID credentials exist, the manual **Release DMG** workflow
can build the direct-download artifact in GitHub Actions. The workflow imports a
Developer ID Application `.p12` into a temporary keychain, runs
`script/build_release_dmg.sh`, notarizes and staples the DMG, writes a SHA-256
checksum, uploads both files as a workflow artifact, optionally creates a draft
GitHub Release with both files, then deletes the temporary keychain.

The workflow is manual-only. The signing/notarization job uses read-only
repository permission and disables persisted checkout credentials. The optional
draft-release job runs separately without Apple signing secrets and grants its
`GITHUB_TOKEN` `contents: write` because GitHub Releases require
repository-content write permission.

Leave **Create GitHub Release** off for a one-off artifact-only validation run.
Turn it on with a tag such as `v0.1.0-beta.1` when you want a durable draft
release download page. In a public repository, workflow artifacts are still
downloadable from the Actions run by signed-in users who can read the
repository, and enabling the release option may create the tag before the draft
is published. Run this workflow only after the DMG is intended to be externally
shareable. Draft releases must still be reviewed and published manually.

Configure these repository secrets before running it:

- `MACOS_DEVELOPER_ID_CERTIFICATE_P12_BASE64` — base64 text for the exported
  Developer ID Application `.p12`.
- `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD` — password used when exporting the
  `.p12`.
- `APPLE_TEAM_ID` — Apple Developer Team ID.
- `APPLE_ID` — Apple ID for notarization.
- `APP_SPECIFIC_PASSWORD` — Apple app-specific password for `notarytool`.
- `DEVELOPER_ID_APPLICATION` — optional exact signing identity name. Leave unset
  only if the temporary keychain contains one Developer ID Application identity.

The draft-release job explicitly requests `contents: write` for its
`GITHUB_TOKEN`. If GitHub still gives the job a read-only token because of an
organization or repository policy, the signed DMG can be produced but the final
GitHub Release creation step will fail.

Create the certificate secret from a local `.p12` without committing the file:

```sh
base64 -i DeveloperIDApplication.p12 | tr -d '\n' | pbcopy
```

Then paste the clipboard into the GitHub secret. Files matching certificate,
provisioning, keychain, and base64 credential patterns are ignored by
`.gitignore` and rejected by `script/check_public_hygiene.sh`.

When **Create GitHub Release** is enabled, the workflow uses `gh release create`
to create a **draft** release at the workflow commit, upload `MacAutopilot.dmg`
and `MacAutopilot.dmg.sha256`, and mark it as a prerelease by default. It fails
before signing if the tag input is missing or if an existing tag points at a
different commit. The generated checksum file references the downloaded DMG
filename, so the draft release notes include this verification command:

```sh
shasum -a 256 -c MacAutopilot.dmg.sha256
```

Before publishing a draft GitHub Release:

- Verify the downloaded DMG against `MacAutopilot.dmg.sha256`.
- Re-run the release candidate validation checklist in
  [`docs/VALIDATION.md`](VALIDATION.md).
- Confirm the published privacy and security copy still matches the build.
- Confirm hosted Basic is pointed at the intended Firebase/Vertex project and
  quota policy.
- Confirm the website/download page is ready to link to the release.
- Replace the generated draft notes with user-facing release notes and known
  limitations.

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
- `script/build_release_dmg.sh --dry-run` validates the Release build settings
  without requiring Developer ID credentials.
- The app now has an asset catalog and `AppIcon` set.
- CI builds and package tests do not run TCC-dependent smoke tests.

## Validation

Release candidates should pass the validation checklist in
[`docs/VALIDATION.md`](VALIDATION.md), including package tests, app build,
deterministic fixture validation, and any explicitly enabled live-provider
smoke tests.
