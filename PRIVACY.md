# Privacy

Mac Autopilot is a local-first macOS automation app. It reads one target app at
a time, asks an AI model what to do next, executes approved actions through
macOS Accessibility, then verifies the result.

## What Stays Local

- Provider API keys and subscription OAuth credentials are stored in Keychain.
- Run history, saved workflows, and approved memories are stored under the
  user's Application Support folder.
- Saved workflows store goal templates, slot names, and optional secret-free
  recipe hints. They do not store typed slot values.
- Prompts, Accessibility trees, screenshots, provider responses, API keys,
  OAuth tokens, and typed workflow variable values are not persisted by the app.

## What Can Leave The Mac

- Mac Autopilot Basic sends the current task and compact target-app context to
  the hosted `llmProxy` so the model can produce the next tool call. Screenshot
  bytes are sent only when screenshot fallback is requested and enabled.
- BYOK providers receive the same model input directly from the Mac app under
  the selected provider's terms.
- Live provider smoke tests use real provider credentials only when a developer
  explicitly supplies them through the shell or Keychain.

## Hosted Basic Metadata

The hosted backend stores usage metadata only: user id, model id, token counts,
estimated cost, latency, status, and timestamps. It does not store prompts,
Accessibility trees, screenshots, model responses, or secrets.

## Retention And Deletion

Local history, memories, workflows, and trusted-app choices can be cleared from
the Control Center. Deleting the app does not automatically delete provider
accounts or Firebase Authentication records. Hosted Basic account deletion and
metadata retention are handled through the deployed Firebase project owner until
a self-service account deletion flow is added.

## Permissions

Accessibility is required to read and operate the target app. Screen Recording
is optional and used only for target-window screenshot fallback. The app remains
single-app and one-run-at-a-time for the beta.

## Public Firebase Client Config

`MacAutopilot/GoogleService-Info.plist` contains Firebase client identifiers for
the macOS app. It is not a server secret and cannot authorize backend calls by
itself; the hosted callable still requires Firebase Authentication and server
authorization. Hosted Basic calls Vertex AI using the deployed function's Google
Cloud service account rather than a client-side model key. Public deployments
should restrict the Firebase web/API key to the intended app and APIs in Google
Cloud Console.

## Contact

Use the repository's security reporting path for vulnerabilities or privacy
issues. Do not post secrets, screenshots, Accessibility-tree dumps, or private
validation logs in public issues.
