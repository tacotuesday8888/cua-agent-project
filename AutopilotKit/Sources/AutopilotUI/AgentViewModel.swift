import AutopilotAgent
import AutopilotCore
import AutopilotLLM
import AutopilotMac
import Foundation
import Observation

/// The state and logic behind the notch UI.
///
/// `AgentViewModel` assembles and runs an `AgentSession`, streams its events
/// into a display feed, and bridges the agent's confirmation requests to the
/// UI by conforming to `UserInteraction`.
@MainActor
@Observable
public final class AgentViewModel: UserInteraction {
    /// The high-level state of the notch UI.
    public enum Phase: Sendable, Equatable {
        case idle
        case running
        case finished(String)
        case failed(String)
    }

    /// One line in the live status feed.
    public struct FeedItem: Identifiable, Sendable {
        public let id = UUID()
        public let text: String
        public let isError: Bool
    }

    /// A risky action awaiting the user's approval.
    public struct PendingApproval: Sendable {
        public let summary: String
    }

    // MARK: - Observable state

    /// The free-text prompt the user is typing.
    public var promptText: String = ""
    /// The app pinned via the `@app` picker, if any.
    public var pinnedApp: AppLocator.RunningApp?
    /// The high-level run state.
    public var phase: Phase = .idle
    /// The live status feed shown in the expanded notch.
    public var feed: [FeedItem] = []
    /// A risky action awaiting approval, or `nil`.
    public var pendingApproval: PendingApproval?
    /// Whether the notch is expanded to its full panel.
    public var isExpanded: Bool = false
    /// The Anthropic API key (bring-your-own in v1).
    public var apiKey: String

    // MARK: - Private

    private static let apiKeyDefaultsKey = "AutopilotAnthropicAPIKey"
    private static let model = "claude-sonnet-4-6"

    private let locator = AppLocator()
    private var runTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    public init() {
        self.apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey) ?? ""
    }

    // MARK: - Actions

    /// Run the current prompt as an agent task.
    public func submit() {
        let task = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, phase != .running else { return }
        guard !apiKey.isEmpty else {
            phase = .failed("Add your Anthropic API key to get started.")
            return
        }
        guard let target = pinnedApp ?? locator.frontmostApp() else {
            phase = .failed("Open the app you want me to use, then try again.")
            return
        }
        UserDefaults.standard.set(apiKey, forKey: Self.apiKeyDefaultsKey)

        feed = []
        phase = .running

        let session = AgentSession(
            llm: AnthropicProvider(apiKey: apiKey),
            computer: MacComputer(
                pid: target.processID,
                appName: target.name,
                bundleIdentifier: target.bundleIdentifier
            ),
            interaction: self,
            configuration: AgentConfiguration(model: Self.model),
            eventHandler: { [weak self] event in
                Task { @MainActor in self?.ingest(event) }
            }
        )

        runTask = Task { @MainActor [weak self] in
            let outcome = await session.run(task: task)
            self?.finish(with: outcome)
        }
    }

    /// Stop a running task.
    public func stop() {
        runTask?.cancel()
        if let continuation = approvalContinuation {
            approvalContinuation = nil
            pendingApproval = nil
            continuation.resume(returning: false)
        }
    }

    /// Answer a pending risky-action confirmation.
    public func resolveApproval(_ approved: Bool) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        pendingApproval = nil
        continuation.resume(returning: approved)
    }

    /// Toggle between the compact and expanded notch.
    public func toggleExpanded() {
        isExpanded.toggle()
    }

    // MARK: - UserInteraction

    public func confirmRiskyAction(summary: String) async -> Bool {
        await withCheckedContinuation { continuation in
            self.pendingApproval = PendingApproval(summary: summary)
            self.approvalContinuation = continuation
        }
    }

    public func askQuestion(_ question: String) async -> String {
        // v1 surfaces questions in the feed; a richer Q&A UI comes later.
        ""
    }

    // MARK: - Agent events

    private func ingest(_ event: AgentEvent) {
        switch event {
        case .started:
            append("Starting…")
        case .thinking:
            break
        case .observedTree(let count):
            append("Read the screen (\(count) elements)")
        case .message(let text):
            append(text)
        case .willPerform(_, let summary, _):
            append(summary)
        case .awaitingConfirmation(let summary):
            append("Needs approval: \(summary)")
        case .confirmationDenied(let summary):
            append("Skipped: \(summary)", isError: true)
        case .performed(_, let summary):
            append("Done: \(summary)")
        case .askedUser(let question, _):
            append("Asked: \(question)")
        case .finished(let summary):
            append("Finished — \(summary)")
        case .failed(let reason):
            append(reason, isError: true)
        case .stopped:
            append("Stopped.", isError: true)
        }
    }

    private func finish(with outcome: AgentOutcome) {
        switch outcome.status {
        case .completed: phase = .finished(outcome.summary)
        case .stopped: phase = .failed("Stopped.")
        case .failed: phase = .failed(outcome.summary)
        }
        runTask = nil
    }

    private func append(_ text: String, isError: Bool = false) {
        feed.append(FeedItem(text: text, isError: isError))
    }
}
