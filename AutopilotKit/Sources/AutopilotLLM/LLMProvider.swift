/// How the user gets access to a model.
public enum LLMAccessMode: String, Sendable, Hashable, Codable {
    /// The app's built-in AI service. The user signs in with the app, not a
    /// vendor account, and does not manage API keys.
    case appManaged
    /// The user supplies their own API key or compatible endpoint access.
    case bringYourOwnKey
    /// The user connects an existing AI account through a supported provider
    /// auth flow.
    case existingSubscription

    public var displayName: String {
        switch self {
        case .appManaged: "Mac Autopilot Basic"
        case .bringYourOwnKey: "Bring Your Own Key"
        case .existingSubscription: "Existing AI Account"
        }
    }
}

/// User- and product-facing metadata for a selectable model.
public struct LLMModelDescriptor: Sendable, Hashable, Codable, Identifiable {
    public let identifier: String
    public let displayName: String
    public let supportsToolCalls: Bool
    public let supportsImageInput: Bool
    public let supportsPromptCaching: Bool

    public var id: String { identifier }

    public init(
        identifier: String,
        displayName: String,
        supportsToolCalls: Bool,
        supportsImageInput: Bool,
        supportsPromptCaching: Bool
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.supportsToolCalls = supportsToolCalls
        self.supportsImageInput = supportsImageInput
        self.supportsPromptCaching = supportsPromptCaching
    }
}

/// User- and product-facing metadata for a known LLM provider.
///
/// This is intentionally separate from the provider instance: callers can make
/// UI and tool-surface decisions before an API key exists.
public struct LLMProviderDescriptor: Sendable, Hashable, Codable {
    public let identifier: String
    public let displayName: String
    public let accessMode: LLMAccessMode
    public let defaultModel: String
    public let supportsToolCalls: Bool
    public let supportsImageInput: Bool
    public let supportsPromptCaching: Bool
    public let availableModels: [LLMModelDescriptor]
    public let allowsCustomModelID: Bool
    public let apiKeyEnvironment: String
    public let keychainAccount: String

    public init(
        identifier: String,
        displayName: String,
        accessMode: LLMAccessMode,
        defaultModel: String,
        supportsToolCalls: Bool,
        supportsImageInput: Bool,
        supportsPromptCaching: Bool,
        availableModels: [LLMModelDescriptor]? = nil,
        allowsCustomModelID: Bool = false,
        apiKeyEnvironment: String,
        keychainAccount: String
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.accessMode = accessMode
        self.defaultModel = defaultModel
        self.supportsToolCalls = supportsToolCalls
        self.supportsImageInput = supportsImageInput
        self.supportsPromptCaching = supportsPromptCaching
        self.availableModels = availableModels ?? [
            LLMModelDescriptor(
                identifier: defaultModel,
                displayName: defaultModel,
                supportsToolCalls: supportsToolCalls,
                supportsImageInput: supportsImageInput,
                supportsPromptCaching: supportsPromptCaching
            )
        ]
        self.allowsCustomModelID = allowsCustomModelID
        self.apiKeyEnvironment = apiKeyEnvironment
        self.keychainAccount = keychainAccount
    }

    public var defaultModelDescriptor: LLMModelDescriptor {
        modelDescriptor(for: defaultModel)
    }

    public func modelDescriptor(for identifier: String) -> LLMModelDescriptor {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowsCustomModelID, !trimmed.isEmpty {
            return LLMModelDescriptor(
                identifier: trimmed,
                displayName: trimmed,
                supportsToolCalls: supportsToolCalls,
                supportsImageInput: supportsImageInput,
                supportsPromptCaching: supportsPromptCaching
            )
        }
        return availableModels.first { $0.identifier == identifier }
            ?? availableModels.first { $0.identifier == defaultModel }
            ?? LLMModelDescriptor(
                identifier: defaultModel,
                displayName: defaultModel,
                supportsToolCalls: supportsToolCalls,
                supportsImageInput: supportsImageInput,
                supportsPromptCaching: supportsPromptCaching
            )
    }

    public static let anthropic = LLMProviderDescriptor(
        identifier: "anthropic",
        displayName: "Anthropic Claude",
        accessMode: .bringYourOwnKey,
        defaultModel: "claude-sonnet-4-6",
        supportsToolCalls: true,
        supportsImageInput: true,
        supportsPromptCaching: true,
        availableModels: [
            LLMModelDescriptor(
                identifier: "claude-sonnet-4-6",
                displayName: "Claude Sonnet 4.6",
                supportsToolCalls: true,
                supportsImageInput: true,
                supportsPromptCaching: true
            )
        ],
        apiKeyEnvironment: "ANTHROPIC_API_KEY",
        keychainAccount: "AutopilotAnthropicAPIKey"
    )

