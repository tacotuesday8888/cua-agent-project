# MacAutopilot backend — hosted LLM proxy

A thin, authenticated **LLM proxy** for Mac Autopilot's *hosted* AI path. The
macOS agent stays on-device; only the model call moves server-side so provider
keys never live in the client and usage can be metered.

- **Runtime:** Firebase Cloud Functions (2nd gen), Node 22.
- **Orchestration:** Genkit — one flow (`llmProxyFlow`) wrapped in `onCallGenkit`.
- **Basic policy:** the backend owns the Mac Autopilot Basic plan: it resolves
  hosted requests to Vertex AI Gemini 3.5 Flash (`gemini-3.5-flash`), accepts
  `automatic` plus old hosted GPT ids as rollout aliases, clamps
  client-requested output tokens to 4096, applies a 1000-request monthly cap,
  and uses the Basic pricing label for usage metadata.
- **Auth:** the `onCallGenkit` auth policy requires a signed-in Firebase user, so
  an unauthenticated caller can never reach the model.
- **Tools:** the model **returns** tool calls (`returnToolRequests: true`) for the
  on-device agent to execute — it never runs tools here.
- **Privacy:** only usage **metadata** (uid, model, token counts, cost, latency,
  status) is stored — never prompts, responses, or screen content.

This is the app's default simple path, branded **Mac Autopilot Basic**. BYOK
remains available in the Mac app for users who want their own provider key or
OpenAI-compatible endpoint.

## Layout

- `src/index.ts` — the `llmProxy` callable function (`onCallGenkit`, auth).
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
npm run test:rules:emulator # Firebase emulator proof that direct client rules deny all
```

For a live end-to-end run you need a Firebase project with Vertex AI enabled and
the function service account allowed to call Vertex AI, then `npx genkit start`
or the Firebase emulators.

The rules emulator test starts Firestore, Realtime Database, and Storage
emulators through the Firebase CLI and requires Java. It exercises Firebase
client SDK contexts, not Admin SDK bypasses, so it proves public clients cannot
directly read or write Firestore, Realtime Database, or Storage.

> Note: if `npm install` fails with an `EACCES`/root-owned cache error on a shared
> machine, point npm at a fresh cache: `npm install --cache /tmp/npm-cache`.

## Deploy (user-side, one-time)

1. In your Firebase/Google Cloud project, enable **Authentication** (Google
   provider), **Firestore**, **Functions**, and the **Vertex AI / Gemini
   Enterprise Agent Platform API**.
2. Grant the Cloud Functions runtime service account the least-privilege Vertex
   role needed to call Gemini models, such as Vertex AI User. The backend uses
   the global Vertex endpoint by default; set `VERTEX_AI_LOCATION` or
   `GCLOUD_LOCATION` in the deployed runtime only if you intentionally need a
   regional endpoint.
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
`gemini-3.5-flash` and clamps generation length before calling Genkit. The flow
passes Genkit's `maxOutputTokens` to the Vertex AI Gemini adapter so the
server-owned cap is enforced independently of the client.
