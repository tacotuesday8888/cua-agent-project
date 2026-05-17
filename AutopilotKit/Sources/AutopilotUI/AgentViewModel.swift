import AutopilotAgent
import AutopilotCore
import AutopilotHistory
import AutopilotLLM
import AutopilotMac
import AutopilotMemory
import Foundation
import Observation
import Security

/// The state and logic behind the notch UI.
///
/// `AgentViewModel` assembles and runs an `AgentSession`, streams its events
/// into a display feed, and bridges the agent's approval and memory requests
/// to the UI by conforming to `UserInteraction`.
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

    /// A gated action awaiting the user's approval.
    public struct PendingApproval: Sendable, Identifiable {
        public let id = UUID()
        /// One-line description of the action and its target.
        public let summary: String
        /// The risk tier — "write" or "destructive".
        public let tier: String
        /// True for destructive actions (send, delete, pay, overwrite).
        public let isDestructive: Bool
        /// The app the action operates.
        public let appName: String
    }

    /// A memory the agent proposed, awaiting the user's approval.
    public struct PendingMemory: Sendable, Identifiable {
        public let id = UUID()
        /// The fact the agent proposes remembering.
        public let text: String
        /// A human label for where it applies, e.g. "Global".
        public let scopeLabel: String
    }

    /// A stored memory shown in the management list.
    public struct StoredMemory: Sendable, Identifiable {
        /// The underlying `MemoryItem` id, used to delete it.
        public let id: UUID
        /// The remembered fact.
        public let text: String
        /// A human label for where it applies, e.g. "Global".
        public let scopeLabel: String
        /// How it was captured — "explicit" or "proposed".
        public let source: String
    }

    /// A clarifying question from the agent, awaiting a user answer.
    public struct PendingQuestion: Sendable, Identifiable {
        public let id = UUID()
        /// The question the model asked before it can continue.
        public let text: String
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
    /// Cumulative input tokens reported by the provider for the current run.
    public private(set) var runInputTokens: Int = 0
    /// Cumulative output tokens reported by the provider for the current run.
    public private(set) var runOutputTokens: Int = 0
    /// A gated action awaiting approval, or `nil`.
    public var pendingApproval: PendingApproval?
    /// A proposed memory awaiting approval, or `nil`.
    public var pendingMemory: PendingMemory?
    /// A clarifying question awaiting an answer, or `nil`.
    public var pendingQuestion: PendingQuestion?
    /// Draft answer for a pending clarification question.
    public var questionAnswerText: String = ""
    /// Whether the notch is expanded to its full panel.
    public var isExpanded: Bool = false
    /// Recent finished runs, newest first, from the local history store.
    public private(set) var recentRuns: [RunRecord] = []
    /// Everything the agent currently remembers about the user, newest first.
    public private(set) var storedMemories: [StoredMemory] = []
    /// Whether the app currently holds Accessibility permission.
    public private(set) var accessibilityTrusted = false
    /// Whether the app currently holds Screen Recording permission.
    public private(set) var screenRecordingTrusted = false
    /// Apps the user trusts permanently for write actions; persisted.
    public var permanentlyTrustedApps: [String] {
        didSet {
            UserDefaults.standard.set(permanentlyTrustedApps, forKey: Self.trustedAppsDefaultsKey)
        }
    }
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

    /// A compact "1.2k in · 0.3k out" token-usage label, or `nil` before any
    /// tokens have been reported.
    public var tokenUsageText: String? {
        guard runInputTokens > 0 || runOutputTokens > 0 else { return nil }
        return "\(Self.compactCount(runInputTokens)) in · "
            + "\(Self.compactCount(runOutputTokens)) out"
    }

    private static func compactCount(_ value: Int) -> String {
        value < 1000 ? "\(value)" : String(format: "%.1fk", Double(value) / 1000)
    }

    // MARK: - Private

    private static let providerDefaultsKey = "AutopilotLLMProvider"
    private static let trustedAppsDefaultsKey = "AutopilotPermanentlyTrustedApps"
    /// How many recent runs to keep loaded for display.
    private static let recentRunDisplayLimit = 20
    /// The most live-feed items to retain; older items are dropped so a long
    /// run's feed does not grow without bound. The expanded notch only shows
    /// the most recent few, so trimming the rest is invisible to the user.
    private static let maxFeedItems = 200

    private let locator = AppLocator()
    /// The local, persistent memory store, shared with the agent and the
    /// (future) memory-management UI.
    private let memory = MemoryStore()
    /// The local, persistent log of finished runs.
    private let history = RunHistoryStore()
    private let promptParser = PromptParser()
    private var runTask: Task<Void, Never>?
    /// Metadata accumulated for the in-flight run, finalized on completion.
    private var pendingRun: PendingRun?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var memoryContinuation: CheckedContinuation<Bool, Never>?
    private var questionContinuation: CheckedContinuation<String, Never>?

    /// In-flight run metadata, redacted into a `RunRecord` once the run ends.
    private struct PendingRun {
        let task: String
        let appName: String
        let model: String
        let startedAt: Date
        var performedTools: [String] = []
    }

    public init() {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
            .flatMap(Provider.init(rawValue:)) ?? .zai
        self.selectedProvider = savedProvider
        self.apiKey = Self.savedAPIKey(for: savedProvider)
        self.permanentlyTrustedApps = UserDefaults.standard
            .stringArray(forKey: Self.trustedAppsDefaultsKey) ?? []
        refreshPermissions()
        Task { [weak self] in
            await self?.loadRecentRuns()
            await self?.loadMemories()
        }
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

        // A "remember:" prompt only stores memory — no app or API key needed.
        let explicitMemories = promptParser.explicitMemories(in: task)
        if !explicitMemories.isEmpty {
            captureExplicitMemories(explicitMemories)
            return
        }

        guard !apiKey.isEmpty else {
            phase = .failed("Add your \(selectedProvider.displayName) API key to get started.")
            return
        }
        // An "@app" mention in the task picks the target, overriding the picker.
        var mentionedApp: String?
        if let mention = promptParser.appMention(in: task),
           let resolved = locator.runningApp(matching: mention) {
            selectedAppName = resolved.name
            mentionedApp = resolved.name
        }
        let appName = selectedAppName.trimmingCharacters(in: .whitespaces)
        guard !appName.isEmpty, let target = locator.runningApp(matching: appName) else {
            phase = .failed("Pick the app you want me to operate, or name it with @.")
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
        runInputTokens = 0
        runOutputTokens = 0
        append("Model — \(provider.displayName) (\(provider.model))")
        if let mentionedApp {
            append("Targeting \(mentionedApp) — named with @ in the task.")
        }
        pendingApproval = nil
        pendingMemory = nil
        pendingQuestion = nil
        questionAnswerText = ""
        phase = .running
        pendingRun = PendingRun(
            task: task,
            appName: target.name,
            model: provider.model,
            startedAt: Date()
        )

        let session = AgentSession(
            llm: Self.makeLLMProvider(provider: provider, apiKey: apiKey),
            computer: MacComputer(
                pid: target.processID,
                appName: target.name,
                bundleIdentifier: target.bundleIdentifier
            ),
            interaction: self,
            configuration: AgentConfiguration(model: provider.model),
            memory: memory,
            permanentlyTrustedApps: Set(permanentlyTrustedApps),
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
        if let continuation = memoryContinuation {
            memoryContinuation = nil
            pendingMemory = nil
            continuation.resume(returning: false)
        }
        if let continuation = questionContinuation {
            questionContinuation = nil
            pendingQuestion = nil
            questionAnswerText = ""
            continuation.resume(returning: "")
        }
    }

    /// Answer a pending action approval.
    public func resolveApproval(_ approved: Bool) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        pendingApproval = nil
        continuation.resume(returning: approved)
    }

    /// Answer a pending memory proposal.
    public func resolveMemory(_ save: Bool) {
        guard let continuation = memoryContinuation else { return }
        memoryContinuation = nil
        pendingMemory = nil
        continuation.resume(returning: save)
    }

    /// Answer a pending clarification question.
    public func resolveQuestion(_ answer: String) {
        guard let continuation = questionContinuation else { return }
        questionContinuation = nil
        pendingQuestion = nil
        questionAnswerText = ""
        continuation.resume(returning: answer.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Toggle between the compact and expanded notch.
    public func toggleExpanded() {
        isExpanded.toggle()
    }

    /// Trust `app` for write actions permanently, across sessions.
    public func grantPermanentTrust(app: String) {
        guard !isPermanentlyTrusted(app) else { return }
        permanentlyTrustedApps.append(app)
    }

    /// Revoke permanent write trust for `app`.
    public func revokePermanentTrust(app: String) {
        permanentlyTrustedApps.removeAll { $0.caseInsensitiveCompare(app) == .orderedSame }
    }

    /// Whether `app` is on the permanent-trust list.
    public func isPermanentlyTrusted(_ app: String) -> Bool {
        permanentlyTrustedApps.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
    }

    // MARK: - Permissions

    /// Re-read the current Accessibility and Screen Recording permission state.
    public func refreshPermissions() {
        accessibilityTrusted = SystemPermissions.accessibilityTrusted
        screenRecordingTrusted = SystemPermissions.screenRecordingTrusted
    }

    /// Prompt for Accessibility permission, then re-read the state.
    public func requestAccessibility() {
        SystemPermissions.requestAccessibility()
        refreshPermissions()
    }

    /// Open the Accessibility pane of System Settings.
    public func openAccessibilitySettings() {
        SystemPermissions.openAccessibilitySettings()
    }

    /// Prompt for Screen Recording permission, then re-read the state.
    public func requestScreenRecording() {
        SystemPermissions.requestScreenRecording()
        refreshPermissions()
    }

    /// Open the Screen Recording pane of System Settings.
    public func openScreenRecordingSettings() {
        SystemPermissions.openScreenRecordingSettings()
    }

    // MARK: - UserInteraction

    public func requestApproval(_ request: ApprovalRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            self.pendingApproval = PendingApproval(
                summary: request.summary,
                tier: request.tier.rawValue,
                isDestructive: request.tier == .destructive,
                appName: request.appName
            )
            self.approvalContinuation = continuation
        }
    }

    public func askQuestion(_ question: String) async -> String {
        await withCheckedContinuation { continuation in
            self.pendingQuestion = PendingQuestion(text: question)
            self.questionAnswerText = ""
            self.questionContinuation = continuation
        }
    }

    public func confirmMemory(_ proposal: MemoryProposal) async -> Bool {
        await withCheckedContinuation { continuation in
            self.pendingMemory = PendingMemory(
                text: proposal.text,
                scopeLabel: proposal.scope.displayName
            )
            self.memoryContinuation = continuation
        }
    }

    // MARK: - Memory

    /// Refresh the stored-memory list from the local memory store.
    public func loadMemories() async {
        storedMemories = await memory.all().map { item in
            StoredMemory(
                id: item.id,
                text: item.text,
                scopeLabel: item.scope.displayName,
                source: item.source.rawValue
            )
        }
    }

    /// Forget a stored memory, then refresh the list.
    public func deleteMemory(id: UUID) {
        Task { [weak self] in
            await self?.memory.delete(id: id)
            await self?.loadMemories()
        }
    }

    /// Store the memories from a "remember:" prompt and report it in the feed.
    private func captureExplicitMemories(_ memories: [MemoryItem]) {
        promptText = ""
        feed = []
        phase = .running
        Task { @MainActor [weak self] in
            guard let self else { return }
            var stored = 0
            for item in memories where await self.memory.add(item) {
                self.append("Saved to memory: \(item.text)")
                stored += 1
            }
            await self.loadMemories()
            self.phase = .finished(stored == 0 ? "Already in memory." : "Saved to memory.")
        }
    }

    // MARK: - Agent events

    private func ingest(_ event: AgentEvent) {
        switch event {
        case .started:
            append("Starting…")
        case .prepared(let summary):
            append(summary)
        case .diagnostics(let diagnostics):
            append(diagnostics.summary, isError: !diagnostics.isReady)
            for warning in diagnostics.warnings {
                append("\(warning.title): \(warning.detail)")
            }
        case .thinking:
            break
        case .observedTree(let count):
            append("Read the screen (\(count) elements)")
        case .tokenUsage(let inputTokens, let outputTokens):
            runInputTokens = inputTokens
            runOutputTokens = outputTokens
        case .message(let text):
            append(text)
        case .memoryRecalled(let items):
            append("Memory in use — \(items.map(\.text).joined(separator: "; "))")
        case .willPerform(_, let target, let tier):
            append(tier == .safe ? target.description : "\(target.description) [\(tier.rawValue)]")
        case .awaitingConfirmation(let request):
            append("Needs approval: \(request.summary)")
        case .confirmationDenied(let summary):
            append("Skipped: \(summary)", isError: true)
        case .performed(let tool, let summary):
            pendingRun?.performedTools.append(tool.rawValue)
            append("Done: \(summary)")
        case .actionFailed(let tool, let reason):
            append("\(tool.rawValue) failed — \(reason)", isError: true)
        case .askedUser(let question, _):
            append("Asked: \(question)")
        case .memoryProposed(let proposal):
            append("Proposing to remember: \(proposal.text)")
        case .memoryStored(let item):
            append("Saved to memory: \(item.text)")
            Task { [weak self] in await self?.loadMemories() }
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
        recordHistory(for: outcome)
    }

    // MARK: - Run history

    /// Refresh the recent-runs list from the local history store.
    public func loadRecentRuns() async {
        recentRuns = await history.recent(Self.recentRunDisplayLimit)
    }

    /// Erase the local run history.
    public func clearHistory() {
        Task { [weak self] in
            await self?.history.clear()
            await self?.loadRecentRuns()
        }
    }

    /// Persist a redacted record of the finished run, then refresh the list.
    private func recordHistory(for outcome: AgentOutcome) {
        guard let pending = pendingRun else { return }
        pendingRun = nil
        let record = RunRecord(
            task: pending.task,
            appName: pending.appName,
            model: pending.model,
            status: Self.runStatus(for: outcome.status),
            summary: outcome.summary,
            actions: pending.performedTools,
            inputTokens: runInputTokens,
            outputTokens: runOutputTokens,
            startedAt: pending.startedAt,
            finishedAt: Date()
        )
        Task { [weak self] in
            await self?.history.record(record)
            await self?.loadRecentRuns()
        }
    }

    private static func runStatus(for status: AgentOutcome.Status) -> RunStatus {
        switch status {
        case .completed: .completed
        case .stopped: .stopped
        case .failed: .failed
        }
    }

    private func append(_ text: String, isError: Bool = false) {
        feed.append(FeedItem(text: text, isError: isError))
        if feed.count > Self.maxFeedItems {
            feed.removeFirst(feed.count - Self.maxFeedItems)
        }
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