    public static let openai = LLMProviderDescriptor(
        identifier: "openai",
        displayName: "OpenAI GPT-5.4 Mini",
        accessMode: .bringYourOwnKey,
        defaultModel: "gpt-5.4-mini",
        supportsToolCalls: true,
        supportsImageInput: true,
        // OpenAI caches repeated prompt prefixes automatically; we emit no
        // explicit cache_control breakpoints, so this stays false.
        supportsPromptCaching: false,
        availableModels: [
            LLMModelDescriptor(
                identifier: "gpt-5.4-mini",
                displayName: "GPT-5.4 Mini",
                supportsToolCalls: true,
                supportsImageInput: true,
                supportsPromptCaching: false
            )
        ],
        apiKeyEnvironment: "OPENAI_API_KEY",
        keychainAccount: "AutopilotOpenAIAPIKey"
    )

    /// A power-user BYOK path for OpenAI-compatible Chat Completions endpoints:
    /// OpenRouter, LiteLLM, local Ollama servers, and similar routers. The
    /// endpoint and model id are configured by the user; the key is optional so
    /// local servers can run without storing a dummy secret.
    public static let openAICompatible = LLMProviderDescriptor(
        identifier: "openai-compatible",
        displayName: "OpenAI-compatible endpoint",
        accessMode: .bringYourOwnKey,
        defaultModel: "custom-model",
        supportsToolCalls: true,
        supportsImageInput: false,
        supportsPromptCaching: false,
        availableModels: [
            LLMModelDescriptor(
                identifier: "custom-model",
                displayName: "Custom model",
                supportsToolCalls: true,
                supportsImageInput: false,
                supportsPromptCaching: false
            )
        ],
        allowsCustomModelID: true,
        apiKeyEnvironment: "",
        keychainAccount: "AutopilotOpenAICompatibleAPIKey"
    )

    /// Mac Autopilot Basic: the model runs behind Mac Autopilot's own backend,
    /// so the user signs in instead of bringing a key. There is no local API
    /// key, hence the empty environment/keychain fields.
    public static let hosted = LLMProviderDescriptor(
        identifier: "hosted",
        displayName: "Mac Autopilot Basic",
        accessMode: .appManaged,
        defaultModel: "gpt-5.4-mini",
        supportsToolCalls: true,
        supportsImageInput: true,
        supportsPromptCaching: false,
        availableModels: [
            LLMModelDescriptor(
                identifier: "gpt-5.4-mini",
                displayName: "GPT-5.4 Mini",
                supportsToolCalls: true,
                supportsImageInput: true,
                supportsPromptCaching: false
            )
        ],
        apiKeyEnvironment: "",
        keychainAccount: ""
    )

    /// Existing ChatGPT Plus/Pro access through an app-owned OpenAI Codex
    /// subscription OAuth connector. The app does not handle ChatGPT cookies
    /// directly; it stores refreshable OAuth credentials in Keychain.
    public static let chatGPTAccount = LLMProviderDescriptor(
        identifier: "chatgpt-account",
        displayName: "ChatGPT subscription",
        accessMode: .existingSubscription,
        defaultModel: "automatic",
        supportsToolCalls: true,
        supportsImageInput: false,
        supportsPromptCaching: false,
        availableModels: [
            LLMModelDescriptor(
                identifier: "automatic",
                displayName: "Automatic",
                supportsToolCalls: true,
                supportsImageInput: false,
                supportsPromptCaching: false
            )
        ],
        apiKeyEnvironment: "",
        keychainAccount: ""
    )

    /// Existing Claude Pro/Max access through an app-owned Anthropic
    /// subscription OAuth connector. The app never reads Claude browser sessions
    /// directly; it stores refreshable OAuth credentials in Keychain.
    public static let anthropicSubscription = LLMProviderDescriptor(
        identifier: "anthropic-subscription",
        displayName: "Claude subscription",
        accessMode: .existingSubscription,
        defaultModel: "automatic",
        supportsToolCalls: true,
        supportsImageInput: false,
        supportsPromptCaching: false,
        availableModels: [
            LLMModelDescriptor(
                identifier: "automatic",
                displayName: "Automatic",
                supportsToolCalls: true,
                supportsImageInput: false,
                supportsPromptCaching: false
            )
        ],
        apiKeyEnvironment: "",
        keychainAccount: ""
    )
}

/// A provider-agnostic interface to a chat LLM with tool-use support.
///
/// Conforming types adapt a specific vendor API (Anthropic, OpenAI, a local
/// model, …) to one request/response shape, so the agent never depends on a
/// particular model or vendor. The app default is `OpenAIProvider`.
public protocol LLMProvider: Sendable {
    /// A short identifier for logging and telemetry, e.g. "anthropic".
    var identifier: String { get }

    /// Send a request and await the model's response.
    func send(_ request: LLMRequest) async throws -> LLMResponse
}
