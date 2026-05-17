import AutopilotCore

/// An observable event emitted during an agent run, for the live status feed.
public enum AgentEvent: Sendable {
    /// The run started for the given task.
    case started(task: String)
    /// The driver completed its readiness checks.
    case diagnostics(ComputerDiagnostics)
    /// The agent is waiting on the model.
    case thinking
    /// The agent observed the UI tree (with its element count).
    case observedTree(elementCount: Int)
    /// The model produced a text message.
    case message(String)
    /// The agent is about to perform an action.
    case willPerform(tool: AgentTool, summary: String, risk: RiskLevel)
    /// A risky action is waiting for user approval.
    case awaitingConfirmation(summary: String)
    /// The user declined a risky action.
    case confirmationDenied(summary: String)
    /// An action completed.
    case performed(tool: AgentTool, summary: String)
    /// The agent asked the user a question and received an answer.
    case askedUser(question: String, answer: String)
    /// The run finished successfully.
    case finished(summary: String)
    /// The run failed.
    case failed(reason: String)
    /// The run was stopped by the user.
    case stopped
}
