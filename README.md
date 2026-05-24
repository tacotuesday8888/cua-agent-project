# Mac Autopilot

Native macOS AI workflow assistant built on an Accessibility-tree-first
computer-use agent. Run a one-off task from chat, then save a successful task as
a reusable **workflow** the agent re-reasons each time it runs — so it adapts to
messy app state instead of breaking like a recorded macro. Under the hood it
reads a target app's accessibility tree, decides with an LLM, acts through
Accessibility actions and synthesized input, then verifies the result — one app
at a time.

## How It Works

- The agent runs a perceive → decide → act → verify loop (`AutopilotAgent`)
  against a single app the user picks, or names inline with `@App` in the task.
- Perception is the accessibility tree rendered to compact text, with
  screenshots as a fallback. The transcript keeps only recent observations, so a
  long run's token cost stays bounded.
- Actions are risk-gated: reading is free, the first write to an app asks once,
  and destructive actions (send, delete, pay, overwrite) always ask.
- The loop stops itself when it repeats one action with no progress, and warns
  the model as its step budget runs low.
- The model can ask clarifying questions and propose durable memories, each
  surfaced for the user to approve. Finished runs are kept in a redacted local
  history. API keys live in the Keychain; nothing leaves the machine except the
  chosen LLM provider's calls.
- A successful task can be saved as a reusable **workflow**: a goal template with
  `{{slot}}` variables you fill in at run time. Re-running a workflow feeds the
  resolved goal back through the same agent loop and approval gate — it is not a
  recorded click-script and is never auto-trusted. Workflows are single-app for
  now, stored locally in `workflows.json`, and hold no secrets.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the notch-led product
shape, safety model, local session-state approach, and backend/account plan.
Use [docs/VALIDATION.md](docs/VALIDATION.md) for repeatable fixture, live
provider, and safe real-app validation. See [docs/RELEASE.md](docs/RELEASE.md)
for direct-distribution and App Store readiness notes.

## Permissions

Mac Autopilot needs **Accessibility** access to read and control other apps,
and optionally **Screen Recording** for screenshot fallback. Grant them from
the app's permissions panel, or in System Settings > Privacy & Security. The
smoke CLI process needs the same Accessibility grant.

### Granting permissions reliably

macOS ties these grants to the app's *code identity*. The local Debug build is
ad-hoc signed (no Team ID), so its identity is keyed by the binary's content
hash: it stays stable across launches and no-op rebuilds, but **changes whenever
you rebuild after editing code** — and macOS then silently drops the grant, even
though System Settings may still show Mac Autopilot enabled. To grant once and
keep it:

1. Build and launch once: `./script/build_and_run.sh`
2. Grant **Accessibility** (required) and **Screen Recording** (optional) from
   the app's permissions panel or System Settings > Privacy & Security, then
   click **Re-check permissions**.
3. Relaunch *without* rebuilding so the identity stays the same:
   `./script/build_and_run.sh --launch-only`

After you change code and rebuild, the ad-hoc identity changes, so re-grant (or
use stable signing, below). If System Settings shows a grant the app does not
see, clear the stale entry and grant again:

```sh
tccutil reset Accessibility com.langqi.MacAutopilot
tccutil reset ScreenCapture com.langqi.MacAutopilot
```

**Make grants survive rebuilds (optional).** Sign with a stable Apple
Development identity instead of ad-hoc, so the grant is keyed to your team rather
than the content hash. Add your Apple ID in Xcode (Settings > Accounts — a free
account works), find your 10-character Team ID, then build with it:

```sh
AUTOPILOT_DEV_TEAM=YOURTEAMID ./script/build_and_run.sh
```

Leaving `AUTOPILOT_DEV_TEAM` unset keeps the default ad-hoc build that CI uses.

## Build And Test

```sh
swift build --package-path AutopilotKit
swift test --package-path AutopilotKit
xcodebuild -project MacAutopilot.xcodeproj -scheme MacAutopilot -destination 'platform=macOS' build
./script/build_and_run.sh --verify
```

## Real Driver Smoke Test

The package includes a small AppKit fixture app and a CLI smoke runner that
exercise the 9-tool driver surface without an LLM:

```sh
swift run --package-path AutopilotKit AutopilotFixtureApp
swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp
swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp --include-screenshot
./script/validate_fixture.sh
./script/validate_fixture.sh --live-provider zai
```

To inspect what the agent would see for any running app, dump its
accessibility tree:

```sh
swift run --package-path AutopilotKit AutopilotSmokeCLI --app Safari --dump-tree
```

## GLM 4.7 Flash

The default Z.AI provider is `glm-4.7-flash` on Z.AI's OpenAI-compatible chat
completions endpoint. Do not put keys in source files. Use one of these local
paths:

- App harness: choose `Z.ai GLM-4.7-Flash`, paste the key into the secure field,
  and run a task; the app stores it in Keychain.
- Smoke CLI: set `ZAI_API_KEY` only in the shell session that runs the smoke
  test, or save the key through the app first.

```sh
swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp --live-provider zai
```

The same live fixture smoke can be run through the validation script with
`./script/validate_fixture.sh --live-provider zai`; add `--api-key-env NAME`,
`--model MODEL`, or `--max-steps N` when needed. The live provider path is
opt-in because it uses a real API key.

The smoke runner process needs Accessibility permission in System Settings >
Privacy & Security > Accessibility. Add `--include-screenshot` to also require
Screen Recording and validate target-window screenshot bytes.

Provider capabilities are explicit in code. Z.AI is configured as a text-only
tool-calling provider, so screenshot image blocks are omitted with a warning;
Anthropic is configured for image input and prompt caching.
