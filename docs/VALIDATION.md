# Mac Autopilot Validation Matrix

This matrix separates checks that can run anywhere from checks that require
local macOS privacy grants. Record failures with the app, command, exact task,
and final agent summary.

## Automated Baseline

Run before every implementation batch:

```sh
swift test --package-path AutopilotKit
xcodebuild -project MacAutopilot.xcodeproj -scheme MacAutopilot -destination 'platform=macOS' -derivedDataPath .build/xcode build
```

Expected result: package tests pass and the app target builds.

For local app launch verification, use the project run entrypoint:

```sh
./script/build_and_run.sh --verify
```

Expected result: the app builds into `.build/xcode`, launches as
`MacAutopilot`, and the process is visible to `pgrep`.

## Fixture Driver Validation

Requires Accessibility permission for the fixture app and the smoke CLI process.

Terminal 1:

```sh
swift run --package-path AutopilotKit AutopilotFixtureApp
```

Terminal 2:

```sh
swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp
swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp --agent-loop
swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp --include-screenshot
```

Expected result: the nine-tool smoke surface passes. Each driver step is
reported independently — a failure no longer aborts the run, so one run shows
the full pass/fail matrix, and a failed step also names the targeted element
(id, role, label). The screenshot run also requires Screen Recording permission
and should report PNG bytes. Screenshots are target-window-only; if the fixture
window cannot be matched to a CoreGraphics window, the smoke run should fail with
a screenshot warning rather than capturing the full display.

The same fixture checks can be run with:

```sh
./script/validate_fixture.sh
./script/validate_fixture.sh --include-screenshot
```

## Live Provider Validation

Requires a saved Keychain key from the app or a process-local environment key.
Do not commit keys or write them into docs.

```sh
ZAI_API_KEY=... swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp --live-provider zai
ANTHROPIC_API_KEY=... swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp --live-provider anthropic
```

Expected result: the fixture input ends with `live smoke value`, the agent calls
`done`, and the smoke CLI reports success. Z.AI is configured as text-only, so
screenshot requests must be omitted or explicitly warned about.

To run deterministic fixture checks and one live fixture smoke in a single
launch/cleanup cycle:

```sh
./script/validate_fixture.sh --live-provider zai
./script/validate_fixture.sh --live-provider anthropic --api-key-env ANTHROPIC_API_KEY
```

The live option is deliberately opt-in because it uses the selected provider's
real API. It reads the API key from the provider's environment variable first,
then falls back to the saved MacAutopilot Keychain entry.

## Validate Recent Driver And Engine Changes

These behaviors shipped on the current branch and need real-app confirmation
beyond the deterministic fixture run. Record results with the capture fields in
the Safe Real-App Matrix below.

- **Click fallback for non-AX-press controls.** Icon-only, Electron, and web
  controls often advertise no working AX press, so `MacComputer.click` falls back
  to a synthesized click at the element's center. Validate against such a control
  (an Electron app like VS Code or Slack, a web button reached through the AX
  tree, or an icon-only toolbar button): use `--dump-tree` to find it, run a
  non-destructive task that clicks it, and confirm the control actually
  activates. Watch for a coordinate-space mismatch on Retina or multi-display
  setups — if the click lands off-target, the element frame needs converting
  before the synthesized click.
- **Prompt-cache token accounting (Anthropic).** Run a multi-step task with the
  Anthropic provider (prompt caching is on) and confirm the reported input
  tokens — in the UI and the saved run history — include cache creation and read
  tokens, not just the uncached remainder.
- **Secondary-action gating.** Confirm a `perform_secondary_action` whose action
  name is destructive (for example a context-menu Delete) is surfaced for
  approval instead of running as a trusted write.

## Safe Real-App Matrix

Use non-destructive tasks only. Do not test send, delete, purchase, sign-out, or
external submission flows until destructive approval behavior is under review.

| App | Command | Safe task | Expected result |
| --- | --- | --- | --- |
| TextEdit | `--dump-tree` | Type a short note into an untitled document | Text appears and no destructive approval fires |
| Notes | `--dump-tree` | Read visible note titles or type into a test note | Agent identifies current controls from AX tree |
| Safari or Chrome | `--dump-tree` | Read page title or type into a local/search field | Agent handles web accessibility labels or asks user |
| Finder | `--dump-tree` | Read visible file names in a test folder | No file mutation occurs |
| Calendar or Mail | `--dump-tree` | Read visible labels only | Agent avoids send/delete workflows |

For each app, capture:

- macOS version and app version
- target window state: focused, minimized, hidden, multi-window
- tree element count
- task text
- tools performed
- failure summary and recovery text

## Permission Checks

Apple documents Accessibility trust through
`AXIsProcessTrustedWithOptions` and Screen Recording through
`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`. Verify:

- Missing Accessibility blocks runs before the first LLM call.
- Missing Screen Recording is a warning unless screenshots are requested.
- Re-checking permissions after returning from System Settings updates the UI.

## Release Gate

A release candidate must pass:

- automated baseline
- fixture driver validation
- one live smoke for each enabled provider
- at least three safe real-app tasks
- manual approval test for one write action and one destructive action
