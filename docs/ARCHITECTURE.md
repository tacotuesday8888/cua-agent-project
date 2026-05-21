# Mac Autopilot Architecture Notes

These notes capture product-shaping architecture decisions that can be built
before the final notch UI exists.

## Product Shape

Mac Autopilot is literally based in the MacBook notch. The notch is the app's
home and primary surface — not a metaphor, not a menu-bar popover, and not an
ordinary floating window. The assistant originates from the physical notch,
expands out of it to take a task, and collapses back into it while work runs.
It controls one target app at a time. On Macs without a notch, a top-center
fallback stands in for the notch, but the notch-resident architecture is the
same.

That product shape implies a few hard technical seams:

- The agent run must be independent of the visible panel state.
- Approvals, questions, memory proposals, and stop requests must be resumable
  interactions, not modal dialogs owned by a normal app window.
- The agent must emit structured events that both a test harness and the notch
  surface can render.
- The action layer must expose target metadata before acting so the UI can show
  what will be clicked, typed into, overwritten, or deleted.

## Current Local-First Stack

- `AutopilotAgent` owns the perceive -> decide -> act -> verify loop. It keeps
  only the most recent UI-tree observations verbatim in the LLM context and
  prunes older ones, so a long run's token cost stays bounded.
- Tool input validation normalizes element references before safety checks,
  loop detection, and execution, so equivalent references like `2`, `"2"`, and
  `"e2"` target the same captured UI element. Malformed element ids, fractional
  scroll amounts, and invalid memory scopes are returned as recoverable tool
  errors before approval prompts, app actions, or memory writes.
- `AutopilotMac` implements the real macOS `ComputerControl` driver with AX
  tree reads, AX actions, synthesized input, and screenshot fallback.
- `AutopilotLLM` keeps provider calls behind `LLMProvider`. Token usage carries
  prompt-cache creation and read counts alongside fresh input, and the run's
  cumulative input tally sums all three, so a cached Anthropic run is reported at
  its true input cost instead of only its uncached remainder.
- `AutopilotUI.AgentViewModel` bridges agent events and user interactions for
  both the temporary harness and the notch surface.
- `AutopilotUI.NotchController` owns the notch panel lifecycle and keeps the
  placeholder notch surface aligned to the physical notch (or a top-center
  fallback on non-notch Macs).
- API keys are local-only and stored in Keychain under
  `com.langqi.MacAutopilot.llm-api-keys`.
- Durable memory is local-only under Application Support and must not store
  secrets.
- `AutopilotHistory` persists a redacted log of finished runs (`RunRecord`)
  under Application Support, capped to the most recent entries.
- `AutopilotWorkflows` persists reusable workflows (`Workflow`) under Application
  Support, capped and secrets-free. A workflow is a goal template plus the
  variables that fill it; a `recipe` field exists on the model for forward
  compatibility but is unused for now (a later phase injects it as a prompt
  prior). The module depends only on Foundation, and only `AutopilotUI` consumes
  it — the agent loop is untouched by single-app workflows.
- Local JSON stores write atomically and keep a `.backup` sibling of the
  previous file before overwriting existing memory, history, or workflow state.
  If a corrupt file is later replaced, the corrupt bytes are still retained for
  manual recovery instead of being silently lost.

## GLM 4.7 Flash

The Z.AI provider uses the OpenAI-compatible chat-completions shape:

- Endpoint: `https://api.z.ai/api/paas/v4/chat/completions`
- Model: `glm-4.7-flash`
- Tool calling: function tools with `tool_choice: auto`
- Key handling: `Authorization: Bearer <api-key>`
- Capability metadata: tool calls are enabled, image input is disabled, prompt
  caching is disabled.

Official references:

- Z.AI Chat Completion API:
  `https://docs.z.ai/api-reference/llm/chat-completion`
- GLM 4.7 model guide:
  `https://docs.z.ai/guides/llm/glm-4.7`

