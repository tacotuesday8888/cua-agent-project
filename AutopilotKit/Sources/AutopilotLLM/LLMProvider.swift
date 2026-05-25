/// User- and product-facing metadata for a known LLM provider.
///
/// This is intentionally separate from the provider instance: callers can make
/// UI and tool-surface decisions before an API key exists.
public struct LLMProviderDescriptor: Sendable, Hashable, Codable {
    public let identifier: String
    public let displayName: String
    public let defaultModel: String
    public let supportsToolCalls: Bool
    public let supportsImageInput: Bool
    public let supportsPromptCaching: Bool
    public let apiKeyEnvironment: String
    public let keychainAccount: String

    public init(
        identifier: String,
        displayName: String,
        defaultModel: String,
        supportsToolCalls: Bool,
        supportsImageInput: Bool,
        supportsPromptCaching: Bool,
        apiKeyEnvironment: String,
        keychainAccount: String
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.defaultModel = defaultModel
        self.supportsToolCalls = supportsToolCalls
        self.supportsImageInput = supportsImageInput
        self.supportsPromptCaching = supportsPromptCaching
        self.apiKeyEnvironment = apiKeyEnvironment
        self.keychainAccount = keychainAccount
    }

    public static let zai = LLMProviderDescriptor(
        identifier: "zai",
        displayName: "Z.ai GLM-4.7-Flash",
        defaultModel: "glm-4.7-flash",
        supportsToolCalls: true,
        supportsImageInput: false,
        supportsPromptCaching: false,
        apiKeyEnvironment: "ZAI_API_KEY",
        keychainAccount: "AutopilotZAIAPIKey"
    )

    public static let anthropic = LLMProviderDescriptor(
        identifier: "anthropic",
        displayName: "Anthropic Claude",
        defaultModel: "claude-sonnet-4-6",
        supportsToolCalls: true,
        supportsImageInput: true,
        supportsPromptCaching: true,
        apiKeyEnvironment: "ANTHROPIC_API_KEY",
        keychainAccount: "AutopilotAnthropicAPIKey"
    )

    public static let openai = LLMProviderDescriptor(
        identifier: "openai",
        displayName: "OpenAI GPT-5.4 Mini",
        defaultModel: "gpt-5.4-mini",
        supportsToolCalls: true,
        supportsImageInput: true,
        // OpenAI caches repeated prompt prefixes automatically; we emit no
        // explicit cache_control breakpoints, so this stays false.
        supportsPromptCaching: false,
        apiKeyEnvironment: "OPENAI_API_KEY",
        keychainAccount: "AutopilotOpenAIAPIKey"
    )

    /// The hosted path: the model runs behind Mac Autopilot's own backend, so the
    /// user signs in instead of bringing a key. There is no local API key, hence
    /// the empty environment/keychain fields.
    public static let hosted = LLMProviderDescriptor(
        identifier: "hosted",
        displayName: "Mac Autopilot (hosted)",
        defaultModel: "gpt-5.4-mini",
        supportsToolCalls: true,
        supportsImageInput: true,
        supportsPromptCaching: false,
        apiKeyEnvironment: "",
        keychainAccount: ""
    )
}

/// A provider-agnostic interface to a chat LLM with tool-use support.
///
/// Conforming types adapt a specific vendor API (Anthropic, OpenAI, a local
/// model, …) to one request/response shape, so the agent never depends on a
/// particular model or vendor. The v1 app default is `ZAIProvider`.
public protocol LLMProvider: Sendable {
    /// A short identifier for logging and telemetry, e.g. "anthropic".
    var identifier: String { get }

    /// Send a request and await the model's response.
    func send(_ request: LLMRequest) async throws -> LLMResponse
}
