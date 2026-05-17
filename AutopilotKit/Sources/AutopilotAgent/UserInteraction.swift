/// How the agent reaches the user for confirmations and clarifying questions.
///
/// The production implementation is backed by the notch UI; tests use
/// `AutomaticApproval`.
public protocol UserInteraction: Sendable {
    /// Ask the user to approve a risky action. Return `true` to proceed.
    func confirmRiskyAction(summary: String) async -> Bool

    /// Ask the user a clarifying question and return their answer.
    func askQuestion(_ question: String) async -> String
}

/// A non-interactive `UserInteraction` for tests and headless runs: it approves
/// every risky action and answers questions with a fixed string.
public struct AutomaticApproval: UserInteraction {
    private let cannedAnswer: String

    public init(answer: String = "") {
        self.cannedAnswer = answer
    }

    public func confirmRiskyAction(summary: String) async -> Bool { true }
    public func askQuestion(_ question: String) async -> String { cannedAnswer }
}
