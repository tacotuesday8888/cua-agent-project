import AutopilotCore
import Foundation

/// An `LLMProvider` backed by OpenAI's Chat Completions API (e.g. GPT-5.4 Mini).
///
/// It speaks the standard OpenAI Chat Completions wire format. The differences
/// this provider handles are: GPT-5.x requires
/// `max_completion_tokens` (it rejects `max_tokens`); multimodal `image_url`
/// content parts so the screenshot fallback works; and relocating images out of
/// `tool` messages — which OpenAI's tool role cannot carry — into a following
/// user message.
public struct OpenAIProvider: LLMProvider {
    public enum TokenLimitParameter: Sendable {
        case maxCompletionTokens
        case maxTokens
    }

    public let identifier: String

    private let apiKey: String
    private let endpoint: URL
    private let urlSession: URLSession
    private let retryPolicy: RetryPolicy
    /// Per-attempt request timeout, in seconds.
    private let requestTimeout: Double
    private let requiresAPIKey: Bool
    private let tokenLimitParameter: TokenLimitParameter
    private let authenticationProviderName: String

    public init(
        apiKey: String,
        identifier: String = "openai",
        authenticationProviderName: String = "OpenAI",
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        urlSession: URLSession = .shared,
        retryPolicy: RetryPolicy = .standard,
        requestTimeout: Double = 60,
        requiresAPIKey: Bool = true,
        tokenLimitParameter: TokenLimitParameter = .maxCompletionTokens
    ) {
        self.identifier = identifier
        self.authenticationProviderName = authenticationProviderName
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.retryPolicy = retryPolicy
        self.requestTimeout = max(1, requestTimeout)
        self.requiresAPIKey = requiresAPIKey
        self.tokenLimitParameter = tokenLimitParameter
    }

    public func send(_ request: LLMRequest) async throws -> LLMResponse {
        guard !requiresAPIKey || !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        let body: Data
        do {
            body = try JSONEncoder().encode(WireRequest(
                request,
                tokenLimitParameter: tokenLimitParameter
            ))
        } catch {
            throw LLMError.decodingFailed("request encoding failed: \(error)")
        }

        return try await retryPolicy.run { try await sendOnce(body: body) }
    }

    private func sendOnce(body: Data) async throws -> LLMResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        urlRequest.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: urlRequest)
        } catch {
            throw LLMError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                throw LLMError.rateLimited(retryAfter: retryAfter)
            }
            if http.statusCode == 401 {
                throw LLMError.authenticationFailed(provider: authenticationProviderName)
            }
            let body = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw LLMError.http(status: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(WireResponse.self, from: data).toLLMResponse()
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.decodingFailed("response decoding failed: \(error)")
        }
    }
}

// MARK: - OpenAI wire format (request)

private struct WireRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let tools: [WireTool]?
    let toolChoice: String?
    // GPT-5.x Chat Completions rejects `max_tokens`; it requires this key.
    let maxCompletionTokens: Int?
    let maxTokens: Int?
    let temperature: Double?
    let stream = false

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case toolChoice = "tool_choice"
        case maxCompletionTokens = "max_completion_tokens"
        case maxTokens = "max_tokens"
        case temperature
        case stream
    }

    init(_ request: LLMRequest, tokenLimitParameter: OpenAIProvider.TokenLimitParameter) {
        model = request.model
        messages = WireMessage.messages(from: request)
        if request.tools.isEmpty {
            tools = nil
            toolChoice = nil
        } else {
            tools = request.tools.map(WireTool.init)
            toolChoice = "auto"
        }
        switch tokenLimitParameter {
        case .maxCompletionTokens:
            maxCompletionTokens = request.maxTokens
            maxTokens = nil
        case .maxTokens:
            maxCompletionTokens = nil
            maxTokens = request.maxTokens
        }
        temperature = request.temperature
    }
}

private struct WireTool: Encodable {
    let type = "function"
    let function: WireToolFunction

    init(_ definition: ToolDefinition) {
        function = WireToolFunction(
            name: definition.name,
            description: definition.description,
            parameters: definition.inputSchema
        )
    }
}

private struct WireToolFunction: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

/// A chat message's `content`: either a plain string or an array of parts (used
/// when images are present).
private enum WireContent: Encodable {
    case text(String)
    case parts([WirePart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

private enum WirePart: Encodable {
    case text(String)
    case imageURL(String)

    private struct ImageURL: Encodable { let url: String }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: url), forKey: .imageURL)
        }
    }
}

private struct WireMessage: Encodable {
    let role: String
    let content: WireContent?
    let toolCalls: [WireRequestToolCall]?
    let toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    static func messages(from request: LLMRequest) -> [WireMessage] {
        var messages: [WireMessage] = []
        if let system = request.system?.trimmingCharacters(in: .whitespacesAndNewlines),
           !system.isEmpty {
            messages.append(WireMessage(role: "system", content: .text(system)))
        }
        for message in request.messages {
            messages.append(contentsOf: WireMessage.messages(from: message))
        }
        return messages
    }

