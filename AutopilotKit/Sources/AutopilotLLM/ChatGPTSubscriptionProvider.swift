import AutopilotCore
import Foundation

/// ChatGPT Plus/Pro access through the OpenAI Codex subscription transport.
///
/// This is the app-owned version of the subscription pattern: OAuth tokens live
/// in Mac Autopilot's Keychain item, and the provider talks directly to the
/// ChatGPT Codex Responses endpoint instead of shelling out to another product.
public struct ChatGPTSubscriptionProvider: LLMProvider {
    public typealias CredentialProvider =
        @Sendable (SubscriptionOAuthProviderID) async throws -> SubscriptionOAuthCredential?

    public let identifier = "chatgpt-account"

    private let credentialProvider: CredentialProvider
    private let endpoint: URL
    private let urlSession: URLSession
    private let retryPolicy: RetryPolicy
    private let requestTimeout: Double

    public init(
        credentialProvider: @escaping CredentialProvider = SubscriptionOAuthCredentialProvider.keychain(),
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
        urlSession: URLSession = .shared,
        retryPolicy: RetryPolicy = .standard,
        requestTimeout: Double = 120
    ) {
        self.credentialProvider = credentialProvider
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.retryPolicy = retryPolicy
        self.requestTimeout = max(1, requestTimeout)
    }

    public func send(_ request: LLMRequest) async throws -> LLMResponse {
        guard let credential = try await credentialProvider(.chatGPTCodex) else {
            throw LLMError.service(message: "Sign in with ChatGPT subscription to use your existing account.")
        }
        guard let accountID = credential.accountID, !accountID.isEmpty else {
            throw LLMError.service(message: "ChatGPT subscription sign-in did not include an account id. Sign in again.")
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(CodexWireRequest(request))
        } catch {
            throw LLMError.decodingFailed("request encoding failed: \(error)")
        }

        return try await retryPolicy.run {
            try await sendOnce(body: body, credential: credential, accountID: accountID)
        }
    }

    private func sendOnce(
        body: Data,
        credential: SubscriptionOAuthCredential,
        accountID: String
    ) async throws -> LLMResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "authorization")
        urlRequest.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        urlRequest.setValue("mac-autopilot", forHTTPHeaderField: "originator")
        urlRequest.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
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
                throw LLMError.authenticationFailed(provider: "ChatGPT subscription")
            }
            let body = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw LLMError.http(status: http.statusCode, body: body)
        }

        return try CodexStreamDecoder.decode(data)
    }
}

public struct AnthropicSubscriptionProvider: LLMProvider {
    public typealias CredentialProvider =
        @Sendable (SubscriptionOAuthProviderID) async throws -> SubscriptionOAuthCredential?

    public let identifier = "anthropic-subscription"

    private let credentialProvider: CredentialProvider
    private let endpoint: URL
    private let urlSession: URLSession
    private let retryPolicy: RetryPolicy
    private let requestTimeout: Double

    public init(
        credentialProvider: @escaping CredentialProvider = SubscriptionOAuthCredentialProvider.keychain(),
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        urlSession: URLSession = .shared,
        retryPolicy: RetryPolicy = .standard,
        requestTimeout: Double = 120
    ) {
        self.credentialProvider = credentialProvider
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.retryPolicy = retryPolicy
        self.requestTimeout = max(1, requestTimeout)
    }

    public func send(_ request: LLMRequest) async throws -> LLMResponse {
        guard let credential = try await credentialProvider(.anthropic) else {
            throw LLMError.service(message: "Sign in with Claude subscription to use your existing account.")
        }

        var resolved = request
        if resolved.model == "automatic" {
            resolved.model = LLMProviderDescriptor.anthropic.defaultModel
        }

        return try await AnthropicProvider(
            oauthToken: credential.accessToken,
            identifier: identifier,
            endpoint: endpoint,
            urlSession: urlSession,
            retryPolicy: retryPolicy,
            requestTimeout: requestTimeout
        ).send(resolved)
    }
}

// MARK: - Request

private struct CodexWireRequest: Encodable {
    let model: String
    let store = false
    let stream = true
    let instructions: String
    let input: [CodexInputItem]
    let text = CodexTextOptions(verbosity: "low")
    let toolChoice = "auto"
    let parallelToolCalls = true
    let tools: [CodexTool]?

