import Foundation

/// How a recorded run ended.
///
/// Mirrors the agent's terminal outcome states so a history entry reads the
/// same as the run feed that produced it.
public enum RunStatus: String, Sendable, Hashable, Codable {
    /// The task finished with a summary.
    case completed
    /// The user stopped the run with the kill switch.
    case stopped
    /// The run was blocked, errored, or hit a limit.
    case failed
}

/// One redacted record of a finished agent run.
///
/// History is deliberately metadata-only: the task, target app, model, status,
/// a short summary, and the ordered tool names that ran. Accessibility trees,
/// screenshots, provider messages, clarifying-question answers, and memory
/// contents are never stored — they can carry private user data.
public struct RunRecord: Sendable, Hashable, Codable, Identifiable {
    /// Stable identifier, assigned on creation.
    public let id: UUID
    /// The natural-language task the user gave the agent.
    public let task: String
    /// The app the agent operated.
    public let appName: String
    /// The model identifier that drove the run.
    public let model: String
    /// How the run ended.
    public let status: RunStatus
    /// The final outcome summary shown to the user.
    public let summary: String
    /// Ordered raw tool names performed during the run — high-level actions
    /// only, carrying no element labels or typed values.
    public let actions: [String]
    /// When the run started.
    public let startedAt: Date
    /// When the run ended.
    public let finishedAt: Date

    public init(
        id: UUID = UUID(),
        task: String,
        appName: String,
        model: String,
        status: RunStatus,
        summary: String,
        actions: [String] = [],
        startedAt: Date,
        finishedAt: Date
    ) {
        self.id = id
        self.task = task
        self.appName = appName
        self.model = model
        self.status = status
        self.summary = summary
        self.actions = actions
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// How many actions the agent performed during the run.
    public var actionCount: Int { actions.count }

    /// How long the run took.
    public var duration: TimeInterval {
        max(0, finishedAt.timeIntervalSince(startedAt))
    }
}
