import AutopilotAgent
import AutopilotCore
import AutopilotLLM
import AutopilotMac
import Foundation
import Observation
import Security

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
        do {
            try Self.saveAPIKey(apiKey, for: provider)
        } catch {
            phase = .failed("Could not save API key securely: \(error.localizedDescription)")
            return
        }

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
        if let key = try? APIKeyStore.load(account: provider.apiKeyDefaultsKey),
           !key.isEmpty {
            return key
        }

        guard
            let legacyKey = UserDefaults.standard.string(forKey: provider.apiKeyDefaultsKey),
            !legacyKey.isEmpty
        else {
            return ""
        }

        try? APIKeyStore.save(legacyKey, account: provider.apiKeyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: provider.apiKeyDefaultsKey)
        return legacyKey
    }

    private static func saveAPIKey(_ apiKey: String, for provider: Provider) throws {
        try APIKeyStore.save(apiKey, account: provider.apiKeyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: provider.apiKeyDefaultsKey)
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

private enum APIKeyStore {
    private static let service = "com.langqi.MacAutopilot.llm-api-keys"

    static func load(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return value
    }

    static func save(_ value: String, account: String) throws {
        guard !value.isEmpty else {
            try delete(account: account)
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    private static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Keychain error \(status)"
    }
}