The app should never store provider keys in source, `UserDefaults`, logs, test
fixtures, or commits. The temporary harness stores the Z.AI key in Keychain when
the user runs a task. The smoke CLI can read `ZAI_API_KEY` from the environment
for one-off validation, then falls back to the same Keychain account.

Provider capabilities live in `AutopilotLLM.LLMProviderDescriptor`. UI and smoke
tooling must use those descriptors instead of duplicating model names, keychain
accounts, or screenshot assumptions.

## Safety Model

The current approval tiers are intentionally simple:

- `safe`: read-only or reversible actions such as reading state and scrolling.
- `write`: changes app state; ask once per app session unless the app is
  permanently trusted.
- `destructive`: sends, deletes, pays, overwrites, subscribes, signs out, or
  otherwise creates consequential effects; always ask.

Destructive intent is read from the target element's label, value, and
accessibility identifier; for `perform_secondary_action` the action name itself
is also checked, so a context-menu "Delete" or `AXDelete` invoked on a plainly
labeled row is still gated. Matching errs toward asking.

The notch UI should surface approvals inline with the action summary, app name,
risk tier, and target frame when available. Declined actions must return a tool
result telling the model not to retry the same action.

## Workflows

A workflow turns a successful one-off task into something repeatable. It is a
saved goal template with `{{slot}}` variables (for example,
`Email {{recipient}} the weekly report`), scoped to a single app. Running a
workflow fills the slots with the user's values and feeds the resolved goal back
through the normal perceive → decide → act → verify loop, so the agent re-reads
the live screen and reasons again rather than replaying recorded steps. That is
the core difference from rule-based automation (Shortcuts, Automator, macros):
the recipe is guidance, the live loop is the source of truth, so a workflow
adapts to UI and edge-case changes instead of breaking.

Scope and guarantees for the current phase:

- **Single-app only.** A workflow runs exactly one app; cross-app workflows are a
  later phase. The `Workflow` model isolates the app name so that change needs no
  data migration.
- **On-demand only.** Workflows run when the user triggers them; scheduling and
  unattended runs are out of scope.
- **Not auto-trusted.** A re-run goes through the same risk gate as any task —
  destructive steps still ask for approval.
- **Local and secrets-free.** Workflows live in `workflows.json` under
  Application Support and store a goal template, variable names, and (later) a
  recipe — never typed values or passwords. Variable values entered at run time
  are used transiently and never persisted.
- **Store-guarded.** The workflow store trims simple boundary whitespace, drops
  invalid records read from disk, and rejects writes missing a name, app, or
  goal. The UI still validates early for a nicer user flow, but persistence is
  the final integrity boundary.
- **Capture.** This phase captures workflows by hand or by saving a finished run
  (`AgentViewModel.createWorkflow` / `saveRunAsWorkflow`). A later phase adds an
  agent-proposed `propose_workflow` tool and a learned recipe injected on re-runs.

## Session State

The agent should treat a run as a durable state machine:

- `idle`: waiting for a prompt.
- `running`: the loop is active.
- `awaiting input`: approval, clarification, or memory proposal.
- `finished`: completed with a summary.
- `failed`: stopped, permission-blocked, provider-blocked, or errored.

Live run state is in `AgentViewModel` and the event stream. `AutopilotHistory`
persists the redacted record of each finished run: the task, target app, model,
status, summary, ordered tool names, and timestamps. Full AX trees, screenshots,
prompts, clarifying-question answers, and provider responses are never stored —
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
- App-picker polish around duplicate app names and saved workflow target edits.
- Redesigning `NotchAssistantView` behind the existing `AgentViewModel` and
  `NotchController` contracts.
- More safety tests around destructive labels, overwrites, and app trust.

## Work That Should Wait For Notch UI Decisions

- Hover animation and dwell timing.
- Final collapsed/expanded dimensions.
- App-chip layout and picker behavior.
- Highlight overlay placement and animation.
- Whether approvals interrupt with a fully expanded panel or a compact inline
  confirmation.
- Global hotkey and menu-bar affordance polish.
