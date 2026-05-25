import Foundation

/// Errors surfaced by an `LLMProvider`.
public enum LLMError: Error, Sendable, Equatable {
    /// No API key was configured for the provider.
    case missingAPIKey
    /// The provider rejected the API key (HTTP 401) — invalid or expired.
    case authenticationFailed(provider: String)
    /// The provider returned a non-success HTTP status.
    case http(status: Int, body: String)
    /// The provider rate-limited the request.
    case rateLimited(retryAfter: Double?)
    /// A request or response could not be encoded/decoded.
    case decodingFailed(String)
    /// A networking error occurred.
    case network(String)
    /// The provider returned a structurally invalid response.
    case invalidResponse(String)
    /// The hosted backend returned a handled error (auth, quota, availability)
    /// whose message is already user-facing.
    case service(message: String)
}

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key is configured for the LLM provider."
        case .authenticationFailed(let provider):
            return "The saved \(provider) API key is invalid or expired. Update the API key and run again."
        case .http(let status, let body):
            return "The LLM provider returned HTTP \(status): \(body)"
        case .rateLimited:
            return "The LLM provider rate-limited the request."
        case .decodingFailed(let detail):
            return "Failed to encode/decode an LLM payload: \(detail)"
        case .network(let detail):
            return "Network error contacting the LLM provider: \(detail)"
        case .invalidResponse(let detail):
            return "The LLM returned an invalid response: \(detail)"
        case .service(let message):
            return message
        }
    }
}
