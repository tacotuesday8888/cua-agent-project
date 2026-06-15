import { HttpsError } from 'firebase-functions/https';

export const HOSTED_BASIC_MODEL = 'gpt-5.4-mini';

const LEGACY_HOSTED_MODEL_ALIASES = new Set(['automatic', 'gpt-5.4']);

export function resolveHostedModel(requestedModel: string): string {
  const model = requestedModel.trim();
  if (model === HOSTED_BASIC_MODEL || LEGACY_HOSTED_MODEL_ALIASES.has(model)) {
    return HOSTED_BASIC_MODEL;
  }
  throw new HttpsError(
    'invalid-argument',
    `Mac Autopilot Basic currently runs ${HOSTED_BASIC_MODEL}.`
  );
}