    private static func messages(from message: LLMMessage) -> [WireMessage] {
        var texts: [String] = []
        var images: [ImageBlock] = []
        var toolUses: [ToolUse] = []
        var toolResults: [ToolResult] = []
        for block in message.content {
            switch block {
            case .text(let text): texts.append(text)
            case .image(let image): images.append(image)
            case .toolUse(let use): toolUses.append(use)
            case .toolResult(let result): toolResults.append(result)
            }
        }

        var messages: [WireMessage] = []
        let visibleText = texts.joined(separator: "\n")
        if !visibleText.isEmpty || !images.isEmpty || !toolUses.isEmpty {
            messages.append(WireMessage(
                role: message.role.rawValue,
                content: content(text: visibleText, images: images),
                toolCalls: toolUses.isEmpty ? nil : toolUses.map(WireRequestToolCall.init)
            ))
        }

        for result in toolResults {
            messages.append(WireMessage(
                role: "tool",
                content: .text(toolResultText(result)),
                toolCallID: result.toolUseID
            ))
            // OpenAI `tool` messages cannot carry images, so relocate any to a
            // following user message — vision models still receive them, in order.
            let resultImages = result.content.compactMap { part -> ImageBlock? in
                if case .image(let image) = part { return image }
                return nil
            }
            if !resultImages.isEmpty {
                messages.append(WireMessage(
                    role: "user",
                    content: .parts(
                        [.text("Image(s) from the previous tool result (\(result.toolUseID)):")]
                            + resultImages.map { WirePart.imageURL(dataURL(for: $0)) }
                    )
                ))
            }
        }
        return messages
    }

    private static func content(text: String, images: [ImageBlock]) -> WireContent? {
        guard !images.isEmpty else {
            return text.isEmpty ? nil : .text(text)
        }
        var parts: [WirePart] = []
        if !text.isEmpty { parts.append(.text(text)) }
        parts.append(contentsOf: images.map { WirePart.imageURL(dataURL(for: $0)) })
        return .parts(parts)
    }

    private static func dataURL(for image: ImageBlock) -> String {
        "data:\(image.mediaType);base64,\(image.base64Data)"
    }

    private static func toolResultText(_ result: ToolResult) -> String {
        let text = result.content.compactMap { content -> String? in
            switch content {
            case .text(let text): return text
            case .image: return nil
            }
        }.joined(separator: "\n")
        let body = text.isEmpty ? "(image-only result; see the following message)" : text
        return result.isError ? "Error: \(body)" : body
    }

    private init(
        role: String,
        content: WireContent?,
        toolCalls: [WireRequestToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

private struct WireRequestToolCall: Encodable {
    let id: String
    let type = "function"
    let function: WireRequestFunctionCall

    init(_ use: ToolUse) {
        id = use.id
        function = WireRequestFunctionCall(name: use.name, arguments: use.input)
    }
}

private struct WireRequestFunctionCall: Encodable {
    let name: String
    let arguments: String

    init(name: String, arguments: JSONValue) {
        self.name = name
        self.arguments = arguments.encodedJSONString
    }
}

// MARK: - OpenAI wire format (response)

private struct WireResponse: Decodable {
    let choices: [WireChoice]
    let usage: WireUsage?

    func toLLMResponse() throws -> LLMResponse {
        guard let choice = choices.first else {
            throw LLMError.invalidResponse("response did not include any choices")
        }
        var content: [LLMContentBlock] = []
        if let text = choice.message.content, !text.isEmpty {
            content.append(.text(text))
        }
        content.append(contentsOf: choice.message.toolCalls.map { .toolUse($0.toToolUse()) })

        return LLMResponse(
            content: content,
            stopReason: choice.stopReason,
            // OpenAI's `prompt_tokens` already includes any cached tokens (cached
            // is a discount, not a separate bucket), so map it straight to
            // inputTokens and leave the Anthropic-style cache fields at zero.
            usage: LLMResponse.Usage(
                inputTokens: usage?.promptTokens ?? 0,
                outputTokens: usage?.completionTokens ?? 0
            )
        )
    }
}

private struct WireChoice: Decodable {
    let message: WireResponseMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }

    var stopReason: LLMResponse.StopReason {
        switch finishReason {
        case "stop": return .endTurn
        case "tool_calls": return .toolUse
        case "length": return .maxTokens
        case let other?: return .other(other)
        case nil: return .other("unspecified")
        }
    }
}

private struct WireResponseMessage: Decodable {
    let content: String?
    let toolCalls: [WireResponseToolCall]

    enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        toolCalls = try container.decodeIfPresent([WireResponseToolCall].self, forKey: .toolCalls) ?? []
    }
}

private struct WireResponseToolCall: Decodable {
    let id: String
    let function: WireResponseFunctionCall

    func toToolUse() -> ToolUse {
        ToolUse(id: id, name: function.name, input: function.arguments)
    }
}

private struct WireResponseFunctionCall: Decodable {
    let name: String
    let arguments: JSONValue

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        // A tool call may omit `arguments` (or send null/invalid JSON) for a
        // no-argument call; treat that as empty input rather than failing.
        arguments = try container.decodeIfPresent(FlexibleArguments.self, forKey: .arguments)?
            .value ?? .object([:])
    }
}

private struct FlexibleArguments: Decodable {
    let value: JSONValue

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                value = .object([:])
            } else if let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) {
                value = parsed
            } else {
                value = .object([:])
            }
        } else {
            value = try container.decode(JSONValue.self)
        }
    }
}

private struct WireUsage: Decodable {
    let promptTokens: Int
    let completionTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

private extension JSONValue {
    var encodedJSONString: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
