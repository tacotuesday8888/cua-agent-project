# Mac Autopilot Architecture Notes

These notes capture product-shaping architecture decisions for the current
Mac Autopilot MVP.

## Product Shape

Mac Autopilot is a focused Mac power tool for running one-app AI workflows. The
primary surface is the **Control Center** window: permissions, AI access, target
app selection, task entry, live run state, approvals, saved workflows, run
history, local memories, and permanent app trust are managed from one compact
place. The compact notch/top-center assistant can remain as a secondary launcher
or status surface, but the product is the accessibility-tree-first agent and
adaptive workflow system, not the notch.

That product shape implies a few hard technical boundaries:

- The Mac app owns one live `AgentViewModel` and injects it into both the
  Control Center and compact assistant. The visible surfaces render and mutate
  the same run instead of creating separate session state.
- Approvals, questions, memory proposals, workflow proposals, and stop requests
  must be resumable interactions the Control Center and compact assistant can
  both render. These pending interactions are shared run state, not separate
  per-surface queues.
- The agent must emit structured events that the shared model, a test harness,
  and the compact assistant surface can render.
- The action layer must expose target metadata before acting so the UI can show
  what will be clicked, typed into, overwritten, or deleted.
- The run model remains single-app and single-run-at-a-time. Broader automation
  modes should be designed explicitly before they are added.

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
  tree reads, AX actions, synthesized input, and screenshot fallback. When an
  element advertises no working AX press (common for icon-only buttons, Electron,
  and web views), `click` falls back to a synthesized click at the element's
  center — the same approved target — mirroring the focus → click fallback used
  for typing.
- `AutopilotLLM` keeps provider calls behind `LLMProvider`. Token usage carries
  prompt-cache creation and read counts alongside fresh input, and the run's
  cumulative input tally sums all three, so a cached Anthropic run is reported at
  its true input cost instead of only its uncached remainder.
- `AutopilotUI.AgentViewModel` bridges agent events and user interactions. The
  app target owns one instance for the Control Center and compact assistant, so
  phase, feed, approvals, questions, memory proposals, workflow proposals,
  selected access path, and stop requests are shared.
- `AgentViewModel.runReadiness` is the shared preflight contract for one-off
  runs. It checks prompt presence, local `remember:` prompts, Accessibility,
  optional Screen Recording status, AI access setup, and exact target-app
  resolution before either UI surface enables Run.
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
  Support, capped and secrets-free. A workflow is a goal template plus the slot
  variables it expects, and an optional `recipe` of secret-free hints. Typed slot
  values are one-run inputs and are not persisted. On a re-run, the recipe is
  injected into the system prompt as a prior (guidance, not a script); the agent
  still re-reads and verifies the live screen. The module depends only on
  Foundation, and only `AutopilotUI` consumes it — the agent loop stays
  storage-agnostic for workflows: the `propose_workflow` tool produces a
  `WorkflowProposal` (defined in `AutopilotAgent`) that the shared model exposes
  for UI review/editing before it is mapped onto a stored `Workflow`.
- Local JSON stores write atomically and keep a `.backup` sibling of the
  previous file before overwriting existing `memory.json`, `run-history.json`,
  or `workflows.json` state. If a corrupt file is later replaced, the corrupt
  bytes are still retained for manual recovery instead of being silently lost.

## LLM providers

The user-facing access modes are **Mac Autopilot Basic** (app-managed),
**bring-your-own-key** providers, and **existing account access** where the app
can delegate auth to a provider-supported account path. **Mac Autopilot Basic**
is the default product path: it routes `gpt-5.4-mini` through the project's
authenticated backend, so the user signs in instead of choosing a vendor or
pasting a key. The backend owns the Basic plan policy: arbitrary hosted model
ids are rejected, legacy hosted aliases resolve to the Basic model, response
tokens are capped server-side, and quota/pricing labels come from the same
policy object used by usage accounting.

