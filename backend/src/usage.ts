import type { ProxyUsage } from './types.js';
import { HOSTED_BASIC_POLICY } from './hostedModel.js';

/// Pure usage accounting — builds the metadata-only record we persist (never any
/// prompt/response content) and estimates cost. Kept Firestore-free for testing.

/** USD per 1M tokens, by model. Extend as providers/models are added. */
const PRICE_PER_MTOK: Record<string, { input: number; output: number }> = {
  [HOSTED_BASIC_POLICY.model]: HOSTED_BASIC_POLICY.pricingUsdPerMillionTokens,
};

/// Tracks which unknown models we've already warned about, so adding a new
/// model never silently goes uncosted but we don't spam the logs either.
const warnedUnknownModels = new Set<string>();

export function estimateCostUsd(model: string, usage: ProxyUsage): number {
  const price = PRICE_PER_MTOK[model];
  if (!price) {
    if (!warnedUnknownModels.has(model)) {
      warnedUnknownModels.add(model);
      console.warn(
        `[usage] unknown model "${model}" — cost reported as 0; add it to PRICE_PER_MTOK`
      );
    }
    return 0;
  }
  const cost =
    (usage.inputTokens / 1_000_000) * price.input +
    (usage.outputTokens / 1_000_000) * price.output;
  // Round to 6 decimals to avoid float noise in stored records.
  return Math.round(cost * 1_000_000) / 1_000_000;
}

export interface UsageRecord {
  uid: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  costUsd: number;
  latencyMs: number;
  status: 'ok' | 'error';
  at: string; // ISO timestamp
}

export function buildUsageRecord(params: {
  uid: string;
  model: string;
  usage: ProxyUsage;
  latencyMs: number;
  status: 'ok' | 'error';
  at?: Date;
}): UsageRecord {
  const at = params.at ?? new Date();
  return {
    uid: params.uid,
    model: params.model,
    inputTokens: params.usage.inputTokens,
    outputTokens: params.usage.outputTokens,
    costUsd: estimateCostUsd(params.model, params.usage),
    latencyMs: params.latencyMs,
    status: params.status,
    at: at.toISOString(),
  };
}
