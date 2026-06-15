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
/// History is deliberately metadata-only: target app, model, status, token
/// counts, timestamps, ordered tool names, and redacted display labels.
/// Accessibility trees, screenshots, raw prompts, provider messages,
/// clarifying-question answers, typed values, and memory contents are never
/// stored — they can carry private user data.
public struct RunRecord: Sendable, Hashable, Codable, Identifiable {
    /// Stable identifier, assigned on creation.
    public let id: UUID
    /// A redacted display label, never the raw prompt.
    public let task: String
    /// The app the agent operated.
    public let appName: String
    /// The model identifier that drove the run.
    public let model: String
    /// How the run ended.
    public let status: RunStatus
    /// A redacted status label, never provider/model response text.
    public let summary: String
    /// Ordered raw tool names performed during the run — high-level actions
    /// only, carrying no element labels or typed values.
    public let actions: [String]
    /// Total input tokens the run's LLM calls consumed.
    public let inputTokens: Int
    /// Total output tokens the run's LLM calls produced.
    public let outputTokens: Int
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
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.id = id
        self.task = Self.redactedTaskLabel(appName: appName)
        self.appName = appName
        self.model = model
        self.status = status
        self.summary = Self.redactedSummary(for: status)
        self.actions = actions
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        appName = try container.decode(String.self, forKey: .appName)
        model = try container.decode(String.self, forKey: .model)
        status = try container.decode(RunStatus.self, forKey: .status)
        task = Self.redactedTaskLabel(appName: appName)
        summary = Self.redactedSummary(for: status)
        actions = try container.decodeIfPresent([String].self, forKey: .actions) ?? []
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(task, forKey: .task)
        try container.encode(appName, forKey: .appName)
        try container.encode(model, forKey: .model)
        try container.encode(status, forKey: .status)
        try container.encode(summary, forKey: .summary)
        try container.encode(actions, forKey: .actions)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(finishedAt, forKey: .finishedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case task
        case appName
        case model
        case status
        case summary
        case actions
        case inputTokens
        case outputTokens
        case startedAt
        case finishedAt
    }

    private static func redactedTaskLabel(appName: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return app.isEmpty ? "Run" : "Run in \(app)"
    }

    private static func redactedSummary(for status: RunStatus) -> String {
        switch status {
        case .completed: "Completed"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    /// How many actions the agent performed during the run.
    public var actionCount: Int { actions.count }

    /// Total tokens (input + output) the run consumed.
    public var totalTokens: Int { inputTokens + outputTokens }

    /// A compact human label for total token usage, e.g. "8.2k".
    public var compactTokens: String {
        totalTokens < 1000
            ? "\(totalTokens)"
            : String(format: "%.1fk", Double(totalTokens) / 1000)
    }

    /// How long the run took.
    public var duration: TimeInterval {
        max(0, finishedAt.timeIntervalSince(startedAt))
    }
}
