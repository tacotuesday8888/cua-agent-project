import { describe, it, expect } from 'vitest';
import { monthKey, isOverCap, DEFAULT_MONTHLY_REQUEST_CAP } from '../src/quota.js';

describe('quota', () => {
  it('formats monthKey as YYYY-MM in UTC', () => {
    expect(monthKey(new Date('2026-05-25T02:00:00Z'))).toBe('2026-05');
    expect(monthKey(new Date('2026-12-01T00:00:00Z'))).toBe('2026-12');
  });

  it('is over cap only at or beyond the limit', () => {
    expect(isOverCap(0, 1000)).toBe(false);
    expect(isOverCap(999, 1000)).toBe(false);
    expect(isOverCap(1000, 1000)).toBe(true);
    expect(isOverCap(1001, 1000)).toBe(true);
  });

  it('defaults to the free-tier cap', () => {
    expect(isOverCap(DEFAULT_MONTHLY_REQUEST_CAP)).toBe(true);
    expect(isOverCap(DEFAULT_MONTHLY_REQUEST_CAP - 1)).toBe(false);
  });
});
