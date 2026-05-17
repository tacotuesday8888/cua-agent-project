# Agent Instructions

## Official-First Workflow

Whenever you configure, integrate, deploy, install, or use any external service, SDK, API, framework, MCP server, plugin, or tool, consult the official documentation, official guides, and official setup instructions if you are not fully certain.

Prefer the official recommended approach first. If the official approach does not fully work, stay as close to it as possible and clearly explain why any deviation is necessary. Do not invent custom setups, shortcuts, or workarounds unless there is a strong practical reason.

## Technical Communication

Whenever you ask me to make a technical decision, explain it in simple, non-technical language first.

Assume I am not deeply technical:
- avoid unnecessary jargon
- explain what each option means
- explain why the decision matters
- explain the practical tradeoffs
- recommend the safest/default option first

Before asking me to choose, make sure I understand the real impact of the decision.

## Development Style

- Keep changes clean, minimal, and maintainable
- Do not overengineer
- Prefer safe, standard, production-ready approaches
- Verify changes before assuming they work
- Do not make risky or irreversible changes without explanation

## Git and Safety Rules

- You may decide when to commit and push if the changes are safe, intentional, and meaningful
- Before committing or pushing, check Git status and review what is being included
- Never commit secrets, API keys, env files, plist files, tokens, certificates, or local configs
- Do not push if the remote looks wrong, the branch looks wrong, or sensitive files may be included
- Prefer small, meaningful commits over large messy commits
- After committing or pushing, report what changed and the commit hash
