import AutopilotCore
import Foundation

/// An `LLMProvider` backed by Z.ai's OpenAI-compatible Chat Completions API.
public struct ZAIProvider: LLMProvider {
    public let identifier = "zai"

    private let apiKey: String
    private let endpoint: URL
    private let urlSession: URLSession
    private let retryPolicy: RetryPolicy
    /// Per-attempt request timeout, in seconds.
    private let requestTimeout: Double

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!,
        urlSession: URLSession = .shared,
        retryPolicy: RetryPolicy = .standard,
        requestTimeout: Double = 60
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.retryPolicy = retryPolicy
        self.requestTimeout = max(1, requestTimeout)
    }

    public func send(_ request: LLMRequest) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        let body: Data
        do {
            body = try JSONEncoder().encode(WireRequest(request))
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
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
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

// MARK: - Z.ai wire format (request)

private struct WireRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let tools: [WireTool]?
    let toolChoice: String?
    let maxTokens: Int
    let temperature: Double?
    let stream = false

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
        case temperature
        case stream
    }

    init(_ request: LLMRequest) {
        model = request.model
        messages = WireMessage.messages(from: request)
        if request.tools.isEmpty {
            tools = nil
            toolChoice = nil
        } else {
            tools = request.tools.map(WireTool.init)
            toolChoice = "auto"
        }
        maxTokens = request.maxTokens
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

private struct WireMessage: Encodable {
    let role: String
    let content: String?
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
            messages.append(WireMessage(role: "system", content: system))
        }

        for message in request.messages {
            messages.append(contentsOf: WireMessage.messages(from: message))
        }
        return messages
    }

    private static func messages(from message: LLMMessage) -> [WireMessage] {
        let visibleContent = message.content.compactMap(visibleText).joined(separator: "\n")
        let toolUses = message.content.compactMap { block -> ToolUse? in
            if case .toolUse(let use) = block { return use }
            return nil
        }
        let toolResults = message.content.compactMap { block -> ToolResult? in
            if case .toolResult(let result) = block { return result }
            return nil
        }

        var messages: [WireMessage] = []
        if !visibleContent.isEmpty || !toolUses.isEmpty {
            messages.append(WireMessage(
                role: message.role.rawValue,
                content: visibleContent.isEmpty ? nil : visibleContent,
                toolCalls: toolUses.map(WireRequestToolCall.init)
            ))
        }
        for result in toolResults {
            messages.append(WireMessage(
                role: "tool",
                content: toolResultText(result),
                toolCallID: result.toolUseID
            ))
        }
        return messages
    }

    private init(
        role: String,
        content: String?,
        toolCalls: [WireRequestToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls?.isEmpty == true ? nil : toolCalls
        self.toolCallID = toolCallID
    }

    private static func visibleText(_ block: LLMContentBlock) -> String? {
        switch block {
        case .text(let text):
            return text
        case .image(let image):
            return "[Image omitted: \(image.mediaType). This Z.ai text model cannot inspect screenshots.]"
        case .toolResult, .toolUse:
            return nil
        }
    }

    private static func toolResultText(_ result: ToolResult) -> String {
        let text = result.content.map { content in
            switch content {
            case .text(let text):
                return text
            case .image(let image):
                return "[Image omitted: \(image.mediaType). This Z.ai text model cannot inspect screenshots.]"
            }
        }.joined(separator: "\n")
        return result.isError ? "Error: \(text)" : text
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

// MARK: - Z.ai wire format (response)

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
        arguments = try container.decode(FlexibleArguments.self, forKey: .arguments).value
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
            } else {
                let data = Data(trimmed.utf8)
                value = try JSONDecoder().decode(JSONValue.self, from: data)
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
