# Mac Autopilot Architecture Notes

These notes capture product-shaping architecture decisions that can be built
before the final notch UI exists.

## Product Shape

Mac Autopilot is a notch-resident macOS assistant that controls one target app
at a time. The final UI should feel like the notch expands into an assistant,
then collapses back to a compact status surface while work is running.

That UX implies a few hard technical seams:

- The agent run must be independent of the visible panel state.
- Approvals, questions, memory proposals, and stop requests must be resumable
  interactions, not modal dialogs owned by a normal app window.
- The agent must emit structured events that both a test harness and the notch
  surface can render.
- The action layer must expose target metadata before acting so the UI can show
  what will be clicked, typed into, overwritten, or deleted.

## Current Local-First Stack

- `AutopilotAgent` owns the perceive -> decide -> act -> verify loop.
- `AutopilotMac` implements the real macOS `ComputerControl` driver with AX
  tree reads, AX actions, synthesized input, and screenshot fallback.
- `AutopilotLLM` keeps provider calls behind `LLMProvider`.
- `AutopilotUI.AgentViewModel` bridges agent events and user interactions for
  both the temporary harness and the notch surface.
- `AutopilotUI.NotchController` owns the floating panel lifecycle and keeps the
  placeholder notch surface aligned to the top-center screen geometry.
- API keys are local-only and stored in Keychain under
  `com.langqi.MacAutopilot.llm-api-keys`.
- Durable memory is local-only under Application Support and must not store
  secrets.

## GLM 4.7 Flash

The Z.AI provider uses the OpenAI-compatible chat-completions shape:

- Endpoint: `https://api.z.ai/api/paas/v4/chat/completions`
- Model: `glm-4.7-flash`
- Tool calling: function tools with `tool_choice: auto`
- Key handling: `Authorization: Bearer <api-key>`

Official references:

- Z.AI Chat Completion API:
  `https://docs.z.ai/api-reference/llm/chat-completion`
- GLM 4.7 model guide:
  `https://docs.z.ai/guides/llm/glm-4.7`

The app should never store provider keys in source, `UserDefaults`, logs, test
fixtures, or commits. The temporary harness stores the Z.AI key in Keychain when
the user runs a task. The smoke CLI can read `ZAI_API_KEY` from the environment
for one-off validation, then falls back to the same Keychain account.

## Safety Model

The current approval tiers are intentionally simple:

- `safe`: read-only or reversible actions such as reading state and scrolling.
- `write`: changes app state; ask once per app session unless the app is
  permanently trusted.
- `destructive`: sends, deletes, pays, overwrites, subscribes, signs out, or
  otherwise creates consequential effects; always ask.

The notch UI should surface approvals inline with the action summary, app name,
risk tier, and target frame when available. Declined actions must return a tool
result telling the model not to retry the same action.

## Session State

The agent should treat a run as a durable state machine:

- `idle`: waiting for a prompt.
- `running`: the loop is active.
- `awaiting input`: approval, clarification, or memory proposal.
- `finished`: completed with a summary.
- `failed`: stopped, permission-blocked, provider-blocked, or errored.

Today this state is in `AgentViewModel` and the event stream. A future local
history store should persist redacted run metadata only: timestamps, target app,
status, high-level actions, and final summary. Full AX trees, screenshots,
prompts, answers, and provider responses should stay off by default because
they can contain private user data.

## Backend And Accounts

The MVP does not need user accounts if it remains local-first and bring-your-own
key. Accounts become useful when the product offers hosted features:

- Authentication: required for paid hosted plans, sync, team use, or support.
- User settings: optional sync for preferences, trusted apps, and model choice.
- Usage limits: required if Mac Autopilot pays for LLM usage or offers trials.
- Subscription/payment readiness: required before managed LLM credits or
  commercial distribution with entitlements.
- LLM key/security handling: BYOK can remain local Keychain-only; hosted keys
  need a server-side vault, access audit logs, key rotation, and least-privilege
  service boundaries.
- Logs/history: local redacted history first; remote history should be opt-in
  and encrypted or minimized.

Recommended default: keep the engine local-first, make BYOK the first working
path, and design backend contracts around optional entitlements and settings
rather than making the agent loop depend on a server.

## Work That Can Continue Before Final UI

- First low-risk live GLM run against a normal third-party app.
- Better prompt/tool-choice recovery for stale or missing AX elements.
- More robust driver diagnostics for permission and target-window failures.
- Target-app selection logic for the future `@app` picker.
- Redesigning `NotchAssistantView` behind the existing `AgentViewModel` and
  `NotchController` contracts.
- Redacted local session-history primitives.
- More safety tests around destructive labels, overwrites, and app trust.

## Work That Should Wait For Notch UI Decisions

- Hover animation and dwell timing.
- Final collapsed/expanded dimensions.
- App-chip layout and picker behavior.
- Highlight overlay placement and animation.
- Whether approvals interrupt with a fully expanded panel or a compact inline
  confirmation.
- Global hotkey and menu-bar affordance polish.