    enum CodingKeys: String, CodingKey {
        case model
        case store
        case stream
        case instructions
        case input
        case text
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case tools
    }

    init(_ request: LLMRequest) {
        model = request.model == "automatic" ? "gpt-5.4" : request.model
        instructions = request.system?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "You are a helpful assistant."
        input = CodexInputItem.items(from: request)
        tools = request.tools.isEmpty ? nil : request.tools.map(CodexTool.init)
    }
}

private struct CodexTextOptions: Encodable {
    let verbosity: String
}

private enum CodexInputItem: Encodable {
    case message(role: String, content: [CodexContentPart])
    case functionCall(id: String?, callID: String, name: String, arguments: String)
    case functionCallOutput(callID: String, output: String)

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case callID = "call_id"
        case name
        case arguments
        case role
        case content
        case output
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let role, let content):
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        case .functionCall(let id, let callID, let name, let arguments):
            try container.encode("function_call", forKey: .type)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(callID, forKey: .callID)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        case .functionCallOutput(let callID, let output):
            try container.encode("function_call_output", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(output, forKey: .output)
        }
    }

    static func items(from request: LLMRequest) -> [CodexInputItem] {
        request.messages.flatMap(items(from:))
    }

    private static func items(from message: LLMMessage) -> [CodexInputItem] {
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

        var items: [CodexInputItem] = []
        let text = texts.joined(separator: "\n")
        if !text.isEmpty || !images.isEmpty {
            let role = message.role == .assistant ? "assistant" : "user"
            items.append(.message(role: role, content: CodexContentPart.parts(
                text: text,
                images: images,
                role: message.role
            )))
        }
        items.append(contentsOf: toolUses.map {
            .functionCall(
                id: $0.id.hasPrefix("fc_") ? $0.id : nil,
                callID: $0.id,
                name: $0.name,
                arguments: $0.input.encodedJSONString
            )
        })
        items.append(contentsOf: toolResults.map {
            .functionCallOutput(callID: $0.toolUseID, output: Self.toolResultText($0))
        })
        return items
    }

    private static func toolResultText(_ result: ToolResult) -> String {
        let text = result.content.compactMap { part -> String? in
            switch part {
            case .text(let text): text
            case .image: nil
            }
        }.joined(separator: "\n")
        if text.isEmpty {
            return result.isError ? "Error: (image omitted)" : "(image omitted)"
        }
        return result.isError ? "Error: \(text)" : text
    }
}

private enum CodexContentPart: Encodable {
    case inputText(String)
    case outputText(String)
    case inputImage(String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case annotations
        case detail
        case imageURL = "image_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inputText(let text):
            try container.encode("input_text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .outputText(let text):
            try container.encode("output_text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode([String](), forKey: .annotations)
        case .inputImage(let imageURL):
            try container.encode("input_image", forKey: .type)
            try container.encode("auto", forKey: .detail)
            try container.encode(imageURL, forKey: .imageURL)
        }
    }

    static func parts(text: String, images: [ImageBlock], role: LLMRole) -> [CodexContentPart] {
        var parts: [CodexContentPart] = []
        if !text.isEmpty {
            parts.append(role == .assistant ? .outputText(text) : .inputText(text))
        }
        if role == .user {
            parts.append(contentsOf: images.map { .inputImage(dataURL(for: $0)) })
        }
        return parts
    }

    private static func dataURL(for image: ImageBlock) -> String {
        "data:\(image.mediaType);base64,\(image.base64Data)"
    }
}

private struct CodexTool: Encodable {
    let type = "function"
    let name: String
    let description: String
    let parameters: JSONValue
    let strict = false

