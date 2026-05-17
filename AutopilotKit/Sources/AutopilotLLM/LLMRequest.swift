/// A request to an `LLMProvider`.
public struct LLMRequest: Sendable {
    /// Model identifier, e.g. a Claude Sonnet model name.
    public var model: String
    /// System prompt (static across an agent run; cached by providers).
    public var system: String?
    /// Conversation so far.
    public var messages: [LLMMessage]
    /// Tools the model may call.
    public var tools: [ToolDefinition]
    /// Maximum tokens to generate.
    public var maxTokens: Int
    /// Optional sampling temperature.
    public var temperature: Double?

    public init(
        model: String,
        system: String? = nil,
        messages: [LLMMessage],
        tools: [ToolDefinition] = [],
        maxTokens: Int = 4096,
        temperature: Double? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}
