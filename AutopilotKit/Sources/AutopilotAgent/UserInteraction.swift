import AutopilotMemory

/// How the agent reaches the user for approvals, clarifying questions, and
/// memory suggestions.
///
/// The production implementation is backed by the notch UI; tests use
/// `AutomaticApproval`.
public protocol UserInteraction: Sendable {
    /// Ask the user to approve a gated action. Return `true` to proceed.
    func requestApproval(_ request: ApprovalRequest) async -> Bool

    /// Ask the user a clarifying question and return their answer.
    func askQuestion(_ question: String) async -> String

    /// Ask the user whether to save a memory the agent proposed. Return `true`
    /// to store it.
    func confirmMemory(_ proposal: MemoryProposal) async -> Bool
}

/// A non-interactive `UserInteraction` for tests and headless runs: it approves
/// every gated action and answers questions with a fixed string.
///
/// It declines proposed memories by default, so a headless run never silently
/// writes to memory; pass `approvesMemory: true` to opt in.
public struct AutomaticApproval: UserInteraction {
    private let cannedAnswer: String
    private let approvesMemory: Bool

    public init(answer: String = "", approvesMemory: Bool = false) {
        self.cannedAnswer = answer
        self.approvesMemory = approvesMemory
    }

    public func requestApproval(_ request: ApprovalRequest) async -> Bool { true }
    public func askQuestion(_ question: String) async -> String { cannedAnswer }
    public func confirmMemory(_ proposal: MemoryProposal) async -> Bool { approvesMemory }
}
