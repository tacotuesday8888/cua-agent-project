# Mac Autopilot Validation Matrix

This matrix separates checks that can run anywhere from checks that require
local macOS privacy grants. Record failures with the app, command, exact task,
and final agent summary.

## Automated Baseline

Run before every implementation batch:

```sh
swift test --package-path AutopilotKit
xcodebuild -project MacAutopilot.xcodeproj -scheme MacAutopilot -destination 'platform=macOS' -derivedDataPath .build/xcode build
cd backend && npm run typecheck && npm test && npm run build
```

Expected result: package tests pass, the app target builds, and backend
TypeScript/tests/build pass. Local Xcode builds may require a valid Apple
Developer provisioning profile; for compile-only validation on a machine without
that profile, run the same Xcode command with `CODE_SIGNING_ALLOWED=NO`.

For local app launch verification, use the project run entrypoint:

```sh
./script/build_and_run.sh --verify
```

Expected result: the app builds into `.build/xcode`, launches as
`MacAutopilot`, and the process is visible to `pgrep`.

## Beta Validation Pack

For beta readiness, use the committed validation entrypoint:

```sh
./script/validate_beta.sh
```

It runs Swift package tests, deterministic fixture driver validation, the
scripted fixture agent loop, and every JSON scenario committed under
`docs/validation/scenarios`. Reports, logs, JSON summaries, and trajectories are
written to `.build/validation/beta-<timestamp>` by default; set
`AUTOPILOT_VALIDATION_DIR=/path/to/report-dir` to choose a specific output
directory. Custom directories inside the repo are rejected unless they live
under `.build`, because these outputs may contain private UI or task text and
must not be committed.

Useful options:

- `--skip-swift-tests` when the package tests already passed in the same build.
- `--include-screenshot` to add the target-window screenshot smoke. Run this
  serially because ScreenCaptureKit can hang when separate screenshot processes
  overlap.
- `--live-provider openai|anthropic` to add one real API-backed fixture smoke;
  use `--api-key-env NAME`, `--model MODEL`, or `--max-steps N` when needed.

Expected result: the script prints a PASS line for each step and ends with the
report directory path. A failure prints the failing log path; set
`AUTOPILOT_VALIDATION_PRINT_FAILURE_LOGS=1` only when you want to echo local
private validation details in your terminal.

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

Run `--include-screenshot` smokes **serially**. Two concurrent screenshot
processes can trip a ScreenCaptureKit checked-continuation misuse and hang; this
is a framework-level limit across separate processes (the driver wraps no manual
continuation of its own), not a driver bug. Serial runs pass.

The run also includes two snapshot-only perception checks that prove the
accessibility reader captures control state the agent depends on:

- `verify_checkbox_value` — the fixture checkbox reports a numeric `AXValue`;
  this passes only if that value is captured (e.g. `"1"`), confirming numeric
  values are not dropped by a string-only cast.
- `verify_icon_button_label` — the fixture's icon-only button has an empty
  `AXTitle` and its name in `AXDescription`; this passes only if the label
  resolves, confirming the empty-title → description fallback works.

If either fails on a real Mac, capture the `--dump-tree` output for the
`autopilot.fixture.checkbox` / `autopilot.fixture.icon-button` elements — that
shows exactly what the reader extracted.

The same fixture checks can be run with:

```sh
./script/validate_fixture.sh
./script/validate_fixture.sh --include-screenshot
```

## Trajectory And Scenario Validation

For real-world reliability work, run agent loops with opt-in trajectory output.
Trajectory files are developer diagnostics and may contain private UI/task text;
do not commit them.

```sh
swift run --package-path AutopilotKit AutopilotSmokeCLI \
  --app AutopilotFixtureApp \
  --agent-loop \
  --record-trajectory .build/trajectories/fixture-agent-loop
```

Scenario JSON can make manual real-app checks repeatable:

```json
{
  "id": "textedit-note",
  "app": "TextEdit",
  "task": "Type hello into the current document, then finish.",
  "provider": "openai",
  "maxSteps": 12,
  "includeScreenshot": false,
  "expect": {
    "finalStatus": "completed",
    "stateContainsText": "hello",
    "toolUsed": "type_text",
    "noActionFailures": true
  }
}
```

Run it with:

```sh
swift run --package-path AutopilotKit AutopilotSmokeCLI \
  --scenario docs/validation/scenarios/fixture-scripted-agent-loop.json \
  --record-trajectory \
  --report-json .build/validation/fixture-scripted-agent-loop-report.json
```

The CLI writes `trace.jsonl` plus screenshot artifacts when screenshots are
requested. The JSON report contains pass/fail checks for the scenario's expected
status, visible text, tool usage, action failures, and window title.
Committed scenarios live under `docs/validation/scenarios/` and are decoded by
the Swift package test suite so invalid fixture shapes fail early.

For a one-command local beta pack, run:

