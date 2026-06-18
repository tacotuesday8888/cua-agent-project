# Security

## Supported Versions

Security fixes target the `main` branch and the latest public beta builds.

## Reporting A Vulnerability

Open a private security advisory through the repository's GitHub **Security**
tab when available. If private advisories are unavailable, open a minimal public
issue that asks for a private contact path but does not include exploit details,
API keys, OAuth tokens, screenshots, or private Accessibility-tree dumps.

Useful reports include:

- The affected commit, build, or release.
- A short reproduction using a test app or redacted fixture.
- Whether the issue can execute an action without approval, persist private
  data, leak credentials, bypass authentication, or exceed hosted quotas.

## Secret Handling

Do not commit `.env` files, provider keys, OAuth tokens, private keys,
certificates, provisioning profiles, Firebase service-account JSON, notarization
credentials, or local tool state. If a real secret is committed or printed in a
public channel, treat it as compromised and rotate it before continuing.

## Public Repo Checks

CI runs `script/check_public_hygiene.sh` to reject common tracked local files,
build outputs, credentials, and high-confidence secret patterns. This check is
a guardrail, not a substitute for reviewing diffs before commit and push.
