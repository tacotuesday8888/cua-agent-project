# Mac Autopilot — Project Handoff

A complete brief for picking this project up cold. Everything below reflects
decisions made with the project owner (Langqi) and the current state of the
code in this repo.

---

## 1. What this is

**Mac Autopilot** is a native macOS app: a **notch-resident AI assistant that
operates other Mac apps for you**. You type a natural-language request; an AI
agent reads the target app's UI, decides what to do, and clicks/types on your
behalf.

It is inspired by **cua** (github.com/trycua/cua — open-source computer-use
agent infrastructure, MIT) and **Ara** (YC S26 — a notch-resident, voice-first
Mac agent). The differentiator vs. OpenAI's Codex computer use and Anthropic's
Cowork: those are foreground, screenshot-driven, "watch it work" assistants;
Mac Autopilot is a **notch-native, accessibility-tree-driven** agent.

---

## 2. How it should work — the product

### 2.1 The notch UI (most important — this is the product's face)

- **Form:** the **notch itself expands** into the UI (the Ara approach) — the
  black notch region grows down/outward into a translucent dark panel. It is
  NOT a separate dropdown. On non-notch Macs, the same panel is anchored at
  top-center of the screen.
- **At rest:** the notch looks completely normal.
- **Hover:** playful — the notch does a little **shake/wobble + a soft glow**.
  If you **hover long enough**, a cue fades in — an "Autopilot" label and/or a
  sparkle glyph.
- **Invoke (3 ways):** a global hotkey, a menu-bar icon, or clicking the notch.
  Clicking unfolds it so you can start prompting.
