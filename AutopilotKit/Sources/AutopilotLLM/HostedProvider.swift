import AutopilotCore
import Foundation

/// An `LLMProvider` that calls Mac Autopilot's own backend (the `llmProxy`
/// Firebase callable) instead of a model vendor directly. The backend holds the
/// provider key, enforces auth + usage limits, and forwards to the model.
///
/// Auth is injected as a token-provider closure (returning the current Firebase
/// ID token) so this stays free of the Firebase SDK and fully unit-testable; the
/// app wires the real token source when sign-in lands.
public struct HostedProvider: LLMProvider {
    public let identifier = "hosted"

    public typealias TokenProvider = @Sendable () async throws -> String?

    private let endpoint: URL
    private let tokenProvider: TokenProvider
    private let urlSession: URLSession
    private let retryPolicy: RetryPolicy
    private let requestTimeout: Double

    public init(
        endpoint: URL,
        tokenProvider: @escaping TokenProvider,
        urlSession: URLSession = .shared,
        retryPolicy: RetryPolicy = .standard,
        requestTimeout: Double = 60
    ) {
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.urlSession = urlSession
        self.retryPolicy = retryPolicy
        self.requestTimeout = max(1, requestTimeout)
    }

    public func send(_ request: LLMRequest) async throws -> LLMResponse {
        let token: String?
        do {
            token = try await tokenProvider()
        } catch {
            throw LLMError.service(message: "Sign in to use hosted AI.")
        }
        guard let token, !token.isEmpty else {
            throw LLMError.service(message: "Sign in to use hosted AI.")
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(RequestEnvelope(data: ProxyRequestWire(request)))
        } catch {
            throw LLMError.decodingFailed("request encoding failed: \(error)")
        }

        return try await retryPolicy.run { try await sendOnce(token: token, body: body) }
    }

    private func sendOnce(token: String, body: Data) async throws -> LLMResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
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

        if (200..<300).contains(http.statusCode) {
            do {
                return try JSONDecoder().decode(ResultEnvelope.self, from: data).result.toLLMResponse()
            } catch {
                throw LLMError.decodingFailed("response decoding failed: \(error)")
            }
        }

        // The callable convention returns a non-2xx status with an `error` body
        // whose message we already wrote to be user-facing.
        if
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
            let message = envelope.error.message,
            !message.isEmpty
        {
            throw LLMError.service(message: message)
        }
        if http.statusCode == 401 {
            throw LLMError.service(message: "Sign in to use hosted AI.")
        }
        throw LLMError.service(message: "The hosted AI service is unavailable (HTTP \(http.statusCode)).")
    }

    /// Map an `LLMRequest` into the backend's neutral message list. Tool-result
    /// images are relocated into a following user message (the neutral tool result
    /// carries text only), mirroring the OpenAI provider.
    fileprivate static func neutralMessages(from request: LLMRequest) -> [WireMessage] {
        var toolNames: [String: String] = [:]
        for message in request.messages {
            for block in message.content {
                if case .toolUse(let use) = block { toolNames[use.id] = use.name }
            }
        }

        var out: [WireMessage] = []
        for message in request.messages {
            let role = message.role == .assistant ? "assistant" : "user"
            var texts: [String] = []
            var images: [WireImage] = []
            var toolCalls: [WireToolCall] = []
            var toolResults: [WireToolResult] = []
            var relocatedImages: [WireImage] = []

            for block in message.content {
                switch block {
                case .text(let text):
                    texts.append(text)
                case .image(let image):
                    images.append(WireImage(image))
                case .toolUse(let use):
                    toolCalls.append(WireToolCall(id: use.id, name: use.name, input: use.input))
                case .toolResult(let result):
                    let text = result.content.compactMap { content -> String? in
                        if case .text(let value) = content { return value }
                        return nil
                    }.joined(separator: "\n")
                    toolResults.append(WireToolResult(
                        toolUseId: result.toolUseID,
                        name: toolNames[result.toolUseID] ?? "tool",
                        text: text,
                        isError: result.isError ? true : nil
                    ))
                    for content in result.content {
                        if case .image(let image) = content { relocatedImages.append(WireImage(image)) }
                    }
                }
            }

            if !toolResults.isEmpty {
                out.append(WireMessage(role: role, toolResults: toolResults))
            }

            let allImages = images + relocatedImages
            let joined = texts.joined(separator: "\n")
            if !joined.isEmpty || !allImages.isEmpty || !toolCalls.isEmpty {
                out.append(WireMessage(
                    role: role,
                    text: joined.isEmpty ? nil : joined,
                    images: allImages.isEmpty ? nil : allImages,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls
                ))
            }
        }
        return out
    }
}

// MARK: - Neutral wire format (request)

private struct RequestEnvelope: Encodable {
    let data: ProxyRequestWire
}

private struct ProxyRequestWire: Encodable {
    let model: String
    let system: String?
    let messages: [WireMessage]
    let tools: [WireTool]?
    let maxTokens: Int?

    init(_ request: LLMRequest) {
        model = request.model
        system = request.system
        messages = HostedProvider.neutralMessages(from: request)
        tools = request.tools.isEmpty
            ? nil
            : request.tools.map { WireTool(name: $0.name, description: $0.description, parameters: $0.inputSchema) }
        maxTokens = request.maxTokens
    }
}

private struct WireMessage: Encodable {
    let role: String
    var text: String?
    var images: [WireImage]?
    var toolCalls: [WireToolCall]?
    var toolResults: [WireToolResult]?
}

private struct WireImage: Encodable {
    let mediaType: String
    let dataBase64: String

    init(_ image: ImageBlock) {
        mediaType = image.mediaType
        dataBase64 = image.base64Data
    }
}

private struct WireToolCall: Encodable {
    let id: String
    let name: String
    let input: JSONValue
}

private struct WireToolResult: Encodable {
    let toolUseId: String
    let name: String
    let text: String
    let isError: Bool?
}

private struct WireTool: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

// MARK: - Neutral wire format (response)

private struct ResultEnvelope: Decodable {
    let result: ProxyResponseWire
}

private struct ErrorEnvelope: Decodable {
    let error: WireError
}

private struct WireError: Decodable {
    let message: String?
    let status: String?
}

private struct ProxyResponseWire: Decodable {
    let content: [WireContent]
    let stopReason: String
    let usage: WireUsage

    func toLLMResponse() -> LLMResponse {
        var blocks: [LLMContentBlock] = []
        for item in content {
            switch item.type {
            case "text":
                if let text = item.text, !text.isEmpty { blocks.append(.text(text)) }
            case "toolUse":
                if let id = item.id, let name = item.name {
                    blocks.append(.toolUse(ToolUse(id: id, name: name, input: item.input ?? .object([:]))))
                }
            default:
                break
            }
        }
        return LLMResponse(
            content: blocks,
            stopReason: Self.stopReason(stopReason),
            usage: LLMResponse.Usage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens)
        )
    }

    private static func stopReason(_ raw: String) -> LLMResponse.StopReason {
        switch raw {
        case "endTurn": return .endTurn
        case "toolUse": return .toolUse
        case "maxTokens": return .maxTokens
        default: return .other(raw)
        }
    }
}

private struct WireContent: Decodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: JSONValue?
}

private struct WireUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
}
