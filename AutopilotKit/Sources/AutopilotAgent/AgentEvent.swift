import AutopilotCore
import AutopilotMemory

/// An observable event emitted during an agent run, for the live status feed.
public enum AgentEvent: Sendable {
    /// The run started for the given task.
    case started(task: String)
    /// The driver brought the target app forward before the run.
    case prepared(summary: String)
    /// The driver completed its readiness checks.
    case diagnostics(ComputerDiagnostics)
    /// The agent is waiting on the model.
    case thinking
    /// The agent observed the UI tree (with its element count).
    case observedTree(elementCount: Int)
    /// Cumulative provider token usage so far in the run.
    case tokenUsage(inputTokens: Int, outputTokens: Int)
    /// The model produced a text message.
    case message(String)
    /// Memory relevant to this task was recalled into the agent's context.
    case memoryRecalled([MemoryItem])
    /// The agent is about to act — surfaces the target before the click or
    /// keystroke fires, so the UI can highlight the real element.
    case willPerform(tool: AgentTool, target: ActionTarget, tier: RiskLevel)
    /// A gated action is waiting for the user's approval.
    case awaitingConfirmation(ApprovalRequest)
    /// The user declined a gated action.
    case confirmationDenied(summary: String)
    /// An action completed.
    case performed(tool: AgentTool, summary: String)
    /// An action failed; carries the failed tool and a recovery-oriented reason.
    case actionFailed(tool: AgentTool, reason: String)
    /// The agent asked the user a question and received an answer.
    case askedUser(question: String, answer: String)
    /// The agent proposed saving a memory.
    case memoryProposed(MemoryProposal)
    /// A memory was saved to the local store.
    case memoryStored(MemoryItem)
    /// A local persistence operation failed, but the run can continue.
    case storageFailed(String)
    /// The run finished successfully.
    case finished(summary: String)
    /// The run failed.
    case failed(reason: String)
    /// The run was stopped by the user.
    case stopped
}
