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
        public let inputTokens: Int
        public let outputTokens: Int

        public init(inputTokens: Int, outputTokens: Int) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
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