- **Prompt:** a single natural-language input ("What should I do?"). Typing `@`
  opens an app picker (app icons + names); choosing one inserts an **app chip**
  (the app's logo) that **pins the target app**. `@app` is purely a target
  picker. Without it, the agent works out / you pick the target app.
- **Running:** the notch **collapses back to a compact size** showing only a
  small status glyph / progress indicator — it stays out of your way while the
  agent works. **Click it to expand** the full **live step feed** ("Opening
  Apple Music…", "Clicking Play"), each step with a spinner, plus a **Stop**
  button.
- **Permission:** when the agent wants to open an app or take a risky action,
  the notch expands and shows an inline **Approve / Skip** prompt, and waits.
- **Done:** a brief result line; the notch eases back to normal.

### 2.2 Agent behaviour

- A **task** = one natural-language request, carried out **within a single
  app** (no cross-app workflows in v1).
- The agent runs a **perceive → decide → act → verify** loop: read the app's
  accessibility tree, ask the LLM for the next action, perform it, re-read the
  tree to verify the effect, repeat.
- **Trust model:** safe/reversible actions run freely; **consequential actions
  (delete, send, purchase, overwrite) are gated** — the user must approve. The
  agent can also ask the user clarifying questions.

---

## 3. Key decisions (and why)

- **Accessibility-tree-PRIMARY perception.** The agent "sees" apps through the
  macOS Accessibility tree (structured UI elements: role, label, value, state)
  rendered as compact text — **not screenshots**. Screenshots are a supplement
  only (for canvas/Electron surfaces). Reasoning: more reliable, cheaper,
  lower-latency, far easier to debug than screenshot+coordinate agents. This is
  how cua's Driver and Ara both work. **This is a firm requirement.**
- **Provider-agnostic LLM.** A real LLM is required, behind a provider-agnostic
  `LLMProvider` protocol. Implemented: **Anthropic** (Claude) and **Z.ai/GLM**
  (an OpenAI-compatible Chat Completions provider). The OpenAI-compatible
  provider also works for OpenRouter, Kimi/Moonshot, DeepSeek, Groq, local
  models (Ollama/LM Studio), etc. — most providers speak the OpenAI format.
- **Native Swift / SwiftUI.** Not Electron/Tauri/web — the product is ~80%
  native macOS system integration (Accessibility API, CGEvent, ScreenCaptureKit,
  notch window, global hotkeys). No bundled Python; the agent loop is in-process
  Swift.
- **No App Sandbox.** A sandboxed app cannot control other apps via the
  Accessibility API, so the app is **non-sandboxed** → **direct distribution**
  (a Developer ID-signed, notarized DMG, Sparkle auto-updates). **Not the Mac
  App Store** (Apple bars sandboxed apps from controlling other apps).
- **Built on cua (MIT)** conceptually — its Driver = accessibility-tree
  automation. Licensing note: never use cua's `omni` extra (it pulls AGPL-3.0
  `ultralytics`); the real-Mac path does not need it.
- **Per-app "knowledge profiles" are deferred.** A future moat: small curated
  per-app knowledge packs that make the agent expert at specific apps. v1 is a
  generic agent; profiles come later.

---

## 4. Architecture & current code

### 4.1 Layout

```
cua agent project/                  ← git repo (remote: tacotuesday8888/cua-agent-project)
  AutopilotKit/                      ← Swift Package — the engine
    Package.swift
    Sources/
      AutopilotCore/                 shared models
      AutopilotLLM/                  provider-agnostic LLM layer
      AutopilotAgent/                the agent loop
      AutopilotPerception/           reads the macOS accessibility tree
      AutopilotAction/               performs AX actions + synthesized input
      AutopilotMac/                  MacComputer (production ComputerControl) + AppLocator
      AutopilotUI/                   the notch UI layer (PARTIAL — see §6)
    Tests/                           ~24 tests (Core, LLM, Agent)
  MacAutopilot.xcodeproj             the macOS app project
  MacAutopilot/                      app target sources (App entry, ContentView, entitlements)
  MacAutopilotTests/
```

### 4.2 The `AutopilotKit` modules

- **AutopilotCore** — `JSONValue` (dynamic JSON for tool I/O), `UIElement` /
  `UITreeSnapshot` (the accessibility-tree model) + `UITreeRenderer` (renders a
  snapshot to compact text for the LLM), `ScrollDirection` / `KeyPress`,
  `RiskLevel`.
- **AutopilotLLM** — `LLMProvider` protocol (`send(_:) async throws ->
  LLMResponse`), the request/response/message/tool types, `LLMError`.
  Implementations: `AnthropicProvider` (Anthropic Messages API, with prompt
  caching), `ZAIProvider` (OpenAI-compatible Chat Completions — works for Z.ai
  GLM and other OpenAI-format APIs), `ScriptedLLMProvider` (test mock).
- **AutopilotAgent** — `AgentSession` (the perceive→decide→act→verify loop,
  an actor), the tool catalog, `RiskClassifier` (flags risky actions),
  `ComputerControl` protocol (the seam to macOS), `MockComputer` (test mock),
  `AgentEvent` (observable run events), `UserInteraction` protocol (confirmations
  + questions). **Agent tools:** `read_tree`, `click_element`, `set_value`,
  `scroll`, `key`, `screenshot`, `ask_user`, `done`.
- **AutopilotPerception** — `AccessibilityTreeReader` (traverses an app's
  `AXUIElement` tree → `UITreeSnapshot` + a live element index), and
  `AccessibilityPermission` (checks/requests the Accessibility TCC permission).
- **AutopilotAction** — `AccessibilityActuator` (AX `AXPress` / set-`AXValue`,
  plus synthesized `CGEvent` keyboard & scroll), `KeyCodes`.
- **AutopilotMac** — `MacComputer`: the production `ComputerControl`, an actor
  that reads via Perception and acts via Action, keyed by the snapshot's element
  ids; screenshots via ScreenCaptureKit. `AppLocator`: finds running apps by
  name / bundle id.
- **AutopilotUI** — `AgentViewModel` (`@MainActor @Observable` — assembles and
  runs an `AgentSession`, streams events into a display feed, bridges
  confirmations to the UI; has a `Provider` enum for Z.ai-GLM vs Anthropic),
  `NotchGeometry` (notch detection + window frames), `NotchWindow` (the
  borderless, non-activating transparent panel). **The notch VIEWS and
  controller are not yet built — see §6.**

### 4.3 The app target

`MacAutopilot.xcodeproj` builds the `MacAutopilot.app`. Bundle id
`com.langqi.MacAutopilot`, deployment target macOS 14.0, App Sandbox OFF, links
the `AutopilotUI` package product. `MacAutopilot/ContentView.swift` is currently
a **minimal test harness** (provider picker, API-key field, target-app picker,
prompt field, live feed) — NOT the notch UI.

---

## 5. What works / is verified

- The entire `AutopilotKit` package compiles; the `MacAutopilot` app builds
  (`xcodebuild` BUILD SUCCEEDED).
- ~24 tests for the AI core; **22 pass, 2 fail** (see §7).
- All committed to git on `main` (the GLM/Z.ai additions are uncommitted
  working changes on top of the last commit).

**Critical caveat:** **nothing has actually run on a real Mac yet.** The tests
all use mocks. The real accessibility-tree reading, the AX actuation, and the
LLM loop against a live API have **never executed**. The first real run is the
single most important next step.

---

## 6. What is NOT done / what's left

1. **The notch UI views & controller** — only `AgentViewModel`, `NotchGeometry`,
   and `NotchWindow` exist. Still to build:
   - The SwiftUI views: the collapsed notch (with the playful hover — shake +
     glow + dwell cue), the expanded prompt panel, the `@app` picker, the live
     status feed, the inline Approve/Skip row.
   - The controller: global hotkey, menu-bar item, click-the-notch, and the
     show / expand / collapse orchestration with the `NotchWindow`.
   - Wiring the notch UI into the app's `@main` (the app currently shows the
     test-harness `ContentView` in a normal window).