BYOK includes first-class OpenAI and Anthropic entries plus a configurable
**OpenAI-compatible endpoint** for routers and local servers such as OpenRouter,
Gemini, LiteLLM, Groq, Together, Fireworks, DeepSeek-compatible gateways,
Qwen/GLM-compatible gateways, and Ollama-compatible local endpoints. Existing
account access descriptors remain in the model layer for future OAuth/Keychain
work, but beta builds expose only Mac Autopilot Basic and BYOK as selectable
run paths:

- The Control Center and compact assistant both surface the selected access
  path. Hosted sign-in state is injected from the app target, keeping
  `AutopilotUI` free of Firebase/Google SDK dependencies. The UI also exposes
  the OpenAI-compatible BYOK preset, endpoint, model id, image capability, and
  API-key controls so router/local-model setup is available from the run
  surface.
- ChatGPT subscription access is planned to follow the OpenAI Codex OAuth subscription
  pattern used by Pi-like tools, but the app owns the connector: OAuth
  credentials are stored in Mac Autopilot's Keychain entries, not in Pi or
  browser storage. The direct provider returns structured text/tool output to the
  existing tool-call loop.
- Claude subscription access is planned to follow the Anthropic Claude Pro/Max OAuth pattern
  used by Pi-like tools, again with app-owned Keychain storage and structured
  output into the same tool-call loop.

- OpenAI / hosted: Chat Completions shape, function tools with
  `tool_choice: auto`. BYOK uses `Authorization: Bearer <api-key>`; hosted sends
  the signed-in account's Firebase ID token to the `llmProxy` backend.
- OpenAI-compatible BYOK: user supplies the full Chat Completions URL, model id,
  optional API key, and image-input capability. The UI ships presets for
  OpenRouter, Gemini, Groq, Together AI, Fireworks AI, DeepSeek, Qwen/DashScope,
  GLM/BigModel, LiteLLM, and Ollama, while still allowing a custom endpoint.
  The transport uses the broadly compatible `max_tokens` request field and omits
  `Authorization` when no key is provided for local endpoints.
- Anthropic: Messages API with prompt caching.
- Existing ChatGPT subscription: OpenAI Codex subscription OAuth credentials,
  text-only Codex Responses transport, and structured tool calls. The app owns
  execution and approvals.
- Existing Claude subscription: Anthropic subscription OAuth credentials with
  Claude OAuth bearer headers and the same text-only structured-output contract.

The app should never store provider keys in source, `UserDefaults`, logs, test
fixtures, or commits. The harness stores the bring-your-own-key in Keychain when
the user runs a task. The smoke CLI can read `OPENAI_API_KEY` /
`ANTHROPIC_API_KEY` from the environment for one-off validation, then falls back
to the same Keychain account. Hosted access uses the signed-in account's token,
not a stored key. Existing account access must not scrape browser sessions or
ask users to paste cookies; it should run an explicit OAuth flow, store
refreshable credentials in Keychain, and treat subscription providers as local
bridges into the same app-owned agent loop.

Provider and model capabilities live in `AutopilotLLM.LLMProviderDescriptor`.
UI and smoke tooling must use those descriptors instead of duplicating model
names, keychain accounts, or screenshot assumptions. For the generic compatible
endpoint, model id and image support are user-controlled because routers do not
expose capabilities consistently.

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

The UI should surface approvals inline with the action summary, app name, risk
tier, and live target metadata when available: label, role, accessibility
identifier or element id, value, and snapshot turn. The target frame drives the
live highlight overlay rather than durable text. This target context is for trust
and debugging only; it is not written to run history or workflow storage.
Declined actions must return a tool result telling the model not to retry the
same action.

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

Scope and guarantees:

- **Single-app only.** A workflow runs exactly one app.
- **On-demand only.** Workflows run when the user triggers them; scheduling and
  unattended runs are out of scope.
- **Not auto-trusted.** A re-run goes through the same risk gate as any task —
  destructive steps still ask for approval.
- **Local and secrets-free.** Workflows live in `workflows.json` under
  Application Support and store a goal template, variable names, and optional
  secret-free recipe hints — never typed values or passwords. Variable values
  entered at run time are used transiently and never persisted.
- **Store-guarded.** The workflow store trims simple boundary whitespace, drops
  invalid records read from disk, and rejects writes missing a name, app, or
  goal. Manual creates, proposal saves, and saved-workflow edits all go through
  the local `WorkflowStore`; UI validation is for a nicer user flow, but
  persistence is the final integrity boundary.
