import Foundation

/// Errors raised while performing a computer action.
public enum AgentError: Error, Sendable, Equatable {
    /// A computer action failed (e.g. the target element no longer exists).
    case computer(String)
    /// A tool was called with missing or invalid input.
    case invalidToolInput(tool: String, detail: String)
}

extension AgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .computer(let message):
            return message
        case .invalidToolInput(let tool, let detail):
            return "Invalid input for \(tool): \(detail)."
        }
    }
}
