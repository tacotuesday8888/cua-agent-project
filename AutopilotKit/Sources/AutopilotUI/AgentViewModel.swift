import AutopilotAgent
import AutopilotCore
import AutopilotHistory
import AutopilotLLM
import AutopilotMac
import AutopilotMemory
import AutopilotWorkflows
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
        case stopping
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

    /// A workflow the agent proposed saving, awaiting the user's approval.
    public struct PendingWorkflow: Sendable, Identifiable {
        public let id = UUID()
        /// The proposed name.
        public let name: String
        /// The reusable goal, with `{{slot}}` tokens.
        public let goalTemplate: String
        /// Optional learned hints injected as a prior on re-runs.
        public let recipe: String
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

    /// A saved workflow shown in the workflows list.
    public struct StoredWorkflow: Sendable, Identifiable {
        /// The underlying `Workflow` id, used to run or delete it.
        public let id: UUID
        /// The user-facing name.
        public let name: String
        /// The app the workflow operates.
        public let appName: String
        /// The goal, with `{{slot}}` tokens for its variables.
        public let goalTemplate: String
        /// The variables the user fills in before a run.
        public let variables: [WorkflowVariable]
        /// How many times it has been run.
        public let runCount: Int
        /// How many of those runs succeeded.
        public let successCount: Int
    }

    /// A clarifying question from the agent, awaiting a user answer.
    public struct PendingQuestion: Sendable, Identifiable {
        public let id = UUID()
        /// The question the model asked before it can continue.
        public let text: String
    }

    /// Product-facing status for consumer-account access.
    public struct ExistingAccountAccessStatus: Sendable, Equatable {
        public let accessMode: LLMAccessMode
        public let title: String
        public let summary: String
        public let detail: String
        public let isAvailable: Bool

        public init(
            accessMode: LLMAccessMode,
            title: String,
            summary: String,
            detail: String,
            isAvailable: Bool
        ) {
            self.accessMode = accessMode
            self.title = title
            self.summary = summary
            self.detail = detail
            self.isAvailable = isAvailable
        }
    }

    /// Product-facing setup state for existing subscription OAuth providers.
    public struct SubscriptionAccountRequirement: Sendable, Equatable {
        public let providerName: String
        public let providerID: SubscriptionOAuthProviderID
        public let setupSummary: String

        public init(
            providerName: String,
            providerID: SubscriptionOAuthProviderID,
            setupSummary: String
        ) {
            self.providerName = providerName
            self.providerID = providerID
            self.setupSummary = setupSummary
        }
    }

    /// A fully-prepared agent run. Tests can replace the session runner while
    /// still exercising workflow preflight, history, and workflow counters.
    struct AgentRunRequest: Sendable {
        let task: String
        let target: AppLocator.RunningApp
        let modelIdentifier: String
        let recipe: String?
    }

    /// Minimal hosted-account state exposed by the app shell. The UI package
    /// stays Firebase-free; the app target supplies this snapshot and actions.
    public struct HostedAccountStatus: Sendable, Equatable {
        public let email: String?
        public let statusMessage: String?

        public init(email: String? = nil, statusMessage: String? = nil) {
            self.email = email
            self.statusMessage = statusMessage
        }

        public var isSignedIn: Bool { email != nil }
    }

    /// A known OpenAI-compatible endpoint preset. Presets reduce setup friction
    /// for common routing/local platforms without adding provider-specific
    /// transport code.
    public struct OpenAICompatiblePreset: Identifiable, Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let endpoint: String
        public let requiresAPIKey: Bool

        public init(
            id: String,
            displayName: String,
            endpoint: String,
            requiresAPIKey: Bool
        ) {
            self.id = id
            self.displayName = displayName
            self.endpoint = endpoint
            self.requiresAPIKey = requiresAPIKey
        }
    }

    /// Supported LLM backends.
    public enum Provider: String, CaseIterable, Identifiable, Sendable {
        /// Mac Autopilot Basic: the app-managed hosted backend (`llmProxy`).
        /// Uses the signed-in Firebase account for auth instead of a pasted key.
        case hosted
        /// ChatGPT Plus/Pro account access through subscription OAuth.
        case chatGPTAccount = "chatgpt-account"
        case openai
        case anthropic
        /// Any OpenAI-compatible Chat Completions endpoint configured by the
        /// user. Supports routers and local servers without provider-specific
        /// subscription assumptions.
        case openAICompatible = "openai-compatible"
        /// Claude Pro/Max account access through subscription OAuth.
        case anthropicSubscription

        public static let allCases: [Provider] = [
            .hosted,
            .chatGPTAccount,
            .anthropicSubscription,
            .openai,
            .anthropic,
            .openAICompatible
        ]

        public var id: String { rawValue }

        public var descriptor: LLMProviderDescriptor {
            switch self {
            case .hosted: .hosted
            case .chatGPTAccount: .chatGPTAccount
            case .openai: .openai
            case .anthropic: .anthropic
            case .openAICompatible: .openAICompatible
            case .anthropicSubscription: .anthropicSubscription
            }
        }

        public var displayName: String {
            descriptor.displayName
        }

        public var accessMode: LLMAccessMode {
            descriptor.accessMode
        }

        /// How this provider authenticates. Drives the settings UI: API key
        /// providers show a `SecureField`; hosted shows Google Sign-In; account
        /// providers show app-owned OAuth sign-in.
        public enum AuthStyle: Sendable, Equatable {
            case apiKey(required: Bool)
            case hostedFirebase
            case subscriptionOAuth(providerID: SubscriptionOAuthProviderID)
        }

        public var authStyle: AuthStyle {
            switch self {
            case .openai, .anthropic:
                .apiKey(required: true)
            case .openAICompatible:
                .apiKey(required: false)
            case .chatGPTAccount:
                .subscriptionOAuth(providerID: .chatGPTCodex)
            case .hosted:
                .hostedFirebase
            case .anthropicSubscription:
                .subscriptionOAuth(providerID: .anthropic)
            }
        }

        /// Whether this provider uses an API key field at all. For the generic
        /// OpenAI-compatible endpoint the key is optional, because local servers
        /// such as Ollama commonly run without one.
        var usesAPIKey: Bool {
            if case .apiKey = authStyle { return true }
            return false
        }

        /// Whether this provider needs a user-supplied API key. Hosted AI and
        /// existing-account providers authenticate without a pasted key.
        var requiresAPIKey: Bool {
            if case .apiKey(let required) = authStyle { return required }
            return false
        }

        var apiKeyPlaceholder: String {
            switch self {
            case .hosted: "Sign in for Mac Autopilot Basic"
            case .chatGPTAccount: "Uses ChatGPT subscription login"
            case .openai: "OpenAI API key"
            case .anthropic: "Anthropic API key"
            case .openAICompatible: "API key (optional for local)"
            case .anthropicSubscription: "Uses Claude subscription login"
            }
        }

        var apiKeyDefaultsKey: String {
            descriptor.keychainAccount
        }
    }

    public static let openAICompatiblePresets: [OpenAICompatiblePreset] = [
        OpenAICompatiblePreset(
            id: "custom",
            displayName: "Custom endpoint",
            endpoint: "",
            requiresAPIKey: false
        ),
        OpenAICompatiblePreset(
            id: "openrouter",
            displayName: "OpenRouter",
            endpoint: "https://openrouter.ai/api/v1/chat/completions",
            requiresAPIKey: true
        ),
        OpenAICompatiblePreset(
            id: "gemini",
            displayName: "Gemini",
            endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            requiresAPIKey: true
        ),
        OpenAICompatiblePreset(
            id: "groq",
            displayName: "Groq",
            endpoint: "https://api.groq.com/openai/v1/chat/completions",
            requiresAPIKey: true
        ),
        OpenAICompatiblePreset(
            id: "together",
            displayName: "Together AI",
            endpoint: "https://api.together.xyz/v1/chat/completions",
            requiresAPIKey: true
        ),
        OpenAICompatiblePreset(
            id: "fireworks",
            displayName: "Fireworks AI",
            endpoint: "https://api.fireworks.ai/inference/v1/chat/completions",
            requiresAPIKey: true
        ),
        OpenAICompatiblePreset(
            id: "deepseek",
            displayName: "DeepSeek",
            endpoint: "https://api.deepseek.com/chat/completions",
            requiresAPIKey: true
        ),
        OpenAICompatiblePreset(
            id: "qwen",
            displayName: "Qwen / DashScope",
            endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            requiresAPIKey: true
        ),
        OpenAICompatiblePreset(
            id: "glm",
            displayName: "GLM / BigModel",
            endpoint: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            requiresAPIKey: true
        ),
        OpenAICompatiblePreset(
            id: "litellm",
            displayName: "LiteLLM local proxy",
            endpoint: "http://localhost:4000/v1/chat/completions",
            requiresAPIKey: false
        ),
        OpenAICompatiblePreset(
            id: "ollama",
            displayName: "Ollama local",
            endpoint: "http://localhost:11434/v1/chat/completions",
            requiresAPIKey: false
        )
    ]

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
    /// A proposed workflow awaiting approval, or `nil`.
    public var pendingWorkflow: PendingWorkflow?
    /// Editable draft name for a pending workflow proposal.
    public var pendingWorkflowNameText: String = ""
    /// Editable draft goal for a pending workflow proposal.
    public var pendingWorkflowGoalText: String = ""
    /// Editable draft recipe hints for a pending workflow proposal.
    public var pendingWorkflowRecipeText: String = ""
    /// A clarifying question awaiting an answer, or `nil`.
    public var pendingQuestion: PendingQuestion?
    /// Draft answer for a pending clarification question.
    public var questionAnswerText: String = ""
    /// Whether the notch is expanded to its full panel.
    public var isExpanded: Bool = false
    /// The current action target being previewed/highlighted, if any.
    public private(set) var highlightedTarget: ActionTarget?
    /// Recent finished runs, newest first, from the local history store.
    public private(set) var recentRuns: [RunRecord] = []
    /// Everything the agent currently remembers about the user, newest first.
    public private(set) var storedMemories: [StoredMemory] = []
    /// The saved workflows, most-recently-updated first.
    public private(set) var savedWorkflows: [StoredWorkflow] = []
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
            selectedModelID = Self.savedModelID(for: selectedProvider)
            apiKey = Self.savedAPIKey(for: selectedProvider)
        }
    }
    /// The selected model id within the selected provider. This is persisted
    /// per provider so switching providers keeps each provider's model choice.
    public var selectedModelID: String {
        didSet {
            UserDefaults.standard.set(
                selectedModelDescriptor.identifier,
                forKey: Self.modelDefaultsKey(for: selectedProvider)
            )
        }
    }
    /// The selected provider's API key (bring-your-own). Unused for hosted AI,
    /// which authenticates with the signed-in account.
    public var apiKey: String
    /// Selected OpenAI-compatible provider preset. `custom` means the endpoint
    /// field is user-controlled without a known platform default.
    public var openAICompatiblePresetID: String {
        didSet {
            UserDefaults.standard.set(
                openAICompatiblePresetID,
                forKey: Self.openAICompatiblePresetDefaultsKey
            )
        }
    }
    /// Full Chat Completions URL for the OpenAI-compatible BYOK path.
    /// This is not secret; any API key for the endpoint stays in Keychain.
    public var openAICompatibleEndpoint: String {
        didSet {
            UserDefaults.standard.set(
                openAICompatibleEndpoint,
                forKey: Self.openAICompatibleEndpointDefaultsKey
            )
        }
    }
    /// Whether the user-selected compatible model accepts image input. Routers
    /// cannot expose this consistently, so the app lets the user opt in.
    public var openAICompatibleSupportsImageInput: Bool {
        didSet {
            UserDefaults.standard.set(
                openAICompatibleSupportsImageInput,
                forKey: Self.openAICompatibleSupportsImageInputDefaultsKey
            )
        }
    }

    /// Supplies the Firebase ID token for hosted AI, or `nil` when not signed in.
    /// Injected by the app once Google Sign-In lands; the default returns `nil`,
    /// so a hosted run before sign-in fails with a clear "Sign in to use hosted
    /// AI." message rather than calling the backend unauthenticated. Not part of
    /// the observable UI state.
    @ObservationIgnored
    public var hostedTokenProvider: HostedProvider.TokenProvider = { nil }
    /// Supplies hosted account UI state without coupling AutopilotUI to Firebase.
    @ObservationIgnored
    public var hostedAccountStatusProvider: @MainActor () -> HostedAccountStatus = {
        HostedAccountStatus()
    }
    /// Starts the app-managed AI sign-in flow. The app target owns the concrete
    /// provider flow and browser presentation.
    @ObservationIgnored
    public var hostedSignInHandler: @MainActor () async -> Void = {}
    /// Signs out of the app-managed AI account.
    @ObservationIgnored
    public var hostedSignOutHandler: @MainActor () -> Void = {}
    @ObservationIgnored
    var runningAppResolverOverride: (@MainActor @Sendable (String) -> AppLocator.MatchResult)?
    @ObservationIgnored
    var agentSessionRunnerOverride:
        (@MainActor @Sendable (AgentRunRequest) async -> AgentOutcome)?
    /// Returns the current OAuth sign-in state for a supported subscription
    /// provider, or `nil` when the UI has not checked yet.
    @ObservationIgnored
    public var subscriptionAccountSignedInProvider:
        @MainActor (SubscriptionOAuthProviderID) -> Bool? = { provider in
            guard let credential = try? SubscriptionOAuthCredentialStore().load(provider: provider) else {
                return false
            }
            return !credential.refreshToken.isEmpty
        }
    /// Supplies refreshable subscription credentials to direct subscription
    /// providers. The default loads from Keychain and refreshes expired tokens.
    @ObservationIgnored
    public var subscriptionOAuthCredentialProvider:
        SubscriptionOAuthCredentialProvider.Load = SubscriptionOAuthCredentialProvider.keychain()

    public var apiKeyPlaceholder: String { selectedProvider.apiKeyPlaceholder }
    public var selectedModelName: String { selectedModelDescriptor.identifier }
    public var selectedProviderDescriptor: LLMProviderDescriptor { selectedProvider.descriptor }
    public var selectedProviderAccessMode: LLMAccessMode { selectedProvider.accessMode }
    public var availableModelDescriptors: [LLMModelDescriptor] {
        selectedProviderDescriptor.availableModels
    }
    public var selectedModelDescriptor: LLMModelDescriptor {
        if selectedProvider == .openAICompatible {
            let modelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = modelID.isEmpty ? selectedProviderDescriptor.defaultModel : modelID
            return LLMModelDescriptor(
                identifier: resolved,
                displayName: resolved == selectedProviderDescriptor.defaultModel ? "Custom model" : resolved,
                supportsToolCalls: true,
                supportsImageInput: openAICompatibleSupportsImageInput,
                supportsPromptCaching: false
            )
        }
        return selectedProviderDescriptor.modelDescriptor(for: selectedModelID)
    }
    public var openAICompatibleEndpointURL: URL? {
        let trimmed = openAICompatibleEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            return nil
        }
        return url
    }
    /// Whether the selected provider shows an API-key field. The field can be
    /// optional for local OpenAI-compatible endpoints.
    public var selectedProviderUsesAPIKey: Bool { selectedProvider.usesAPIKey }
    /// Whether the selected provider needs a pasted API key. `false` for hosted
    /// AI; the UI uses this to hide the key field.
    public var selectedProviderRequiresAPIKey: Bool {
        if selectedProvider == .openAICompatible {
            return selectedOpenAICompatiblePreset.requiresAPIKey
        }
        return selectedProvider.requiresAPIKey
    }
    public var selectedOpenAICompatiblePreset: OpenAICompatiblePreset {
        Self.openAICompatiblePresets.first { $0.id == openAICompatiblePresetID }
            ?? Self.openAICompatiblePresets[0]
    }
    public var isRunInProgress: Bool {
        switch phase {
        case .running, .stopping:
            true
        case .idle, .finished, .failed:
            false
        }
    }
    public var existingAccountAccessStatus: ExistingAccountAccessStatus {
        ExistingAccountAccessStatus(
            accessMode: .existingSubscription,
            title: "Existing AI Account Access",
            summary: "ChatGPT Plus/Pro and Claude Pro/Max use subscription login.",
            detail: "Mac Autopilot owns ChatGPT/Claude OAuth credential storage in Keychain and asks subscription-backed models for structured output.",
            isAvailable: true
        )
    }

    public var selectedSubscriptionAccountRequirement: SubscriptionAccountRequirement? {
        switch selectedProvider.authStyle {
        case .subscriptionOAuth(let providerID):
            return SubscriptionAccountRequirement(
                providerName: selectedProvider.displayName,
                providerID: providerID,
                setupSummary: "\(selectedProvider.displayName) uses app-owned OAuth sign-in. Tokens are stored in Keychain; browser cookies are not read."
            )
        default:
            return nil
        }
    }

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

    private static func appList(_ apps: [AppLocator.RunningApp]) -> String {
        let names = apps.map(\.name).sorted()
        let shown = names.prefix(3).joined(separator: ", ")
        guard names.count > 3 else { return shown }
        return "\(shown), and \(names.count - 3) more"
    }

    // MARK: - Private

    private static let providerDefaultsKey = "AutopilotLLMProvider"
    private static let modelDefaultsPrefix = "AutopilotLLMModel."
    private static let openAICompatiblePresetDefaultsKey = "AutopilotOpenAICompatiblePreset"
    private static let openAICompatibleEndpointDefaultsKey = "AutopilotOpenAICompatibleEndpoint"
    private static let openAICompatibleSupportsImageInputDefaultsKey =
        "AutopilotOpenAICompatibleSupportsImageInput"
    private static let trustedAppsDefaultsKey = "AutopilotPermanentlyTrustedApps"
    private static let workflowRequiredMessage = "Workflow name, app, and goal are required."
    private static let stoppedOutcome = AgentOutcome(
        status: .stopped,
        summary: "Stopped by the user."
    )
    /// The deployed `llmProxy` Firebase callable that backs hosted AI.
    static let hostedEndpoint = URL(
        string: "https://us-central1-macautopilot.cloudfunctions.net/llmProxy"
    )!
    /// How many recent runs to keep loaded for display.
    private static let recentRunDisplayLimit = 20
    /// The most live-feed items to retain; older items are dropped so a long
    /// run's feed does not grow without bound. The expanded notch only shows
    /// the most recent few, so trimming the rest is invisible to the user.
    private static let maxFeedItems = 200

    private let locator = AppLocator()
    /// The local, persistent memory store, shared with the agent and the
    /// (future) memory-management UI.
    private let memory: MemoryStore
    /// The local, persistent log of finished runs.
    private let history: RunHistoryStore
    /// The local, persistent store of reusable workflows.
    private let workflows: WorkflowStore
    private let promptParser = PromptParser()
    private var runTask: Task<Void, Never>?
    /// Metadata accumulated for the in-flight run, finalized on completion.
    private var pendingRun: PendingRun?
    /// The workflow this run was started from, if any, so its run/success
    /// counts can be updated when the run finishes.
    private var activeWorkflowID: UUID?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var memoryContinuation: CheckedContinuation<Bool, Never>?
    private var workflowContinuation: CheckedContinuation<Bool, Never>?
    private var questionContinuation: CheckedContinuation<String, Never>?

    /// In-flight run metadata, redacted into a `RunRecord` once the run ends.
    private struct PendingRun {
        let task: String
        let appName: String
        let model: String
        let startedAt: Date
        var performedTools: [String] = []
    }

    public init(
        memory: MemoryStore = MemoryStore(),
        history: RunHistoryStore = RunHistoryStore(),
        workflows: WorkflowStore = WorkflowStore()
    ) {
        self.memory = memory
        self.history = history
        self.workflows = workflows
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
            .flatMap(Provider.init(rawValue:))
        let savedProvider = storedProvider.flatMap { Provider.allCases.contains($0) ? $0 : nil }
            ?? .hosted
        self.selectedProvider = savedProvider
        self.selectedModelID = Self.savedModelID(for: savedProvider)
        self.apiKey = Self.savedAPIKey(for: savedProvider)
        let savedPreset = UserDefaults.standard.string(
            forKey: Self.openAICompatiblePresetDefaultsKey
        )
        if let savedPreset,
           Self.openAICompatiblePresets.contains(where: { $0.id == savedPreset }) {
            self.openAICompatiblePresetID = savedPreset
        } else {
            self.openAICompatiblePresetID = "custom"
        }
        self.openAICompatibleEndpoint = UserDefaults.standard
            .string(forKey: Self.openAICompatibleEndpointDefaultsKey) ?? ""
        self.openAICompatibleSupportsImageInput = UserDefaults.standard
            .object(forKey: Self.openAICompatibleSupportsImageInputDefaultsKey) as? Bool ?? false
        self.permanentlyTrustedApps = UserDefaults.standard
            .stringArray(forKey: Self.trustedAppsDefaultsKey) ?? []
        refreshPermissions()
        Task { [weak self] in
            await self?.loadRecentRuns()
            await self?.loadMemories()
            await self?.loadWorkflows()
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
        guard !task.isEmpty, !isRunInProgress else { return }

        // A "remember:" prompt only stores memory — no app or API key needed.
        let explicitMemories = promptParser.explicitMemories(in: task)
        if !explicitMemories.isEmpty {
            captureExplicitMemories(explicitMemories)
            return
        }

        if let message = providerSetupErrorMessage() {
            phase = .failed(message)
            return
        }
        // An "@app" mention in the task picks the target, overriding the picker.
        var note: String?
        if let mention = promptParser.appMention(in: task) {
            switch resolveRunningApp(matching: mention) {
            case .matched(let resolved):
                selectedAppName = resolved.name
                note = "Targeting \(resolved.name) — named with @ in the task."
            case .notFound:
                phase = .failed("No running app matched @\(mention). Open that app, then try again.")
                return
            case .ambiguous(let apps):
                phase = .failed(
                    "@\(mention) matches more than one running app: "
                        + "\(Self.appList(apps)). Pick the exact app, then try again."
                )
                return
            }
        }
        let appName = selectedAppName.trimmingCharacters(in: .whitespaces)
        guard !appName.isEmpty else {
            phase = .failed("Pick the app you want me to operate, or name it with @.")
            return
        }
        let target: AppLocator.RunningApp
        switch resolveRunningApp(matching: appName) {
        case .matched(let resolved):
            target = resolved
        case .notFound:
            phase = .failed("Open \(appName), then try again.")
            return
        case .ambiguous(let apps):
            phase = .failed(
                "\(appName) matches more than one running app: "
                    + "\(Self.appList(apps)). Pick the exact app, then try again."
            )
            return
        }
        activeWorkflowID = nil
        startRun(task: task, target: target, note: note)
    }

    /// Run a saved workflow: fill its variables into the goal, then run it
    /// through the normal single-app agent loop. A re-run is not trusted
    /// automatically — it goes through the same approval gate as any task.
    public func runWorkflow(id: UUID, bindings: [String: String]) {
        guard !isRunInProgress else { return }
        activeWorkflowID = nil
        if let message = providerSetupErrorMessage() {
            phase = .failed(message)
            return
        }
        phase = .running
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else {
                self.finishStoppedWorkflowPreflight()
                return
            }
            guard let workflow = await self.workflows.get(id: id) else {
                self.phase = .failed("That workflow could not be found.")
                self.runTask = nil
                self.activeWorkflowID = nil
                return
            }
            guard !Task.isCancelled else {
                self.finishStoppedWorkflowPreflight()
                return
            }
            let missingSlots = WorkflowRenderer.missingSlotNames(
                in: workflow.goalTemplate,
                variables: workflow.variables,
                bindings: bindings
            )
            guard missingSlots.isEmpty else {
                let labels = missingSlots.map { "{{\($0)}}" }.joined(separator: ", ")
                self.phase = .failed("Fill workflow fields: \(labels).")
                self.runTask = nil
                self.activeWorkflowID = nil
                return
            }
            guard !Task.isCancelled else {
                self.finishStoppedWorkflowPreflight()
                return
            }
            let target: AppLocator.RunningApp
            switch self.resolveRunningApp(matching: workflow.appName) {
            case .matched(let resolved):
                target = resolved
            case .notFound:
                self.phase = .failed(
                    "\(workflow.appName) is not running. Open it, then run this workflow."
                )
                self.runTask = nil
                self.activeWorkflowID = nil
                return
            case .ambiguous(let apps):
                self.phase = .failed(
                    "\(workflow.appName) matches more than one running app: "
                        + "\(Self.appList(apps)). Use a more specific workflow target."
                )
                self.runTask = nil
                self.activeWorkflowID = nil
                return
            }
            guard !Task.isCancelled else {
                self.finishStoppedWorkflowPreflight()
                return
            }
            let resolvedBindings = WorkflowRenderer.resolvedBindings(
                variables: workflow.variables,
                bindings: bindings
            )
            let goal = WorkflowRenderer.resolveGoal(
                template: workflow.goalTemplate,
                bindings: resolvedBindings
            )
            self.selectedAppName = workflow.appName
            self.activeWorkflowID = workflow.id
            self.runTask = nil
            self.startRun(
                task: goal,
                target: target,
                note: "Workflow — \(workflow.name)",
                recipe: workflow.recipe
            )
        }
    }

    private func finishStoppedWorkflowPreflight() {
        phase = .failed("Stopped.")
        runTask = nil
        activeWorkflowID = nil
    }

    /// Build and start an `AgentSession` for `task` against `target`, resetting
    /// the run UI state. Shared by direct prompts and workflow re-runs. A
    /// workflow re-run passes its saved `recipe` as a prompt prior.
    private func startRun(
        task: String,
        target: AppLocator.RunningApp,
        note: String? = nil,
        recipe: String? = nil
    ) {
        let provider = selectedProvider
        let model = selectedModelDescriptor
        let apiKey = apiKey
        let compatibleEndpoint = openAICompatibleEndpointURL
        let subscriptionCredentialProvider = subscriptionOAuthCredentialProvider
        if provider.usesAPIKey {
            do {
                try Self.saveAPIKey(apiKey, for: provider)
            } catch {
                phase = .failed("Could not save API key securely: \(error.localizedDescription)")
                return
            }
        }

        feed = []
        runInputTokens = 0
        runOutputTokens = 0
        append("Model — \(provider.displayName) (\(model.identifier))")
        if let note {
            append(note)
        }
        pendingApproval = nil
        pendingMemory = nil
        pendingWorkflow = nil
        clearPendingWorkflowDraft()
        pendingQuestion = nil
        highlightedTarget = nil
        questionAnswerText = ""
        phase = .running
        pendingRun = PendingRun(
            task: task,
            appName: target.name,
            model: model.identifier,
            startedAt: Date()
        )

        if let runAgentSession = agentSessionRunnerOverride {
            let request = AgentRunRequest(
                task: task,
                target: target,
                modelIdentifier: model.identifier,
                recipe: recipe
            )
            runTask = Task { @MainActor [weak self] in
                let outcome = await runAgentSession(request)
                self?.finish(with: Task.isCancelled ? Self.stoppedOutcome : outcome)
            }
            return
        }

        let session = AgentSession(
            llm: Self.makeLLMProvider(
                provider: provider,
                apiKey: apiKey,
                hostedTokenProvider: hostedTokenProvider,
                subscriptionCredentialProvider: subscriptionCredentialProvider,
                openAICompatibleEndpoint: compatibleEndpoint
            ),
            computer: MacComputer(
                pid: target.processID,
                appName: target.name,
                bundleIdentifier: target.bundleIdentifier
            ),
            interaction: self,
            configuration: AgentConfiguration(
                model: model.identifier,
                supportsImageInput: model.supportsImageInput,
                recipe: recipe
            ),
            memory: memory,
            permanentlyTrustedApps: Set(permanentlyTrustedApps),
            eventHandler: { [weak self] event in
                Task { @MainActor in self?.ingest(event) }
            }
        )

        runTask = Task { @MainActor [weak self] in
            let outcome = await session.run(task: task)
            self?.finish(with: Task.isCancelled ? Self.stoppedOutcome : outcome)
        }
    }

    /// Stop a running task.
    public func stop() {
        let hadRunTask = runTask != nil
        runTask?.cancel()
        highlightedTarget = nil
        if hadRunTask, phase == .running {
            phase = .stopping
        }
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
        if let continuation = workflowContinuation {
            workflowContinuation = nil
            pendingWorkflow = nil
            clearPendingWorkflowDraft()
            continuation.resume(returning: false)
        }
        if let continuation = questionContinuation {
            questionContinuation = nil
            pendingQuestion = nil
            questionAnswerText = ""
            continuation.resume(returning: "")
        }
    }

    private func resolveRunningApp(matching query: String) -> AppLocator.MatchResult {
        if let runningAppResolverOverride {
            return runningAppResolverOverride(query)
        }
        return locator.resolveRunningApp(matching: query)
    }

    public func applyOpenAICompatiblePreset(id: String) {
        guard let preset = Self.openAICompatiblePresets.first(where: { $0.id == id }) else {
            return
        }
        openAICompatiblePresetID = preset.id
        if !preset.endpoint.isEmpty {
            openAICompatibleEndpoint = preset.endpoint
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

    /// Answer a pending workflow proposal. On save, persist it for reuse against
    /// the current run's target app, deriving variables from its `{{slot}}`s.
    public func resolveWorkflow(_ save: Bool) {
        guard let continuation = workflowContinuation else { return }
        guard save else {
            workflowContinuation = nil
            pendingWorkflow = nil
            clearPendingWorkflowDraft()
            continuation.resume(returning: false)
            return
        }
        guard let proposed = pendingWorkflow else {
            workflowContinuation = nil
            clearPendingWorkflowDraft()
            continuation.resume(returning: false)
            return
        }

        let trimmedName = pendingWorkflowNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoal = pendingWorkflowGoalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApp = (pendingRun?.appName ?? selectedAppName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedGoal.isEmpty, !trimmedApp.isEmpty else {
            append("Workflow warning — \(Self.workflowRequiredMessage)", isError: true)
            return
        }

        let proposalID = proposed.id
        let variables = Self.workflowVariables(in: trimmedGoal)
        let trimmedRecipe = pendingWorkflowRecipeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflow = Workflow(
            name: trimmedName,
            appName: trimmedApp,
            goalTemplate: trimmedGoal,
            recipe: trimmedRecipe,
            variables: variables,
            source: .proposed
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.workflows.addReporting(workflow)
            guard
                self.pendingWorkflow?.id == proposalID,
                let continuation = self.workflowContinuation
            else {
                return
            }
            switch result {
            case .stored:
                await self.loadWorkflows()
                self.workflowContinuation = nil
                self.pendingWorkflow = nil
                self.clearPendingWorkflowDraft()
                continuation.resume(returning: true)
            case .updated, .cleared:
                await self.loadWorkflows()
            case .duplicate, .invalid, .failed:
                self.appendWorkflowWriteWarning(result, workflowName: workflow.name)
                await self.loadWorkflows()
            }
        }
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

    public func confirmWorkflow(_ proposal: WorkflowProposal) async -> Bool {
        await withCheckedContinuation { continuation in
            self.pendingWorkflow = PendingWorkflow(
                name: proposal.name,
                goalTemplate: proposal.goalTemplate,
                recipe: proposal.recipe
            )
            self.pendingWorkflowNameText = proposal.name
            self.pendingWorkflowGoalText = proposal.goalTemplate
            self.pendingWorkflowRecipeText = proposal.recipe
            self.workflowContinuation = continuation
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

    /// Erase every stored memory from the local memory file.
    public func clearMemories() {
        Task { [weak self] in
            guard let self else { return }
            if case .failed(let message) = await self.memory.clearReporting() {
                self.append("Storage warning — \(message)", isError: true)
            }
            await self.loadMemories()
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
            var failures = 0
            for item in memories {
                switch await self.memory.addReporting(item) {
                case .stored:
                    self.append("Saved to memory: \(item.text)")
                    stored += 1
                case .duplicate, .cleared:
                    break
                case .failed(let message):
                    self.append("Storage warning — \(message)", isError: true)
                    failures += 1
                }
            }
            await self.loadMemories()
            if failures > 0 && stored == 0 {
                self.phase = .failed("Could not save memory.")
            } else {
                self.phase = .finished(stored == 0 ? "Already in memory." : "Saved to memory.")
            }
        }
    }

    // MARK: - Workflows

    /// Refresh the saved-workflow list from the local store.
    public func loadWorkflows() async {
        savedWorkflows = await workflows.all().map { workflow in
            StoredWorkflow(
                id: workflow.id,
                name: workflow.name,
                appName: workflow.appName,
                goalTemplate: workflow.goalTemplate,
                variables: workflow.variables,
                runCount: workflow.runCount,
                successCount: workflow.successCount
            )
        }
    }

    /// Save a new workflow built by hand.
    public func createWorkflow(
        name: String,
        appName: String,
        goalTemplate: String,
        variables: [WorkflowVariable] = []
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoal = goalTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApp = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedGoal.isEmpty, !trimmedApp.isEmpty else { return }
        let derived = variables.isEmpty
            ? Self.workflowVariables(in: trimmedGoal)
            : variables
        storeWorkflow(Workflow(
            name: trimmedName,
            appName: trimmedApp,
            goalTemplate: trimmedGoal,
            variables: derived,
            source: .manual
        ))
    }

    /// Run history is redacted, so it cannot be converted back into a workflow
    /// goal. Workflows must be created manually from the current form or saved
    /// through an explicit agent proposal.
    public func saveRunAsWorkflow(_ record: RunRecord, name: String) {
        append("Run history is redacted. Create a workflow from a goal template instead.", isError: true)
    }

    /// Update a saved workflow while preserving its local-only metadata.
    public func updateWorkflow(
        id: UUID,
        name: String,
        appName: String,
        goalTemplate: String
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApp = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoal = goalTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedApp.isEmpty, !trimmedGoal.isEmpty else {
            append("Workflow warning — \(Self.workflowRequiredMessage)", isError: true)
            return
        }
        let variables = Self.workflowVariables(in: trimmedGoal)
        Task { [weak self] in
            guard let self else { return }
            guard let existing = await self.workflows.get(id: id) else {
                self.append("Workflow warning — That workflow could not be found.", isError: true)
                await self.loadWorkflows()
                return
            }
            let updated = Workflow(
                id: existing.id,
                name: trimmedName,
                appName: trimmedApp,
                goalTemplate: trimmedGoal,
                recipe: existing.recipe,
                variables: variables,
                source: existing.source,
                sourceRunID: existing.sourceRunID,
                createdAt: existing.createdAt,
                updatedAt: existing.updatedAt,
                runCount: existing.runCount,
                successCount: existing.successCount
            )
            let result = await self.workflows.update(updated)
            if case .updated = result {
                // Success is reflected by reloading the list below.
            } else {
                self.appendWorkflowWriteWarning(result, workflowName: trimmedName)
            }
            await self.loadWorkflows()
        }
    }

    /// Delete a saved workflow, then refresh the list.
    public func deleteWorkflow(id: UUID) {
        Task { [weak self] in
            await self?.workflows.delete(id: id)
            await self?.loadWorkflows()
        }
    }

    /// Erase every saved workflow.
    public func clearWorkflows() {
        Task { [weak self] in
            guard let self else { return }
            if case .failed(let message) = await self.workflows.clearReporting() {
                self.append("Storage warning — \(message)", isError: true)
            }
            await self.loadWorkflows()
        }
    }

    /// Persist a workflow and surface duplicate/failure outcomes in the feed.
    private func storeWorkflow(_ workflow: Workflow) {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.workflows.addReporting(workflow)
            switch result {
            case .stored, .updated, .cleared:
                break
            case .duplicate, .invalid, .failed:
                self.appendWorkflowWriteWarning(result, workflowName: workflow.name)
            }
            await self.loadWorkflows()
        }
    }

    private static func workflowVariables(in goalTemplate: String) -> [WorkflowVariable] {
        WorkflowRenderer.slotNames(in: goalTemplate).map { WorkflowVariable(name: $0) }
    }

    private func clearPendingWorkflowDraft() {
        pendingWorkflowNameText = ""
        pendingWorkflowGoalText = ""
        pendingWorkflowRecipeText = ""
    }

    private func appendWorkflowWriteWarning(
        _ result: WorkflowWriteResult,
        workflowName: String
    ) {
        switch result {
        case .stored, .updated, .cleared:
            break
        case .duplicate:
            append("A workflow named \"\(workflowName)\" already exists.", isError: true)
        case .invalid(let message):
            append("Workflow warning — \(message)", isError: true)
        case .failed(let message):
            append("Storage warning — \(message)", isError: true)
        }
    }

    // MARK: - Agent events

    func ingestForTesting(_ event: AgentEvent) {
        ingest(event)
    }

    private func ingest(_ event: AgentEvent) {
        switch event {
        case .started:
            highlightedTarget = nil
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
            highlightedTarget = target
            append(tier == .safe ? target.description : "\(target.description) [\(tier.rawValue)]")
        case .awaitingConfirmation(let request):
            append("Needs approval: \(request.summary)")
        case .confirmationDenied(let summary):
            highlightedTarget = nil
            append("Skipped: \(summary)", isError: true)
        case .performed(let tool, let summary):
            highlightedTarget = nil
            pendingRun?.performedTools.append(tool.rawValue)
            append("Done: \(summary)")
        case .actionFailed(let tool, let reason):
            highlightedTarget = nil
            append("\(tool.rawValue) failed — \(reason)", isError: true)
        case .askedUser(let question, _):
            append("Asked: \(question)")
        case .memoryProposed(let proposal):
            append("Proposing to remember: \(proposal.text)")
        case .memoryStored(let item):
            append("Saved to memory: \(item.text)")
            Task { [weak self] in await self?.loadMemories() }
        case .workflowProposed(let proposal):
            append("Proposing to save a workflow: \(proposal.name)")
        case .workflowSaved(let name):
            append("Saved workflow: \(name)")
            Task { [weak self] in await self?.loadWorkflows() }
        case .storageFailed(let message):
            append("Storage warning — \(message)", isError: true)
        case .finished(let summary):
            highlightedTarget = nil
            append("Finished — \(summary)")
        case .failed(let reason):
            highlightedTarget = nil
            append(reason, isError: true)
        case .stopped:
            highlightedTarget = nil
            append("Stopped.", isError: true)
        }
    }

    private func finish(with outcome: AgentOutcome) {
        let outcome = phase == .stopping ? Self.stoppedOutcome : outcome
        switch outcome.status {
        case .completed: phase = .finished(outcome.summary)
        case .stopped: phase = .failed("Stopped.")
        case .failed: phase = .failed(outcome.summary)
        }
        runTask = nil
        if let workflowID = activeWorkflowID {
            activeWorkflowID = nil
            let succeeded = outcome.status == .completed
            Task { [weak self] in
                await self?.workflows.recordRun(id: workflowID, succeeded: succeeded)
                await self?.loadWorkflows()
            }
        }
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
            guard let self else { return }
            if case .failed(let message) = await self.history.clearReporting() {
                self.append("Storage warning — \(message)", isError: true)
            }
            await self.loadRecentRuns()
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
            guard let self else { return }
            if case .failed(let message) = await self.history.recordReporting(record) {
                self.append("Storage warning — \(message)", isError: true)
            }
            await self.loadRecentRuns()
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

    /// Returns a user-facing error message if the selected provider can't run
    /// yet (missing API key, not signed in), or `nil` if ready.
    private func providerSetupErrorMessage() -> String? {
        if selectedProvider == .hosted, !hostedAccountStatusProvider().isSignedIn {
            return "Sign in with Google to use Mac Autopilot Basic."
        }
        if selectedProvider != .openAICompatible, selectedProvider.requiresAPIKey, apiKey.isEmpty {
            return "Add your \(selectedProvider.displayName) API key to get started."
        }
        if selectedProvider == .openAICompatible {
            if selectedOpenAICompatiblePreset.requiresAPIKey, apiKey.isEmpty {
                return "Add your \(selectedOpenAICompatiblePreset.displayName) API key to get started."
            }
            if openAICompatibleEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Add the OpenAI-compatible chat completions URL to get started."
            }
            if openAICompatibleEndpointURL == nil {
                return "Enter a valid OpenAI-compatible chat completions URL."
            }
            if selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Add a model ID for the OpenAI-compatible endpoint."
            }
        }
        if case .subscriptionOAuth(let providerID) = selectedProvider.authStyle,
           let signedIn = subscriptionAccountSignedInProvider(providerID) {
            if signedIn == false {
                return "Sign in with \(selectedProvider.displayName) to use your existing account."
            }
        } else if case .subscriptionOAuth = selectedProvider.authStyle {
            return "Check \(selectedProvider.displayName) sign-in status, then run again."
        }
        return nil
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

    private static func savedModelID(for provider: Provider) -> String {
        let descriptor = provider.descriptor
        let key = modelDefaultsKey(for: provider)
        if let saved = UserDefaults.standard.string(forKey: key),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if descriptor.allowsCustomModelID {
                return saved
            }
            if descriptor.availableModels.contains(where: { $0.identifier == saved }) {
                return saved
            }
        }
        return descriptor.defaultModel
    }

    private static func modelDefaultsKey(for provider: Provider) -> String {
        "\(modelDefaultsPrefix)\(provider.rawValue)"
    }

    private static func saveAPIKey(_ apiKey: String, for provider: Provider) throws {
        try APIKeyStore.save(apiKey, account: provider.apiKeyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: provider.apiKeyDefaultsKey)
    }

    private static func makeLLMProvider(
        provider: Provider,
        apiKey: String,
        hostedTokenProvider: @escaping HostedProvider.TokenProvider,
        subscriptionCredentialProvider: @escaping SubscriptionOAuthCredentialProvider.Load,
        openAICompatibleEndpoint: URL? = nil
    ) -> any LLMProvider {
        switch provider {
        case .hosted:
            return HostedProvider(endpoint: hostedEndpoint, tokenProvider: hostedTokenProvider)
        case .chatGPTAccount:
            return ChatGPTSubscriptionProvider(credentialProvider: subscriptionCredentialProvider)
        case .openai:
            return OpenAIProvider(apiKey: apiKey)
        case .anthropic:
            return AnthropicProvider(apiKey: apiKey)
        case .openAICompatible:
            return OpenAIProvider(
                apiKey: apiKey,
                identifier: LLMProviderDescriptor.openAICompatible.identifier,
                authenticationProviderName: "OpenAI-compatible endpoint",
                endpoint: openAICompatibleEndpoint ?? URL(
                    string: "http://localhost:11434/v1/chat/completions"
                )!,
                requiresAPIKey: false,
                tokenLimitParameter: .maxTokens
            )
        case .anthropicSubscription:
            return AnthropicSubscriptionProvider(credentialProvider: subscriptionCredentialProvider)
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
