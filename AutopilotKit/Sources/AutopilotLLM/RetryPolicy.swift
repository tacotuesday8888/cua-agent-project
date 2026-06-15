import Foundation

/// Retry behavior for transient LLM provider failures, shared by every
/// `LLMProvider`.
///
/// Network blips, rate limits, and 5xx responses are retried with exponential
/// backoff; client errors, decoding failures, and a missing API key are not,
/// since retrying them cannot help.
public struct RetryPolicy: Sendable, Equatable {
    /// Number of retries after the first attempt.
    public let maxRetries: Int
    /// First retry delay, in seconds, before exponential backoff is applied.
    public let baseDelaySeconds: Double
    /// Maximum retry delay, in seconds.
    public let maxDelaySeconds: Double

    /// Two retries with 1s → 2s backoff, capped at 5s.
    public static let standard = RetryPolicy()
    /// No retries — a single attempt only.
    public static let disabled = RetryPolicy(
        maxRetries: 0,
        baseDelaySeconds: 0,
        maxDelaySeconds: 0
    )

    public init(
        maxRetries: Int = 2,
        baseDelaySeconds: Double = 1,
        maxDelaySeconds: Double = 5
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelaySeconds = max(0, baseDelaySeconds)
        self.maxDelaySeconds = max(0, maxDelaySeconds)
    }

    /// Run `operation`, retrying transient `LLMError`s with backoff until it
    /// succeeds or the retry budget is exhausted.
    func run(
        _ operation: () async throws -> LLMResponse
    ) async throws -> LLMResponse {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let error as LLMError where shouldRetry(error, attempt: attempt) {
                let delay = delaySeconds(for: error, attempt: attempt)
                attempt += 1
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    /// Whether `error` is worth another attempt within the retry budget.
    private func shouldRetry(_ error: LLMError, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }
        switch error {
        case .network, .rateLimited:
            return true
        case .http(let status, _):
            return [500, 502, 503, 504].contains(status)
        case .missingAPIKey, .authenticationFailed, .accountAuthenticationFailed,
             .decodingFailed, .invalidResponse, .service:
            return false
        }
    }

    /// The backoff delay before the next attempt, honoring a `retry-after`
    /// hint when the provider sent one.
    private func delaySeconds(for error: LLMError, attempt: Int) -> Double {
        if case .rateLimited(let retryAfter) = error, let retryAfter, retryAfter > 0 {
            return min(retryAfter, maxDelaySeconds)
        }
        guard baseDelaySeconds > 0 else { return 0 }
        return min(baseDelaySeconds * pow(2, Double(attempt)), maxDelaySeconds)
    }
}
