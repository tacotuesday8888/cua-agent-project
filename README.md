# Mac Autopilot

Native macOS app experiment for an Accessibility-tree-first computer-use agent.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the current notch-led
architecture, GLM 4.7 Flash setup, safety model, local session-state approach,
and backend/account plan.

## Build And Test

```sh
swift build --package-path AutopilotKit
swift test --package-path AutopilotKit
xcodebuild -project MacAutopilot.xcodeproj -scheme MacAutopilot -destination 'platform=macOS' build
```

## Real Driver Smoke Test

The package includes a small AppKit fixture app and a CLI smoke runner that
exercise the 9-tool driver surface without an LLM:

```sh
swift run --package-path AutopilotKit AutopilotFixtureApp
swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp
swift run --package-path AutopilotKit AutopilotSmokeCLI --app AutopilotFixtureApp --include-screenshot
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

The smoke runner process needs Accessibility permission in System Settings >
Privacy & Security > Accessibility. Add `--include-screenshot` to also require
Screen Recording and validate target-window screenshot bytes.
