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

    /// Supported LLM backends for the test harness.
    public enum Provider: String, CaseIterable, Identifiable, Sendable {
        case zai
        case anthropic

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .zai: "Z.ai GLM-4.7-Flash"
            case .anthropic: "Anthropic Claude"
            }
        }

        var model: String {
            switch self {
            case .zai: "glm-4.7-flash"
            case .anthropic: "claude-sonnet-4-6"
            }
        }

        var apiKeyPlaceholder: String {
            switch self {
            case .zai: "Z.ai API key"
            case .anthropic: "Anthropic API key"
            }
        }

        var apiKeyDefaultsKey: String {
            switch self {
            case .zai: "AutopilotZAIAPIKey"
            case .anthropic: "AutopilotAnthropicAPIKey"
            }
        }
    }

    // MARK: - Observable state

    /// The free-text prompt the user is typing.
    public var promptText: String = ""
    /// Names of currently-running apps, for the target picker.
    public var runningAppNames: [String] = []
    /// The app the user selected as the agent's target.
    public var selectedAppName: String = ""
    /// The high-level run state.
    public var phase: Phase = .idle
    /// The live status feed shown in the expanded notch.
    public var feed: [FeedItem] = []
    /// A risky action awaiting approval, or `nil`.
    public var pendingApproval: PendingApproval?
    /// Whether the notch is expanded to its full panel.
    public var isExpanded: Bool = false
    /// The selected LLM backend for this run.
    public var selectedProvider: Provider {
        didSet {
            guard selectedProvider != oldValue else { return }
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: Self.providerDefaultsKey)
            apiKey = Self.savedAPIKey(for: selectedProvider)
        }
    }
    /// The selected provider's API key (bring-your-own in v1).
    public var apiKey: String

    public var apiKeyPlaceholder: String { selectedProvider.apiKeyPlaceholder }
    public var selectedModelName: String { selectedProvider.model }

    // MARK: - Private

    private static let providerDefaultsKey = "AutopilotLLMProvider"

    private let locator = AppLocator()
    private var runTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    public init() {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
            .flatMap(Provider.init(rawValue:)) ?? .zai
        self.selectedProvider = savedProvider
        self.apiKey = Self.savedAPIKey(for: savedProvider)
    }

    // MARK: - Actions

    /// Refresh the list of running apps for the target picker.
    public func refreshApps() {
        runningAppNames = locator.runningApps().map(\.name).sorted()
        if selectedAppName.isEmpty {
            selectedAppName = runningAppNames.first ?? ""
        }
    }

    /// Run the current prompt as an agent task.
    public func submit() {
        let task = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, phase != .running else { return }
        guard !apiKey.isEmpty else {
            phase = .failed("Add your \(selectedProvider.displayName) API key to get started.")
            return
        }
        let appName = selectedAppName.trimmingCharacters(in: .whitespaces)
        guard !appName.isEmpty, let target = locator.runningApp(matching: appName) else {
            phase = .failed("Pick the app you want me to operate.")
            return
        }
        let provider = selectedProvider
        let apiKey = apiKey
        UserDefaults.standard.set(apiKey, forKey: provider.apiKeyDefaultsKey)

        feed = []
        phase = .running

        let session = AgentSession(
            llm: Self.makeLLMProvider(provider: provider, apiKey: apiKey),
            computer: MacComputer(
                pid: target.processID,
                appName: target.name,
                bundleIdentifier: target.bundleIdentifier
            ),
            interaction: self,
            configuration: AgentConfiguration(model: provider.model),
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
        case .diagnostics(let diagnostics):
            append(diagnostics.summary, isError: !diagnostics.isReady)
            for warning in diagnostics.warnings {
                append("\(warning.title): \(warning.detail)")
            }
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

    private static func savedAPIKey(for provider: Provider) -> String {
        UserDefaults.standard.string(forKey: provider.apiKeyDefaultsKey) ?? ""
    }

    private static func makeLLMProvider(provider: Provider, apiKey: String) -> any LLMProvider {
        switch provider {
        case .zai:
            ZAIProvider(apiKey: apiKey)
        case .anthropic:
            AnthropicProvider(apiKey: apiKey)
        }
    }
}
