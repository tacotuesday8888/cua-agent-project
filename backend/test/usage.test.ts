import { describe, it, expect } from 'vitest';
import { estimateCostUsd, buildUsageRecord } from '../src/usage.js';

describe('usage', () => {
  it('estimates Mac Autopilot Basic Gemini 3.5 Flash cost from token counts', () => {
    // 1M input @ $1.50 + 1M output @ $9.00 = $10.50.
    expect(
      estimateCostUsd('gemini-3.5-flash', { inputTokens: 1_000_000, outputTokens: 1_000_000 })
    ).toBeCloseTo(10.5, 6);
    expect(estimateCostUsd('gemini-3.5-flash', { inputTokens: 0, outputTokens: 0 })).toBe(0);
  });

  it('returns 0 for unknown models', () => {
    expect(estimateCostUsd('mystery-model', { inputTokens: 1000, outputTokens: 1000 })).toBe(0);
  });

  it('builds a metadata-only usage record (no prompt/response content)', () => {
    const at = new Date('2026-05-25T00:00:00Z');
    const rec = buildUsageRecord({
      uid: 'u1',
      model: 'gemini-3.5-flash',
      usage: { inputTokens: 100, outputTokens: 50 },
      latencyMs: 1234,
      status: 'ok',
      at,
    });
    expect(rec).toEqual({
      uid: 'u1',
      model: 'gemini-3.5-flash',
      inputTokens: 100,
      outputTokens: 50,
      costUsd: estimateCostUsd('gemini-3.5-flash', { inputTokens: 100, outputTokens: 50 }),
      latencyMs: 1234,
      status: 'ok',
      at: '2026-05-25T00:00:00.000Z',
    });
    // No message/prompt/response fields are ever stored.
    expect(Object.keys(rec).sort()).toEqual(
      ['at', 'costUsd', 'inputTokens', 'latencyMs', 'model', 'outputTokens', 'status', 'uid']
    );
  });
});
