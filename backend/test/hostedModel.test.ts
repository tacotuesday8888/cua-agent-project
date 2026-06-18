import { describe, it, expect } from 'vitest';
import {
  HOSTED_BASIC_MODEL,
  HOSTED_BASIC_POLICY,
  hostedBasicGenerationConfig,
  resolveHostedMaxOutputTokens,
  resolveHostedModel,
} from '../src/hostedModel.js';

describe('hosted model policy', () => {
  it('describes the Mac Autopilot Basic server-side policy in one place', () => {
    expect(HOSTED_BASIC_POLICY.productName).toBe('Mac Autopilot Basic');
    expect(HOSTED_BASIC_POLICY.model).toBe('gemini-3.5-flash');
    expect(HOSTED_BASIC_POLICY.maxOutputTokens).toBe(4096);
    expect(HOSTED_BASIC_POLICY.monthlyRequestCap).toBe(1000);
    expect(HOSTED_BASIC_POLICY.pricingUsdPerMillionTokens).toEqual({ input: 1.5, output: 9.0 });
  });

  it('uses Gemini 3.5 Flash for Mac Autopilot Basic', () => {
    expect(HOSTED_BASIC_MODEL).toBe('gemini-3.5-flash');
    expect(resolveHostedModel('gemini-3.5-flash')).toBe('gemini-3.5-flash');
  });

  it('maps legacy hosted automatic selections to the Basic model', () => {
    expect(resolveHostedModel('automatic')).toBe(HOSTED_BASIC_MODEL);
    expect(resolveHostedModel('gpt-5.4-mini')).toBe(HOSTED_BASIC_MODEL);
    expect(resolveHostedModel('gpt-5.4')).toBe(HOSTED_BASIC_MODEL);
  });

  it('rejects arbitrary hosted model ids to keep the service cost bounded', () => {
    expect(() => resolveHostedModel('gpt-5.5')).toThrow(/Mac Autopilot Basic/);
  });

  it('clamps requested output tokens to the Basic policy cap', () => {
    expect(resolveHostedMaxOutputTokens()).toBe(4096);
    expect(resolveHostedMaxOutputTokens(256)).toBe(256);
    expect(resolveHostedMaxOutputTokens(999_999)).toBe(4096);
    expect(resolveHostedMaxOutputTokens(0)).toBe(1);
    expect(resolveHostedMaxOutputTokens(32.8)).toBe(32);
  });

  it('emits Vertex/Gemini generation config for the Basic cap', () => {
    expect(hostedBasicGenerationConfig(999_999)).toEqual({
      maxOutputTokens: 4096,
    });
  });
});
