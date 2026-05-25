/// Pure error classification — kept free of firebase-functions so it can be unit
/// tested. `code` values are valid Firebase callable error codes; the wiring
/// layer converts a `ProxyError` to an `HttpsError`.

export type ProxyErrorCode =
  | 'unauthenticated'
  | 'invalid-argument'
  | 'resource-exhausted'
  | 'unavailable'
  | 'internal';

export class ProxyError extends Error {
  readonly code: ProxyErrorCode;
  constructor(code: ProxyErrorCode, message: string) {
    super(message);
    this.name = 'ProxyError';
    this.code = code;
  }
}

/** Best-effort HTTP status pulled from an unknown thrown error. */
export function statusFromError(err: unknown): number | undefined {
  const e = err as
    | { status?: unknown; statusCode?: unknown; cause?: { status?: unknown }; message?: unknown }
    | undefined;
  const direct = e?.status ?? e?.statusCode ?? e?.cause?.status;
  if (typeof direct === 'number') return direct;
  // Fall back to scanning the message for a 3-digit HTTP status.
  if (typeof e?.message === 'string') {
    const match = e.message.match(/\b(4\d\d|5\d\d)\b/);
    if (match) return Number(match[1]);
  }
  return undefined;
}

/**
 * Map an error from the model/provider call into a `ProxyError` with a
 * user-appropriate code and message — never leaking the provider's raw body.
 */
export function normalizeProviderError(err: unknown): ProxyError {
  const status = statusFromError(err);
  if (status === 401 || status === 403) {
    // The server key is misconfigured/expired — the user's fault to fix it isn't,
    // so surface a generic service error, not an auth prompt.
    return new ProxyError('internal', 'The AI service is temporarily unavailable.');
  }
  if (status === 429) {
    return new ProxyError('resource-exhausted', 'The AI service is busy. Please try again shortly.');
  }
  if (status !== undefined && status >= 500) {
    return new ProxyError('unavailable', 'The AI service is temporarily unavailable.');
  }
  return new ProxyError('internal', 'The AI request could not be completed.');
}
