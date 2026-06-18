import { onCallGenkit } from 'firebase-functions/https';
import { initializeApp } from 'firebase-admin/app';
import { llmProxyFlow } from './flow.js';

initializeApp();

/**
 * The hosted LLM proxy. `onCallGenkit` enforces the auth policy before running
 * the flow, so an unauthenticated caller can never reach the model. Mac
 * Autopilot Basic uses Vertex AI via the function service account/ADC, so there
 * is no provider API key mounted into the function.
 */
export const llmProxy = onCallGenkit(
  {
    authPolicy: (auth) => !!auth?.uid,
  },
  llmProxyFlow
);
