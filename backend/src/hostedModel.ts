import { HttpsError } from 'firebase-functions/https';

export const HOSTED_BASIC_POLICY = {
  productName: 'Mac Autopilot Basic',
  model: 'gemini-3.5-flash',
  aliases: ['automatic', 'gpt-5.4-mini', 'gpt-5.4'],
  maxOutputTokens: 4096,
  monthlyRequestCap: 1000,
  pricingUsdPerMillionTokens: { input: 1.5, output: 9.0 },
} as const;

export const HOSTED_BASIC_MODEL = HOSTED_BASIC_POLICY.model;

const LEGACY_HOSTED_MODEL_ALIASES = new Set<string>(HOSTED_BASIC_POLICY.aliases);

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

export function resolveHostedMaxOutputTokens(requestedMaxTokens?: number): number {
  if (requestedMaxTokens === undefined) {
    return HOSTED_BASIC_POLICY.maxOutputTokens;
  }

  const wholeTokens = Math.trunc(requestedMaxTokens);
  return Math.min(Math.max(wholeTokens, 1), HOSTED_BASIC_POLICY.maxOutputTokens);
}

export interface HostedBasicGenerationConfig {
  maxOutputTokens: number;
}

export function hostedBasicGenerationConfig(
  requestedMaxTokens?: number
): HostedBasicGenerationConfig {
  const maxOutputTokens = resolveHostedMaxOutputTokens(requestedMaxTokens);
  return {
    maxOutputTokens,
  };
}