2. **First real end-to-end run** — run the app, grant Accessibility + Screen
   Recording permissions, give the agent a real task on a real app, and verify
   the engine actually works. Expect bugs in the real AX/actuation code.
3. **`@app` targeting in the agent** — v1 uses an explicit target-app picker;
   the "agent guesses the app, asks to open it" flow is not built.
4. **Per-app knowledge profiles** — deferred (future moat).
5. **Distribution** — Developer ID signing, notarization, DMG, Sparkle.

---

## 7. Known issue — the 2 failing tests

`swift test --package-path AutopilotKit` shows 2 failures:

- `AnthropicProviderTests.decodesAnthropicResponse` — fails decoding: missing
  key `content`.
- `ZAIProviderTests.decodesZAIResponse` — fails decoding: missing key `choices`.

**Diagnosis:** each provider's decode test receives the *other* provider's
canned JSON (Anthropic's decoder wants `content`; Z.ai's wants `choices`). It is
a **test-isolation bug** — the two provider test suites use `URLProtocol` HTTP
stubs (`StubURLProtocol` and `ZAIStubURLProtocol` in
`AutopilotKit/Tests/AutopilotLLMTests/AutopilotLLMTests.swift`) and run in
parallel, and their stub state cross-contaminates. The **providers themselves
are correct** — the encoding test (`encodesOpenAIStyleToolMessages`), the
HTTP-error test, and the missing-API-key tests all pass.

**Fix direction:** serialize the HTTP-stub provider tests so they never run
concurrently — e.g. nest `AnthropicProviderTests` and `ZAIProviderTests` inside
a single parent suite marked `@Suite(.serialized)`, or give each suite a fully
private stub and confirm no shared global URL-loading state.

---

## 8. Repo, build & run

- **Toolchain:** Swift 6.2, Xcode 26, macOS 14+ deployment target, Apple
  Silicon.
- **Build the package:** `swift build --package-path AutopilotKit`
- **Test the package:** `swift test --package-path AutopilotKit`
- **Build the app:**
  `xcodebuild -project MacAutopilot.xcodeproj -scheme MacAutopilot -destination 'platform=macOS' build`
- **Run it:** open `MacAutopilot.xcodeproj` in Xcode and Run. The first time the
  agent reads or acts, macOS will block it — grant **Accessibility** and
  **Screen Recording** to the app under System Settings → Privacy & Security.
  Enter an LLM API key, pick a target app, type a task.
- **Git:** branch `main`, remote `origin` → `github.com/tacotuesday8888/cua-agent-project`.
  Commit as the user (Langqi) — **no AI/assistant attribution in commit
  messages.**

---

## 9. Suggested next steps (in order)

1. Fix the 2 failing tests (§7) so the suite is green.
2. **Do the first real end-to-end run** — verify the AX reading, the actuation,
   and the LLM loop actually work on a live app before building more UI. This
   de-risks everything.
3. Fix whatever the first run surfaces in the real macOS automation code.
4. Build the notch UI views + controller (§6.1) per the design in §2.1.
5. Wire the notch UI into the app's `@main`; retire the test-harness
   `ContentView`.
6. Then: `@app` targeting, distribution, and (later) per-app knowledge profiles.
