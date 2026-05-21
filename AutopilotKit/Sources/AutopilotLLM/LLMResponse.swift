/// A response from an `LLMProvider`.
public struct LLMResponse: Sendable, Hashable {
    /// Why the model stopped generating.
    public enum StopReason: Sendable, Hashable {
        case endTurn
        case toolUse
        case maxTokens
        case other(String)
    }

    /// Token usage for the request.
    public struct Usage: Sendable, Hashable {
        /// Fresh, uncached input tokens billed at the base input rate.
        public let inputTokens: Int
        public let outputTokens: Int
        /// Input tokens written to the prompt cache (Anthropic prompt caching).
        public let cacheCreationInputTokens: Int
        /// Input tokens served from the prompt cache (Anthropic prompt caching).
        public let cacheReadInputTokens: Int

        public init(
            inputTokens: Int,
            outputTokens: Int,
            cacheCreationInputTokens: Int = 0,
            cacheReadInputTokens: Int = 0
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
        }

        /// Every input token the model processed for this call: fresh tokens
        /// plus any written to or read from the prompt cache. With caching on,
        /// `inputTokens` alone counts only the uncached remainder, so cost
        /// accounting must use this sum.
        public var totalInputTokens: Int {
            inputTokens + cacheCreationInputTokens + cacheReadInputTokens
        }
    }

    public let content: [LLMContentBlock]
    public let stopReason: StopReason
    public let usage: Usage

    public init(content: [LLMContentBlock], stopReason: StopReason, usage: Usage) {
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    /// All tool calls present in the response.
    public var toolUses: [ToolUse] {
        content.compactMap { block in
            if case .toolUse(let use) = block { return use }
            return nil
        }
    }

    /// The concatenated text of the response.
    public var text: String {
        content
            .compactMap { block -> String? in
                if case .text(let value) = block { return value }
                return nil
            }
            .joined(separator: "\n")
    }
}