- **Proposal/edit flow.** Workflows are created by hand or from an explicit
  `propose_workflow` call after a repeatable task. The proposal becomes pending
  workflow state on the shared `AgentViewModel`. The Control Center is the
  primary editing surface: the user can review and adjust the saved name, goal
  template, slots, and secret-free recipe hints before saving, then edit those
  fields later on saved workflows. The compact assistant can create and run
  workflows, show recipe hints, and render proposal state, but it is not the
  primary editor.
- **No history-to-workflow conversion.** Raw run history is redacted and is not
  used as a workflow goal source. A finished run can inspire an explicit
  proposal, but the app must not reconstruct a saved workflow from
  `run-history.json`. The saved recipe is injected as a prompt prior on re-runs.

## Session State

The agent should treat a run as a durable state machine. Internal phases map to
these user-visible states:

- **Ready**: waiting for a prompt.
- **Working**: the loop is active.
- **Waiting for You**: the run is paused on a user interaction, such as an
  approval, clarification, memory proposal, or workflow proposal.
- **Stopping**: the user has pressed Stop and the UI is waiting for the
  cooperative agent task to wind down.
- **Done**: completed with a summary.
- **Stopped**: the user stopped the run. This is a normal terminal state, not a
  failure, and is recorded with `RunStatus.stopped`.
- **Needs attention**: permission-blocked, provider-blocked, or errored.

Live run state is in the app-owned `AgentViewModel` and the event stream. The
same model is passed to the Control Center and compact assistant so both
surfaces show the same phase, pending interaction, feed, and stop control.
Pending interactions are shared state: answering an approval, question, memory
proposal, or workflow proposal from either surface must clear or resume the same
underlying interaction on the other surface.
`AutopilotHistory` persists the redacted record of each finished run to
`run-history.json`: a generic task label, target app, model, status, ordered
tool names, and timestamps. Raw prompts, model summaries, AX trees, screenshots,
clarifying-question answers, provider responses, API/OAuth secrets, and typed
workflow variable values are never stored — they can contain private user data.

## Backend And Accounts

The on-device agent stays local — only the LLM call can move server-side, via
a thin authenticated proxy. That makes Mac Autopilot Basic the simple default
without putting a provider key in the client, while BYOK remains available for
users who want direct provider control.

What's shipped:

- **`llmProxy`** — Firebase Functions 2nd gen, written with **Genkit** + the
  `@genkit-ai/compat-oai` plugin, fronting **OpenAI GPT-5.4 Mini** for Mac
  Autopilot Basic. Source lives under `backend/`.
- **Auth gate** — `onCallGenkit`'s `authPolicy` rejects anything without a
  signed-in Firebase user, so the function can't be invoked anonymously.
- **Sign-in** — Firebase Authentication with the Google provider. The client
  obtains an ID token via `FirebaseAuth` + `GoogleSignIn-iOS` and sends it as
  the callable's `Authorization: Bearer …`.
- **Quotas + usage** — a per-user monthly cap is enforced inside the flow
  (atomic Firestore transaction). Each call writes a **metadata-only** usage
  doc (uid, model, tokens, cost, latency, status). Prompts, responses, AX
  trees, and screenshots are never persisted.
- **Client provider** — `HostedProvider` (alongside `OpenAIProvider`,
  `AnthropicProvider`, OpenAI-compatible endpoints, and subscription account
  providers) speaks the callable wire format
  (`{data: …}` request + `{result: …}` / `{error: …}` response) and maps
  errors back into `LLMError` for the UI. Hosted is the default user-facing path;
  BYOK remains available as the advanced local/provider-controlled path. The app
  target injects hosted account status and sign-in/sign-out actions into the
  shared app-owned model so the compact assistant can show the default path
  without linking Firebase into `AutopilotUI`.

Security stays server-side: Firestore rules are deny-all (clients never read
or write directly), the OpenAI key lives in **Cloud Secret Manager**, and the
client-shipped `GoogleService-Info.plist` carries only client identifiers.
