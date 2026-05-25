import { onCallGenkit } from 'firebase-functions/https';
import { defineSecret } from 'firebase-functions/params';
import { initializeApp } from 'firebase-admin/app';
import { llmProxyFlow } from './flow.js';

initializeApp();

// The OpenAI key lives in Cloud Secret Manager, never in source. It is exposed to
// the function as process.env.OPENAI_API_KEY at runtime, where the Genkit OpenAI
// plugin reads it.
const openaiKey = defineSecret('OPENAI_API_KEY');

/**
 * The hosted LLM proxy. `onCallGenkit` enforces the auth policy before running
 * the flow, so an unauthenticated caller can never reach the model (or the key).
 */
export const llmProxy = onCallGenkit(
  {
    secrets: [openaiKey],
    authPolicy: (auth) => !!auth?.uid,
  },
  llmProxyFlow
);
