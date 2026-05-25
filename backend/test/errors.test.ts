import { describe, it, expect } from 'vitest';
import { statusFromError, normalizeProviderError, ProxyError } from '../src/errors.js';

describe('statusFromError', () => {
  it('reads status from common error shapes', () => {
    expect(statusFromError({ status: 429 })).toBe(429);
    expect(statusFromError({ statusCode: 503 })).toBe(503);
    expect(statusFromError({ cause: { status: 401 } })).toBe(401);
    expect(statusFromError(new Error('Request failed with status 500'))).toBe(500);
    expect(statusFromError(new Error('no status here'))).toBeUndefined();
  });
});

describe('normalizeProviderError', () => {
  it('maps provider auth failures to a generic internal error, not an API-key message', () => {
    const e = normalizeProviderError({ status: 401 });
    expect(e).toBeInstanceOf(ProxyError);
    expect(e.code).toBe('internal');
    expect(e.message).not.toMatch(/api key/i);
  });

  it('maps 429 to resource-exhausted and 5xx to unavailable', () => {
    expect(normalizeProviderError({ status: 429 }).code).toBe('resource-exhausted');
    expect(normalizeProviderError({ status: 502 }).code).toBe('unavailable');
  });

  it('defaults unknown errors to internal', () => {
    expect(normalizeProviderError(new Error('weird')).code).toBe('internal');
  });
});
