# AGENTS.md

Project instructions for Codex and other coding agents. Keep shared repo rules in
sync with `CLAUDE.md`.

## Project Direction

MacAutopilot is a local-first macOS Swift app for AI-assisted computer use. The
product direction is a Mac-native AI workflow assistant: chat remains for
one-off tasks, and repeated successful work should become reusable workflows.

Workflows should handle messy local Mac context, not become a Mac cleaner,
generic chatbot, n8n/Zapier clone, workflow canvas, Ara clone, or enterprise RPA
system. Build single-app workflows first; defer cross-app execution, scheduling,
backend/accounts, record-and-replay, and final notch polish until validated.

## Build And Validation

- Run package tests with `swift test --package-path AutopilotKit`.
- Run the app build with `xcodebuild -project MacAutopilot.xcodeproj -scheme MacAutopilot -destination 'platform=macOS' -derivedDataPath .build/xcode build`.
- For driver changes, follow `docs/VALIDATION.md`; fixture and real-app smokes
  may require Accessibility and Screen Recording permissions.

## Engineering Rules

- Preserve the local-first BYOK model, Keychain provider keys, local memory, and
  redacted local run history.
- Keep edits scoped to the requested work and existing package boundaries.
- Do not revert user or other-agent changes without explicit instruction.
- Before continuing inherited work, inspect the relevant diff, repo state, tests,
  and product constraints.
- If another agent's work is sound, continue from it. If it needs changes, make
  the smallest targeted correction and verify it.
- Add or update focused tests for behavior you change.

## Repo References

- Issues are tracked in GitHub Issues on `tacotuesday8888/cua-agent-project`;
  see `docs/agents/issue-tracker.md`.
- Triage labels are documented in `docs/agents/triage-labels.md`.
- Domain docs use one root `CONTEXT.md` plus `docs/adr/`; see
  `docs/agents/domain.md`.
