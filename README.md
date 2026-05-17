# Mac Autopilot

Native macOS app experiment for an Accessibility-tree-first computer-use agent.

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
```

The smoke runner process needs Accessibility permission in System Settings >
Privacy & Security > Accessibility. Screen Recording is useful for screenshot
fallbacks, but this smoke test does not require screenshots.
