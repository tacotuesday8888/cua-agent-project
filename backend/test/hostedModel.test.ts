import { describe, it, expect } from 'vitest';
import { HOSTED_BASIC_MODEL, resolveHostedModel } from '../src/hostedModel.js';

describe('hosted model policy', () => {
  it('uses gpt-5.4-mini for Mac Autopilot Basic', () => {
    expect(HOSTED_BASIC_MODEL).toBe('gpt-5.4-mini');
    expect(resolveHostedModel('gpt-5.4-mini')).toBe('gpt-5.4-mini');
  });

  it('maps legacy hosted automatic selections to the Basic model', () => {
    expect(resolveHostedModel('automatic')).toBe(HOSTED_BASIC_MODEL);
    expect(resolveHostedModel('gpt-5.4')).toBe(HOSTED_BASIC_MODEL);
  });

  it('rejects arbitrary hosted model ids to keep the service cost bounded', () => {
    expect(() => resolveHostedModel('gpt-5.5')).toThrow(/Mac Autopilot Basic/);
  });
});
