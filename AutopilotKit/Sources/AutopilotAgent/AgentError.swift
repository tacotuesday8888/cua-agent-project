/// Errors raised while performing a computer action.
public enum AgentError: Error, Sendable, Equatable {
    /// A computer action failed (e.g. the target element no longer exists).
    case computer(String)
    /// A tool was called with missing or invalid input.
    case invalidToolInput(tool: String, detail: String)
}