    init(_ definition: ToolDefinition) {
        name = definition.name
        description = definition.description
        parameters = definition.inputSchema
    }
}

// MARK: - Stream decoding

private enum CodexStreamDecoder {
    static func decode(_ data: Data) throws -> LLMResponse {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let payloads = ssePayloads(in: raw)
        if payloads.isEmpty {
            return try decodeJSONResponse(data)
        }

        var text = ""
        var activeToolCallID: String?
        var tools: [String: ToolAccumulator] = [:]
        var orderedToolIDs: [String] = []
        var inputTokens = 0
        var outputTokens = 0
        var status: String?

        for payload in payloads {
            guard
                let data = payload.data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = object["type"] as? String
            else {
                continue
            }

            switch type {
            case "response.output_text.delta":
                text += object["delta"] as? String ?? ""
            case "response.output_item.added", "response.output_item.done":
                if let item = object["item"] as? [String: Any],
                   item["type"] as? String == "function_call" {
                    let callID = item["call_id"] as? String
                        ?? item["id"] as? String
                        ?? "call_\(orderedToolIDs.count + 1)"
                    activeToolCallID = callID
                    if tools[callID] == nil {
                        orderedToolIDs.append(callID)
                    }
                    tools[callID] = ToolAccumulator(
                        id: callID,
                        name: item["name"] as? String ?? "tool",
                        arguments: item["arguments"] as? String ?? tools[callID]?.arguments ?? ""
                    )
                }
            case "response.function_call_arguments.delta":
                if let activeToolCallID {
                    tools[activeToolCallID]?.arguments += object["delta"] as? String ?? ""
                }
            case "response.function_call_arguments.done":
                if let activeToolCallID {
                    let existing = tools[activeToolCallID]?.arguments ?? ""
                    tools[activeToolCallID]?.arguments = object["arguments"] as? String ?? existing
                }
            case "response.completed", "response.done", "response.incomplete":
                if let response = object["response"] as? [String: Any] {
                    status = response["status"] as? String ?? status
                    if let usage = response["usage"] as? [String: Any] {
                        inputTokens = usage["input_tokens"] as? Int ?? inputTokens
                        outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                    }
                }
            case "response.failed", "error":
                throw LLMError.service(message: codexErrorMessage(from: object))
            default:
                continue
            }
        }

        let toolUses = orderedToolIDs.compactMap { tools[$0]?.toolUse() }
        var content: [LLMContentBlock] = []
        if !text.isEmpty {
            content.append(.text(text))
        }
        content.append(contentsOf: toolUses.map(LLMContentBlock.toolUse))

        return LLMResponse(
            content: content.isEmpty ? [.text("")] : content,
            stopReason: stopReason(status: status, hasTools: !toolUses.isEmpty),
            usage: LLMResponse.Usage(inputTokens: inputTokens, outputTokens: outputTokens)
        )
    }

    private static func decodeJSONResponse(_ data: Data) throws -> LLMResponse {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let output = object?["output"] as? [[String: Any]] ?? []
        let text = output.compactMap { item -> String? in
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]] else {
                return nil
            }
            return content.compactMap { $0["text"] as? String }.joined()
        }.joined()
        let usage = object?["usage"] as? [String: Any]
        return LLMResponse(
            content: [.text(text)],
            stopReason: .endTurn,
            usage: LLMResponse.Usage(
                inputTokens: usage?["input_tokens"] as? Int ?? 0,
                outputTokens: usage?["output_tokens"] as? Int ?? 0
            )
        )
    }

    private static func ssePayloads(in raw: String) -> [String] {
        var payloads: [String] = []
        var current: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            if line.isEmpty {
                if !current.isEmpty {
                    payloads.append(current.joined(separator: "\n"))
                    current = []
                }
                continue
            }
            if line.hasPrefix("data:") {
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if value != "[DONE]" {
                    current.append(value)
                }
            }
        }
        if !current.isEmpty {
            payloads.append(current.joined(separator: "\n"))
        }
        return payloads
    }

    private static func stopReason(status: String?, hasTools: Bool) -> LLMResponse.StopReason {
        if hasTools { return .toolUse }
        switch status {
        case "incomplete": return .maxTokens
        case "failed", "cancelled": return .other(status ?? "failed")
        default: return .endTurn
        }
    }

    private static func codexErrorMessage(from object: [String: Any]) -> String {
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        if let response = object["response"] as? [String: Any],
           let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return "ChatGPT subscription request failed."
    }
}

private struct ToolAccumulator {
    let id: String
    var name: String
    var arguments: String

    func toolUse() -> ToolUse {
        let input = (try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))) ?? .object([:])
        return ToolUse(id: id, name: name, input: input)
    }
}

private extension JSONValue {
    var encodedJSONString: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
