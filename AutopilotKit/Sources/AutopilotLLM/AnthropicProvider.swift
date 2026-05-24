import AutopilotCore
import Foundation

/// An `LLMProvider` backed by Anthropic's Messages API.
///
/// Maps the provider-agnostic request/response types to Anthropic's wire
/// format, and enables prompt caching on the system prompt and tool
/// definitions (both static across an agent run).
public struct AnthropicProvider: LLMProvider {
    public let identifier = "anthropic"

    private let apiKey: String
    private let endpoint: URL
    private let apiVersion: String
    private let urlSession: URLSession
    private let retryPolicy: RetryPolicy
    /// Per-attempt request timeout, in seconds.
    private let requestTimeout: Double

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        apiVersion: String = "2023-06-01",
        urlSession: URLSession = .shared,
        retryPolicy: RetryPolicy = .standard,
        requestTimeout: Double = 60
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.apiVersion = apiVersion
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
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
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
                throw LLMError.authenticationFailed(provider: "Anthropic")
            }
            let body = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw LLMError.http(status: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(WireResponse.self, from: data).toLLMResponse()
        } catch {
            throw LLMError.decodingFailed("response decoding failed: \(error)")
        }
    }
}

// MARK: - Anthropic wire format (request)

private struct WireCacheControl: Encodable {
    let type: String
    static let ephemeral = WireCacheControl(type: "ephemeral")
}

private struct WireRequest: Encodable {
    let model: String
    let maxTokens: Int
    let temperature: Double?
    let system: [WireSystemBlock]?
    let messages: [WireMessage]
    let tools: [WireTool]?

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case temperature
        case system
        case messages
        case tools
    }

    init(_ request: LLMRequest) {
        model = request.model
        maxTokens = request.maxTokens
        temperature = request.temperature
        if let system = request.system, !system.isEmpty {
            self.system = [WireSystemBlock(text: system, cacheControl: .ephemeral)]
        } else {
            system = nil
        }
        messages = request.messages.map(WireMessage.init)
        if request.tools.isEmpty {
            tools = nil
        } else {
            var wireTools = request.tools.map(WireTool.init)
            // Cache the static tool definitions by marking the final tool.
            wireTools[wireTools.count - 1].cacheControl = .ephemeral
            tools = wireTools
        }
    }
}

private struct WireSystemBlock: Encodable {
    let type = "text"
    let text: String
    var cacheControl: WireCacheControl?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case cacheControl = "cache_control"
    }
}

private struct WireTool: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    var cacheControl: WireCacheControl?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
        case cacheControl = "cache_control"
    }

    init(_ definition: ToolDefinition) {
        name = definition.name
        description = definition.description
        inputSchema = definition.inputSchema
        cacheControl = nil
    }
}

private struct WireMessage: Encodable {
    let role: String
    let content: [WireContentBlock]

    init(_ message: LLMMessage) {
        role = message.role.rawValue
        content = message.content.map(WireContentBlock.init)
    }
}

private struct WireImageSource: Encodable {
    let type = "base64"
    let mediaType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }
}

private enum WireContentBlock: Encodable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(id: String, content: [WireToolResultPart], isError: Bool)
    case image(mediaType: String, data: String)

    init(_ block: LLMContentBlock) {
        switch block {
        case .text(let text):
            self = .text(text)
        case .toolUse(let use):
            self = .toolUse(id: use.id, name: use.name, input: use.input)
        case .toolResult(let result):
            self = .toolResult(
                id: result.toolUseID,
                content: result.content.map(WireToolResultPart.init),
                isError: result.isError
            )
        case .image(let image):
            self = .image(mediaType: image.mediaType, data: image.base64Data)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case toolUseID = "tool_use_id"
        case content
        case isError = "is_error"
        case source
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let id, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(id, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .isError)
        case .image(let mediaType, let data):
            try container.encode("image", forKey: .type)
            try container.encode(WireImageSource(mediaType: mediaType, data: data), forKey: .source)
        }
    }
}

private enum WireToolResultPart: Encodable {
    case text(String)
    case image(mediaType: String, data: String)

    init(_ content: ToolResult.Content) {
        switch content {
        case .text(let text):
            self = .text(text)
        case .image(let image):
            self = .image(mediaType: image.mediaType, data: image.base64Data)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case source
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let mediaType, let data):
            try container.encode("image", forKey: .type)
            try container.encode(WireImageSource(mediaType: mediaType, data: data), forKey: .source)
        }
    }
}

// MARK: - Anthropic wire format (response)

private struct WireResponse: Decodable {
    let content: [WireResponseBlock]
    let stopReason: String?
    let usage: WireUsage

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
        case usage
    }

    func toLLMResponse() -> LLMResponse {
        let blocks = content.compactMap { $0.toContentBlock() }
        let reason: LLMResponse.StopReason
        switch stopReason {
        case "end_turn": reason = .endTurn
        case "tool_use": reason = .toolUse
        case "max_tokens": reason = .maxTokens
        case let other?: reason = .other(other)
        case nil: reason = .other("unspecified")
        }
        return LLMResponse(
            content: blocks,
            stopReason: reason,
            usage: LLMResponse.Usage(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationInputTokens: usage.cacheCreationInputTokens,
                cacheReadInputTokens: usage.cacheReadInputTokens
            )
        )
    }
}

private struct WireUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    /// Present only when prompt caching wrote or read tokens; absent otherwise.
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheCreationInputTokens =
            try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        cacheReadInputTokens =
            try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
    }
}

private struct WireResponseBlock: Decodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: JSONValue?

    func toContentBlock() -> LLMContentBlock? {
        switch type {
        case "text":
            return text.map(LLMContentBlock.text)
        case "tool_use":
            guard let id, let name else { return nil }
            return .toolUse(ToolUse(id: id, name: name, input: input ?? .object([:])))
        default:
            return nil
        }
    }
}
