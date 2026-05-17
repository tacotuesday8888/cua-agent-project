import AutopilotCore

/// A role in an LLM conversation.
public enum LLMRole: String, Sendable, Hashable {
    case user
    case assistant
}

/// A tool call requested by the model.
public struct ToolUse: Sendable, Hashable {
    public let id: String
    public let name: String
    public let input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// A base64-encoded image, e.g. a screenshot supplement.
public struct ImageBlock: Sendable, Hashable {
    public let mediaType: String
    public let base64Data: String

    public init(mediaType: String = "image/png", base64Data: String) {
        self.mediaType = mediaType
        self.base64Data = base64Data
    }
}

/// The result of executing a tool, sent back to the model.
public struct ToolResult: Sendable, Hashable {
    /// A piece of a tool result: either text or an image.
    public enum Content: Sendable, Hashable {
        case text(String)
        case image(ImageBlock)
    }

    public let toolUseID: String
    public let content: [Content]
    public let isError: Bool

    public init(toolUseID: String, content: [Content], isError: Bool = false) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = isError
    }

    /// Convenience for a text-only result.
    public init(toolUseID: String, text: String, isError: Bool = false) {
        self.init(toolUseID: toolUseID, content: [.text(text)], isError: isError)
    }
}

/// One content block within a message.
public enum LLMContentBlock: Sendable, Hashable {
    case text(String)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    case image(ImageBlock)
}

/// A single message in an LLM conversation.
public struct LLMMessage: Sendable, Hashable {
    public let role: LLMRole
    public let content: [LLMContentBlock]

    public init(role: LLMRole, content: [LLMContentBlock]) {
        self.role = role
        self.content = content
    }

    /// A plain-text user message.
    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: [.text(text)])
    }

    /// A plain-text assistant message.
    public static func assistant(_ text: String) -> LLMMessage {
        LLMMessage(role: .assistant, content: [.text(text)])
    }
}
