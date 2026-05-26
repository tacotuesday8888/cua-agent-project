# MacAutopilot backend — hosted LLM proxy

A thin, authenticated **LLM proxy** for Mac Autopilot's *hosted* AI path. The
macOS agent stays on-device; only the model call moves server-side so provider
keys never live in the client and usage can be metered.

- **Runtime:** Firebase Cloud Functions (2nd gen), Node 22.
- **Orchestration:** Genkit — one flow (`llmProxyFlow`) wrapped in `onCallGenkit`.
- **Model:** OpenAI GPT‑5.4 Mini via `@genkit-ai/compat-oai` (provider-agnostic;
  the client sends a logical model id).
- **Auth:** the `onCallGenkit` auth policy requires a signed-in Firebase user, so
  an unauthenticated caller can never reach the model or the key.
- **Tools:** the model **returns** tool calls (`returnToolRequests: true`) for the
  on-device agent to execute — it never runs tools here.
- **Privacy:** only usage **metadata** (uid, model, token counts, cost, latency,
  status) is stored — never prompts, responses, or screen content.

This is opt-in. The app's default remains BYOK (the user's own key, local-only).

## Layout

- `src/index.ts` — the `llmProxy` callable function (`onCallGenkit`, secret, auth).
- `src/flow.ts` — the Genkit flow: quota check → `ai.generate` → usage record.
- `src/translate.ts` — neutral request/response ⇆ Genkit (pure, unit-tested).
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