```sh
./script/validate_beta.sh
```

It runs Swift package tests, starts `AutopilotFixtureApp`, runs the deterministic
driver smoke, runs the scripted one-app agent loop, executes committed scenarios,
and writes logs, trajectories, and JSON reports under
`.build/validation/beta-<timestamp>`. Add `--include-screenshot` when Screen
Recording permission is available. Add `--live-provider openai|anthropic` only
when the matching provider key is available through the environment or
Mac Autopilot Keychain entry.

Committed scenario fixtures live in `docs/validation/scenarios`. Each fixture
file should be named `<scenario-id>.json`, decode as `AgentValidationScenario`,
target a non-empty app/task, use a positive `maxSteps` when present, and include
at least one expectation field. The package tests load these committed fixtures
directly so malformed or accidentally empty scenarios fail before beta
validation is run by hand.

## AI Access Validation

Do not commit keys, OAuth tokens, Firebase ID tokens, or provider responses.

- **Mac Autopilot Basic.** Sign in with Google from the Control Center, confirm
  the UI reports a signed-in Basic account, then run a fixture task through the
  hosted path. Expected result: the app sends a Firebase-authenticated callable
  request to `llmProxy`, the backend resolves the model to `gpt-5.4-mini`, and
  Firestore receives only usage metadata.
- **BYOK OpenAI / Anthropic.** Use a saved Keychain key from the app or a
  process-local environment key for smoke validation:
  ```sh
  OPENAI_API_KEY=... swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp --live-provider openai
  ANTHROPIC_API_KEY=... swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp --live-provider anthropic
  ```
- **OpenAI-compatible endpoint.** In the Control Center, choose a preset or
  custom Chat Completions URL, set the model id, provide an API key only if the
  endpoint requires one, and set image support only when the model supports it.
- **Existing account access.** Choose ChatGPT subscription or Claude
  subscription and complete the app-owned OAuth flow. Expected result: refreshable
  credentials are stored in Keychain; browser cookies are not read or pasted.

Expected result: the fixture input ends with `live smoke value`, the agent calls
`done`, and the smoke CLI reports success.

To run deterministic fixture checks and one live fixture smoke in a single
launch/cleanup cycle:

