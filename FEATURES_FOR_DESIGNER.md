# Mac Autopilot — Product Reference For Design

## Current Product

Mac Autopilot is a native macOS AI automation layer for one target app at a
time. The core product is the accessibility-tree-first agent: it reads the live
UI, reasons with an LLM, acts through Accessibility and synthesized input,
verifies after every step, and turns repeatable goals into adaptive workflows.

The primary user surface is the **Control Center** window. It should feel like a
quiet Mac power tool: compact, dense, native, readable, and trustworthy. The
compact notch/top-center assistant is secondary chrome for quick access and
status; do not treat the notch as the differentiator.

## What The Control Center Must Support

- Grant and re-check Accessibility and Screen Recording permissions.
- Choose AI access:
  - **Mac Autopilot Basic**: default hosted AI, Google/Firebase sign-in,
    backend `llmProxy`, Vertex AI Gemini 3.5 Flash, no local provider key.
  - **Bring Your Own Key**: OpenAI, Anthropic, or OpenAI-compatible Chat
    Completions endpoint. Keys stay in Keychain. Compatible endpoints need
    preset/custom URL, model id, optional API key, and image-capability toggle.
  - **Existing AI Account**: ChatGPT subscription and Claude subscription
    through app-owned OAuth credentials in Keychain. No browser-cookie scraping.
- Pick or mention one target app with `@App`.
- Run one task at a time and show live run state.
- Surface approvals inline: writes ask unless the app is trusted; destructive
  actions always ask.
- Let the model ask clarifying questions inline.
- Show recent redacted runs.
- Create, edit, and run saved single-app workflows.
- Manage local memories and permanent app trust.

## Workflows

Workflows are adaptive goals, not recorded click scripts. A saved workflow stores
a single-app goal template with `{{slot}}` variables and optional secret-free
recipe hints. Each run resolves slot values and goes back through the live
perceive -> decide -> act -> verify loop with the same approval gates. Typed slot
values are one-run inputs and are not persisted. The Control Center is the place
to edit a proposed workflow before saving and to edit saved workflows later; the
compact assistant can show workflow state, but it should not be treated as the
primary editing surface.

## Privacy Boundaries

- API keys and OAuth credentials live in Keychain.
- Memory, history, workflows, and trust live locally under Application Support
  with atomic writes and backups.
- History stores redacted metadata only, not prompts, provider summaries, AX
  trees, screenshots, or typed workflow values.
- The backend stores usage metadata only: uid, model, token counts, cost, latency,
  status, and timestamp.
- Firestore/Storage direct client rules should stay deny-all unless a new
  architecture decision changes that.

## Out Of Scope For This MVP

Do not design these as active product promises yet: multi-app workflows,
scheduling, remote sync, payments, voice input, file attachments, and final
compact-assistant hover/global-hotkey polish.
