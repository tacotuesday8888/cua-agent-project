# MacAutopilot backend — hosted LLM proxy

A thin, authenticated **LLM proxy** for Mac Autopilot's *hosted* AI path. The
macOS agent stays on-device; only the model call moves server-side so provider
keys never live in the client and usage can be metered.

- **Runtime:** Firebase Cloud Functions (2nd gen), Node 22.
- **Orchestration:** Genkit — one flow (`llmProxyFlow`) wrapped in `onCallGenkit`.
- **Basic policy:** the backend owns the Mac Autopilot Basic plan: it resolves
  hosted requests to `gpt-5.4-mini`, accepts only legacy aliases such as
  `automatic`, clamps client-requested output tokens to 4096, applies a
  1000-request monthly cap, and uses the Basic pricing label for usage metadata.
- **Auth:** the `onCallGenkit` auth policy requires a signed-in Firebase user, so
  an unauthenticated caller can never reach the model or the key.
- **Tools:** the model **returns** tool calls (`returnToolRequests: true`) for the
  on-device agent to execute — it never runs tools here.
- **Privacy:** only usage **metadata** (uid, model, token counts, cost, latency,
  status) is stored — never prompts, responses, or screen content.

This is the app's default simple path, branded **Mac Autopilot Basic**. BYOK
remains available in the Mac app for users who want their own provider key or
OpenAI-compatible endpoint.

## Layout

- `src/index.ts` — the `llmProxy` callable function (`onCallGenkit`, secret, auth).
- `src/flow.ts` — the Genkit flow: quota check → Basic policy config →
  `ai.generate` → usage record.
- `src/translate.ts` — neutral request/response ⇆ Genkit (pure, unit-tested).
- `src/hostedModel.ts` — Basic model aliases, output-token cap, quota, and
  pricing label.
- `src/quota.ts`, `src/usage.ts`, `src/errors.ts` — pure logic (unit-tested).
- `src/types.ts` — the neutral wire contract shared with the client.

## Local development

```sh
cd backend
npm ci            # or: npm install
npm run typecheck # tsc --noEmit
npm test          # vitest (pure logic)
npm run build     # emits lib/
```

For a live end-to-end run you need a Firebase project + the OpenAI key (below),
then `npx genkit start` or the Firebase emulators.

> Note: if `npm install` fails with an `EACCES`/root-owned cache error on a shared
> machine, point npm at a fresh cache: `npm install --cache /tmp/npm-cache`.

## Deploy (user-side, one-time)

1. In your Firebase project, enable **Authentication** (Google provider),
   **Firestore**, and **Functions**.
2. Store the OpenAI key in Secret Manager (never in source):
   ```sh
   firebase functions:secrets:set OPENAI_API_KEY
   ```
3. Add a `firebase.json` at the repo root pointing Functions at this folder
   (or run `firebase init functions` and choose `backend`):
   ```json
   {
     "functions": [
       {
         "source": "backend",
         "codebase": "default",
         "predeploy": [
           "npm --prefix \"$RESOURCE_DIR\" ci",
           "npm --prefix \"$RESOURCE_DIR\" run build"
         ]
       }
     ]
   }
   ```
4. Deploy and note the callable name (`llmProxy`) and region:
   ```sh
   firebase deploy --only functions
   ```

The macOS client's `HostedProvider`
([`AutopilotKit/Sources/AutopilotLLM/HostedProvider.swift`](../AutopilotKit/Sources/AutopilotLLM/HostedProvider.swift))
calls `llmProxy` with the signed-in user's Firebase ID token.

`llmProxy` treats the client request as untrusted policy input. A client may
send a preferred model or `maxTokens`, but Basic always resolves to
`gpt-5.4-mini` and clamps generation length before calling Genkit. The flow
passes Genkit's `maxOutputTokens` to preserve the framework-level intent and
OpenAI's `max_completion_tokens` passthrough field so the installed
compatibility adapter sends the same server-owned cap to Chat Completions.