```sh
./script/validate_fixture.sh --live-provider openai
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
- **AX attribute capture (numeric value + empty-title label).** The fixture run's
  `verify_checkbox_value` and `verify_icon_button_label` steps cover this on the
  bundled app. Confirm it on a real app too: `--dump-tree` an app with a checkbox
  or toggle (e.g. a System Settings pane) and an icon-only toolbar button (Safari
  or Finder), and check that the checkbox shows a `value:` (0/1) and the toolbar
  icon shows a label rather than appearing as a bare `AXButton`.

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

## Real-World Reliability Validation (hard targets)

The Safe Real-App Matrix above covers easy single-window native apps. These
harder targets exercise the failure modes most likely to break real-world use;
run them once the easy matrix passes, capturing the same fields. Each maps to a
ranked risk in the engineering plan, and each fix is reactive — send the saved
trace of any failure.

- **Web forms (Safari/Chrome) — AX↔DOM fidelity.** Beyond the local-page smoke:
  a real multi-field form (search, login on a test account). Set several fields,
  then submit, and confirm the page actually received every value. Watch for: a
  field that reports the set value via AX while the page ignored it; a button
  click that "succeeds" via AX but nothing happens. (Risk #1, action-effect
  verification — the Safari `set_value` bug class.)
- **Electron app (VS Code / Slack / Discord) — click reliability.** Custom UI
  with thin AX. Run a non-destructive task that clicks a control with no working
  AXPress (exercises the synthesized-click fallback). Watch for: clicks landing
  off-target (Retina / multi-display coordinate space), or AX "success" with no
  visible effect. (Risks #1 and #5.)
- **Large / content-heavy page — perception limits.** Point at a long page and
  `--dump-tree`. Watch for: multi-second reads, the target control missing
  because the 1500-element cap truncated it, or the run stalling if the app is
  briefly unresponsive (no AX messaging timeout yet). (Risks #2 and #3.)
- **Multi-window app — window selection.** An app with two or more windows open.
  Confirm the agent reads and acts on the intended window, and that a screenshot
  matches it. Watch for: actions hitting the wrong window; screenshots matching
  the wrong window. (Risk #4.)
- **Longer multi-step task.** A 6–10 step task in one app. Watch for: whether the
  default 25-step budget is enough, transitional/half-rendered state right after
  an action (would motivate a settle delay), and a clean `done` finish.
- **Approval UX in the app (not the CLI).** In the MacAutopilot app, run a task
  with one write and one destructive action. Confirm the prompt appears, Approve
  proceeds, and Decline stops the action without a retry. The smoke CLI
  auto-approves, so this is the only way to validate the safety gate. (Risk #6.)
- **Live provider runs.** One live run on Mac Autopilot Basic, each BYOK
  provider (OpenAI and Anthropic), one OpenAI-compatible endpoint, and each
  subscription account path. Confirm image input is enabled only where supported
  and prompt caching is reported correctly for Anthropic.

## Shared State And Workflow Validation

These are manual app checks for the shared-state workflow milestone.

- **Shared run state.** Start a safe one-app run from the Control Center, then
  open the compact assistant. Confirm both surfaces show the same target app,
  phase, user-visible state label, feed updates, pending approvals/questions/
  proposals, and stop state. Answering or stopping from one surface should
  update the other because pending interactions are shared `AgentViewModel`
  state, not separate Control Center and compact-assistant queues.
- **User-visible state labels.** Exercise or simulate each user-visible state:
  Ready before a prompt, Working during an active run, Waiting for You while an
  approval/question/proposal is pending, Stopping immediately after Stop is
  pressed, Done after a successful finish, Stopped after a cooperative stop, and
  Needs attention after a permission, provider, or runtime error. Confirm the
  Control Center and compact assistant use the same label for the same run.
- **Stopped is not a failure.** Start a safe run, press Stop, and let the agent
  wind down. Expected result: both surfaces show Stopping while the stop is in
  progress, then Stopped after it completes; the history record stores
  `RunStatus.stopped`, and the run is not presented as Needs attention or as an
  error.
- **Editable proposed workflow.** Run a repeatable safe task that causes the
  model to call `propose_workflow` (or use a local test provider/scenario that
  returns that tool call). In the Control Center, edit the proposed workflow
  before saving: name, goal template, slots, and any secret-free recipe hints.
  Confirm the saved workflow uses the edited values, not the raw proposal.
- **Saved workflow edit and slot privacy.** Edit an existing saved workflow in
  the Control Center, including its optional recipe hints. Relaunch the app and
  confirm the change was persisted through the local workflow store. Run it with
  distinctive slot values, then inspect
  `~/Library/Application Support/MacAutopilot/workflows.json`; it should contain
  the template, slot names, and optional secret-free hints, but not the typed
  slot values used for that run.
- **Approval target context.** In the app, trigger a write approval against a
  labeled control. Confirm the approval prompt shows the app, risk tier, action
  summary, and available live target details such as label, role, accessibility
  identifier or element id, value, and snapshot turn. Decline the action and
  confirm the run tells the model not to retry that same action.

## Privacy Storage Checks

Inspect Application Support after a run:

- `run-history.json` stores redacted task labels, app/model/status/tool
  metadata, and timestamps only.
- `workflows.json` stores single-app goal templates, slot names, and optional
  secret-free recipe hints; typed slot values are not persisted.
- `memory.json` stores only user-approved durable memories.
- Provider API keys and OAuth credentials are in Keychain, not `UserDefaults`,
  local JSON, logs, or source files.
- Firestore direct client rules remain deny-all unless a new architecture
  decision explicitly changes them.

## Permission Checks

Apple documents Accessibility trust through
`AXIsProcessTrustedWithOptions` and Screen Recording through
`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`. Verify:

- Missing Accessibility blocks runs before the first LLM call.
- Missing Screen Recording is a warning unless screenshots are requested.
- Re-checking permissions after returning from System Settings updates the UI.

**Ad-hoc identity and TCC grants.** The local Debug app is ad-hoc signed (no Team
ID), so macOS keys its grant on the binary's content hash. Verified with
`codesign -dv --verbose=4`: the CDHash is stable across launches, no-op rebuilds,
and `build_and_run.sh --launch-only`, but changes when you rebuild after editing
code — which silently drops the grant while System Settings still shows the app
enabled. This is why the smoke CLI keeps working (it inherits the Terminal's
grant) while a freshly rebuilt GUI app reports missing permission. To validate
the GUI reliably: build once, grant, then relaunch with
`./script/build_and_run.sh --launch-only` (no rebuild). To make grants survive
code changes, build with a stable team via `AUTOPILOT_DEV_TEAM=<TeamID>`.

TCC logs confirm the trap (`Failed to match existing code requirement for subject
com.langqi.MacAutopilot`): once a grant has gone stale, its stored requirement
stays bound to the older build's cdhash, so System Settings keeps showing the app
ON while the current build matches nothing — and `--launch-only` cannot repair a
grant that is *already* stale. Recover by resetting first, then relaunching and
re-granting the current build: `tccutil reset Accessibility|ScreenCapture
com.langqi.MacAutopilot` → `./script/build_and_run.sh --launch-only` → re-enable
in System Settings → **Re-check permissions**.

## Release Gate

A release candidate must pass:

- automated baseline
- `./script/validate_beta.sh` fixture and scripted-scenario reports
- fixture driver validation
- one live smoke for each enabled provider
- at least three safe real-app tasks
- manual approval test for one write action and one destructive action
