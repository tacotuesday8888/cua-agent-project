import AutopilotCore
import Foundation
import Testing
@testable import AutopilotLLM

struct LLMResponseTests {
    @Test func extractsToolUsesAndText() {
        let response = LLMResponse(
            content: [
                .text("Working on it."),
                .toolUse(ToolUse(id: "t1", name: "click",
                                 input: ["element_index": 3]))
            ],
            stopReason: .toolUse,
            usage: .init(inputTokens: 10, outputTokens: 5)
        )
        #expect(response.text == "Working on it.")
        #expect(response.toolUses.count == 1)
        #expect(response.toolUses.first?.name == "click")
        #expect(response.toolUses.first?.input["element_index"]?.intValue == 3)
    }

    @Test func textOnlyResponseHasNoToolUses() {
        let response = LLMResponse(
            content: [.text("done")],
            stopReason: .endTurn,
            usage: .init(inputTokens: 1, outputTokens: 1)
        )
        #expect(response.toolUses.isEmpty)
    }

    @Test func totalInputTokensSumsCacheTokens() {
        let usage = LLMResponse.Usage(
            inputTokens: 10,
            outputTokens: 4,
            cacheCreationInputTokens: 100,
            cacheReadInputTokens: 250
        )
        #expect(usage.totalInputTokens == 360)
    }

    @Test func totalInputTokensDefaultsToFreshInputWithoutCaching() {
        let usage = LLMResponse.Usage(inputTokens: 12, outputTokens: 3)
        #expect(usage.cacheCreationInputTokens == 0)
        #expect(usage.cacheReadInputTokens == 0)
        #expect(usage.totalInputTokens == 12)
    }
}

struct LLMProviderDescriptorTests {
    @Test func knownProviderCapabilitiesAreExplicit() {
        #expect(LLMProviderDescriptor.zai.identifier == "zai")
        #expect(LLMProviderDescriptor.zai.defaultModel == "glm-4.7-flash")
        #expect(LLMProviderDescriptor.zai.supportsToolCalls)
        #expect(!LLMProviderDescriptor.zai.supportsImageInput)
        #expect(!LLMProviderDescriptor.zai.supportsPromptCaching)
        #expect(LLMProviderDescriptor.zai.apiKeyEnvironment == "ZAI_API_KEY")
        #expect(LLMProviderDescriptor.zai.keychainAccount == "AutopilotZAIAPIKey")

        #expect(LLMProviderDescriptor.anthropic.identifier == "anthropic")
        #expect(LLMProviderDescriptor.anthropic.supportsToolCalls)
        #expect(LLMProviderDescriptor.anthropic.supportsImageInput)
        #expect(LLMProviderDescriptor.anthropic.supportsPromptCaching)
        #expect(LLMProviderDescriptor.anthropic.apiKeyEnvironment == "ANTHROPIC_API_KEY")
        #expect(LLMProviderDescriptor.anthropic.keychainAccount == "AutopilotAnthropicAPIKey")
    }
}

struct LLMErrorTests {
    @Test func authenticationFailedMessageNamesTheProviderAndIsActionable() {
        #expect(
            LLMError.authenticationFailed(provider: "Z.ai").errorDescription
                == "The saved Z.ai API key is invalid or expired. Update the API key and run again."
        )
        #expect(
            LLMError.authenticationFailed(provider: "Anthropic").errorDescription
                == "The saved Anthropic API key is invalid or expired. Update the API key and run again."
        )
    }

    @Test func authenticationFailedDoesNotLeakRawProviderBody() {
        // Unlike `.http`, the 401 path must not surface raw provider JSON or a
        // bare status code to the user.
        let message = LLMError.authenticationFailed(provider: "Z.ai").errorDescription ?? ""
        #expect(!message.contains("{"))
        #expect(!message.contains("HTTP"))
    }
}

struct ScriptedLLMProviderTests {
    @Test func returnsResponsesInOrderAndRecordsRequests() async throws {
        let one = LLMResponse(content: [.text("one")], stopReason: .endTurn,
                              usage: .init(inputTokens: 1, outputTokens: 1))
        let two = LLMResponse(content: [.text("two")], stopReason: .endTurn,
                              usage: .init(inputTokens: 1, outputTokens: 1))
        let provider = ScriptedLLMProvider([one, two])

        let first = try await provider.send(LLMRequest(model: "m", messages: [.user("a")]))
        let second = try await provider.send(LLMRequest(model: "m", messages: [.user("b")]))

        #expect(first.text == "one")
        #expect(second.text == "two")
        let recorded = await provider.requests
        #expect(recorded.count == 2)
    }

    @Test func throwsWhenExhausted() async {
        let provider = ScriptedLLMProvider([])
        do {
            _ = try await provider.send(LLMRequest(model: "m", messages: []))
            Issue.record("expected the provider to throw when exhausted")
        } catch {
            #expect(error is LLMError)
        }
    }
}

@Suite(.serialized)
struct AnthropicProviderTests {
    @Test func decodesAnthropicResponse() async throws {
        let canned = """
        {
          "id": "msg_1",
          "type": "message",
          "role": "assistant",
          "content": [
            {"type": "text", "text": "Hi"},
            {"type": "tool_use", "id": "tu_1", "name": "done", "input": {"summary": "ok"}}
          ],
          "stop_reason": "tool_use",
          "usage": {"input_tokens": 12, "output_tokens": 7}
        }
        """
        StubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(canned.utf8))
        }
        defer { StubURLProtocol.responder = nil }

        let response = try await makeProvider().send(
            LLMRequest(model: "claude-test", system: "sys", messages: [.user("hello")])
        )
        #expect(response.stopReason == .toolUse)
        #expect(response.text == "Hi")
        #expect(response.toolUses.first?.name == "done")
        #expect(response.usage.inputTokens == 12)
        #expect(response.usage.outputTokens == 7)
        // A response without cache fields decodes with zeroed cache usage.
        #expect(response.usage.cacheCreationInputTokens == 0)
        #expect(response.usage.cacheReadInputTokens == 0)
        #expect(response.usage.totalInputTokens == 12)
    }

    @Test func decodesPromptCacheUsage() async throws {
        let canned = """
        {
          "id": "msg_2",
          "type": "message",
          "role": "assistant",
          "content": [{"type": "text", "text": "Hi"}],
          "stop_reason": "end_turn",
          "usage": {
            "input_tokens": 8,
            "output_tokens": 5,
            "cache_creation_input_tokens": 200,
            "cache_read_input_tokens": 1500
          }
        }
        """
        StubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(canned.utf8))
        }
        defer { StubURLProtocol.responder = nil }

        let response = try await makeProvider().send(
            LLMRequest(model: "claude-test", system: "sys", messages: [.user("hello")])
        )
        #expect(response.usage.inputTokens == 8)
        #expect(response.usage.cacheCreationInputTokens == 200)
        #expect(response.usage.cacheReadInputTokens == 1500)
        // The billed input is the fresh tokens plus both cache figures.
        #expect(response.usage.totalInputTokens == 1708)
    }

    @Test func surfacesHTTPErrors() async {
        StubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 400,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"error":"bad request"}"#.utf8))
        }
        defer { StubURLProtocol.responder = nil }

        do {
            _ = try await makeProvider().send(LLMRequest(model: "m", messages: [.user("x")]))
            Issue.record("expected an HTTP error to be thrown")
        } catch {
            #expect(error is LLMError)
        }
    }

    @Test func missingAPIKeyThrows() async {
        do {
            _ = try await AnthropicProvider(apiKey: "")
                .send(LLMRequest(model: "m", messages: [.user("x")]))
            Issue.record("expected a missing-API-key error")
        } catch {
            #expect(error as? LLMError == .missingAPIKey)
        }
    }

    @Test func retriesTransientServerError() async throws {
        let counter = LockedCounter()
        StubURLProtocol.responder = { request in
            if counter.increment() == 1 {
                let http = HTTPURLResponse(url: request.url!, statusCode: 503,
                                           httpVersion: nil, headerFields: nil)!
                return (http, Data(#"{"error":"unavailable"}"#.utf8))
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(Self.cannedResponse.utf8))
        }
        defer { StubURLProtocol.responder = nil }

        let response = try await makeProvider(
            retryPolicy: RetryPolicy(maxRetries: 1, baseDelaySeconds: 0)
        ).send(LLMRequest(model: "claude-test", messages: [.user("hello")]))

        #expect(response.text == "Hi")
        #expect(counter.value == 2)
    }

    @Test func stopsRetryingAfterLimit() async {
        let counter = LockedCounter()
        StubURLProtocol.responder = { request in
            counter.increment()
            let http = HTTPURLResponse(url: request.url!, statusCode: 500,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"error":"boom"}"#.utf8))
        }
        defer { StubURLProtocol.responder = nil }

        do {
            _ = try await makeProvider(
                retryPolicy: RetryPolicy(maxRetries: 1, baseDelaySeconds: 0)
            ).send(LLMRequest(model: "claude-test", messages: [.user("hello")]))
            Issue.record("expected an HTTP error after retry exhaustion")
        } catch {
            #expect(error is LLMError)
            #expect(counter.value == 2)
        }
    }

    @Test func doesNotRetryClientError() async {
        let counter = LockedCounter()
        StubURLProtocol.responder = { request in
            counter.increment()
            let http = HTTPURLResponse(url: request.url!, statusCode: 400,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"error":"bad request"}"#.utf8))
        }
        defer { StubURLProtocol.responder = nil }

        do {
            _ = try await makeProvider(
                retryPolicy: RetryPolicy(maxRetries: 2, baseDelaySeconds: 0)
            ).send(LLMRequest(model: "claude-test", messages: [.user("hello")]))
            Issue.record("expected a client error to be thrown")
        } catch {
            #expect(error is LLMError)
            // A 4xx is not transient — it must not be retried.
            #expect(counter.value == 1)
        }
    }

    @Test func invalidAPIKeyReturnsFriendlyAuthErrorWithoutRetrying() async {
        let counter = LockedCounter()
        StubURLProtocol.responder = { request in
            counter.increment()
            let http = HTTPURLResponse(url: request.url!, statusCode: 401,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"type":"error","error":{"type":"authentication_error"}}"#.utf8))
        }
        defer { StubURLProtocol.responder = nil }

        do {
            _ = try await makeProvider(
                retryPolicy: RetryPolicy(maxRetries: 2, baseDelaySeconds: 0)
            ).send(LLMRequest(model: "claude-test", messages: [.user("hello")]))
            Issue.record("expected an authentication error")
        } catch {
            // A 401 maps to a plain, provider-named message, not raw JSON, and
            // is not retried (a bad key will not fix itself).
            #expect(error as? LLMError == .authenticationFailed(provider: "Anthropic"))
            #expect(counter.value == 1)
        }
    }

    @Test func encodesAnthropicRequestWithPromptCaching() async throws {
        StubURLProtocol.capturedRequest = nil
        StubURLProtocol.capturedBody = nil
        StubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(Self.cannedResponse.utf8))
        }
        defer {
            StubURLProtocol.responder = nil
            StubURLProtocol.capturedRequest = nil
            StubURLProtocol.capturedBody = nil
        }

        let tool = ToolDefinition(
            name: "done",
            description: "Finish the task.",
            inputSchema: [
                "type": "object",
                "properties": ["summary": ["type": "string"]],
                "required": ["summary"]
            ]
        )
        _ = try await makeProvider().send(LLMRequest(
            model: "claude-test",
            system: "sys",
            messages: [
                .user("hello"),
                LLMMessage(role: .assistant, content: [
                    .text("I will finish."),
                    .toolUse(ToolUse(id: "tu_1", name: "done", input: ["summary": "ok"]))
                ]),
                LLMMessage(role: .user, content: [
                    .toolResult(ToolResult(toolUseID: "tu_1", text: "Done."))
                ])
            ],
            tools: [tool],
            maxTokens: 256
        ))

        let request = try #require(StubURLProtocol.capturedRequest)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let body = try #require(StubURLProtocol.capturedBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let payload = try #require(json)

        #expect(payload["model"] as? String == "claude-test")
        #expect(payload["max_tokens"] as? Int == 256)

        // The system prompt is a text-block array carrying a cache breakpoint.
        let system = try #require(payload["system"] as? [[String: Any]])
        #expect(system.first?["type"] as? String == "text")
        #expect(system.first?["text"] as? String == "sys")
        let systemCache = system.first?["cache_control"] as? [String: Any]
        #expect(systemCache?["type"] as? String == "ephemeral")

        // Messages keep Anthropic's tool_use / tool_result block shapes.
        let messages = try #require(payload["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantBlocks.contains {
            $0["type"] as? String == "tool_use" && $0["id"] as? String == "tu_1"
        })
        let toolResultBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(toolResultBlocks.first?["type"] as? String == "tool_result")
        #expect(toolResultBlocks.first?["tool_use_id"] as? String == "tu_1")

        // The final tool definition carries the other cache breakpoint.
        let tools = try #require(payload["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "done")
        #expect(tools.first?["input_schema"] != nil)
        let toolCache = tools.last?["cache_control"] as? [String: Any]
        #expect(toolCache?["type"] as? String == "ephemeral")
    }

    private static let cannedResponse = """
    {
      "id": "msg_1",
      "type": "message",
      "role": "assistant",
      "content": [{"type": "text", "text": "Hi"}],
      "stop_reason": "end_turn",
      "usage": {"input_tokens": 1, "output_tokens": 1}
    }
    """

    private func makeProvider(retryPolicy: RetryPolicy = .standard) -> AnthropicProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AnthropicProvider(apiKey: "test-key",
                                 urlSession: URLSession(configuration: config),
                                 retryPolicy: retryPolicy)
    }
}

@Suite(.serialized)
struct ZAIProviderTests {
    @Test func decodesZAIResponse() async throws {
        let canned = """
        {
          "id": "chatcmpl-1",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "content": "Hi",
                "tool_calls": [
                  {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "done",
                      "arguments": "{\\"summary\\":\\"ok\\"}"
                    }
                  }
                ]
              },
              "finish_reason": "tool_calls"
            }
          ],
          "usage": {
            "prompt_tokens": 12,
            "completion_tokens": 7,
            "total_tokens": 19
          }
        }
        """
        ZAIStubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(canned.utf8))
        }
        defer { ZAIStubURLProtocol.responder = nil }

        let response = try await makeProvider().send(
            LLMRequest(model: "glm-4.7-flash", system: "sys", messages: [.user("hello")])
        )
        #expect(response.stopReason == .toolUse)
        #expect(response.text == "Hi")
        #expect(response.toolUses.first?.id == "call_1")
        #expect(response.toolUses.first?.name == "done")
        #expect(response.toolUses.first?.input["summary"]?.stringValue == "ok")
        #expect(response.usage.inputTokens == 12)
        #expect(response.usage.outputTokens == 7)
    }

    @Test func malformedToolArgumentsDecodeAsEmptyInput() async throws {
        // A smaller model can emit broken JSON in a tool call's arguments. The
        // call must still decode (with empty input) so the agent can return a
        // recoverable tool error, instead of the whole run dying on decode.
        let canned = """
        {
          "choices": [{
            "index": 0,
            "message": {
              "role": "assistant",
              "tool_calls": [{
                "id": "call_1",
                "type": "function",
                "function": { "name": "click", "arguments": "{ not valid json" }
              }]
            },
            "finish_reason": "tool_calls"
          }],
          "usage": { "prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2 }
        }
        """
        ZAIStubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(canned.utf8))
        }
        defer { ZAIStubURLProtocol.responder = nil }

        let response = try await makeProvider().send(
            LLMRequest(model: "glm-4.7-flash", messages: [.user("x")])
        )
        #expect(response.toolUses.count == 1)
        #expect(response.toolUses.first?.name == "click")
        #expect(response.toolUses.first?.input.objectValue?.isEmpty == true)
    }

    @Test func missingToolArgumentsDecodeAsEmptyInput() async throws {
        // Some models omit `arguments` entirely for a no-argument tool call.
        let canned = """
        {
          "choices": [{
            "index": 0,
            "message": {
              "role": "assistant",
              "tool_calls": [{
                "id": "call_1",
                "type": "function",
                "function": { "name": "list_apps" }
              }]
            },
            "finish_reason": "tool_calls"
          }],
          "usage": { "prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2 }
        }
        """
        ZAIStubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(canned.utf8))
        }
        defer { ZAIStubURLProtocol.responder = nil }

        let response = try await makeProvider().send(
            LLMRequest(model: "glm-4.7-flash", messages: [.user("x")])
        )
        #expect(response.toolUses.count == 1)
        #expect(response.toolUses.first?.name == "list_apps")
        #expect(response.toolUses.first?.input.objectValue?.isEmpty == true)
    }

    @Test func encodesOpenAIStyleToolMessages() async throws {
        let canned = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "Finished"
              },
              "finish_reason": "stop"
            }
          ],
          "usage": {
            "prompt_tokens": 1,
            "completion_tokens": 1,
            "total_tokens": 2
          }
        }
        """
        ZAIStubURLProtocol.capturedRequest = nil
        ZAIStubURLProtocol.capturedBody = nil
        ZAIStubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(canned.utf8))
        }
        defer {
            ZAIStubURLProtocol.responder = nil
            ZAIStubURLProtocol.capturedRequest = nil
            ZAIStubURLProtocol.capturedBody = nil
        }

        let tool = ToolDefinition(
            name: "done",
            description: "Finish the task.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "summary": ["type": "string"]
                ],
                "required": ["summary"]
            ]
        )
        _ = try await makeProvider().send(LLMRequest(
            model: "glm-4.7-flash",
            system: "sys",
            messages: [
                .user("hello"),
                LLMMessage(role: .assistant, content: [
                    .text("I will finish."),
                    .toolUse(ToolUse(id: "call_1", name: "done", input: ["summary": "ok"]))
                ]),
                LLMMessage(role: .user, content: [
                    .toolResult(ToolResult(toolUseID: "call_1", text: "Done."))
                ])
            ],
            tools: [tool],
            maxTokens: 128,
            temperature: 0.5
        ))

        let request = try #require(ZAIStubURLProtocol.capturedRequest)
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer test-key")
        let body = try #require(ZAIStubURLProtocol.capturedBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let payload = try #require(json)

        #expect(payload["model"] as? String == "glm-4.7-flash")
        #expect(payload["tool_choice"] as? String == "auto")
        #expect(payload["max_tokens"] as? Int == 128)
        #expect(payload["temperature"] as? Double == 0.5)

        let messages = try #require(payload["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(messages[0]["content"] as? String == "sys")
        #expect(messages[3]["tool_call_id"] as? String == "call_1")
        #expect(messages[3]["content"] as? String == "Done.")

        let assistantToolCalls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        let function = try #require(assistantToolCalls.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "done")
        #expect(function["arguments"] as? String == #"{"summary":"ok"}"#)

        let tools = try #require(payload["tools"] as? [[String: Any]])
        let toolFunction = try #require(tools.first?["function"] as? [String: Any])
        #expect(tools.first?["type"] as? String == "function")
        #expect(toolFunction["name"] as? String == "done")
    }

    @Test func retriesRateLimitedResponse() async throws {
        let counter = LockedCounter()
        ZAIStubURLProtocol.responder = { request in
            if counter.increment() == 1 {
                let http = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["retry-after": "0"]
                )!
                return (http, Data(#"{"error":{"message":"busy"}}"#.utf8))
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(Self.cannedZAIResponse.utf8))
        }
        defer { ZAIStubURLProtocol.responder = nil }

        let response = try await makeProvider(
            retryPolicy: RetryPolicy(maxRetries: 1, baseDelaySeconds: 0)
        ).send(LLMRequest(model: "glm-4.7-flash", messages: [.user("hello")]))

        #expect(response.text == "Hi")
        #expect(counter.value == 2)
    }

    @Test func retriesTransientServerError() async throws {
        let counter = LockedCounter()
        ZAIStubURLProtocol.responder = { request in
            if counter.increment() == 1 {
                let http = HTTPURLResponse(url: request.url!, statusCode: 503,
                                           httpVersion: nil, headerFields: nil)!
                return (http, Data(#"{"error":"unavailable"}"#.utf8))
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(Self.cannedZAIResponse.utf8))
        }
        defer { ZAIStubURLProtocol.responder = nil }

        let response = try await makeProvider(
            retryPolicy: RetryPolicy(maxRetries: 1, baseDelaySeconds: 0)
        ).send(LLMRequest(model: "glm-4.7-flash", messages: [.user("hello")]))

        #expect(response.text == "Hi")
        #expect(counter.value == 2)
    }

    @Test func stopsRetryingAfterLimit() async {
        let counter = LockedCounter()
        ZAIStubURLProtocol.responder = { request in
            counter.increment()
            let http = HTTPURLResponse(url: request.url!, statusCode: 429,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"error":{"message":"busy"}}"#.utf8))
        }
        defer { ZAIStubURLProtocol.responder = nil }

        do {
            _ = try await makeProvider(
                retryPolicy: RetryPolicy(maxRetries: 1, baseDelaySeconds: 0)
            ).send(LLMRequest(model: "glm-4.7-flash", messages: [.user("hello")]))
            Issue.record("expected a rate-limit error after retry exhaustion")
        } catch {
            #expect(error is LLMError)
            #expect(counter.value == 2)
        }
    }

    @Test func missingAPIKeyThrows() async {
        do {
            _ = try await ZAIProvider(apiKey: "")
                .send(LLMRequest(model: "glm-4.7-flash", messages: [.user("x")]))
            Issue.record("expected a missing-API-key error")
        } catch {
            #expect(error as? LLMError == .missingAPIKey)
        }
    }

    @Test func invalidAPIKeyReturnsFriendlyAuthErrorWithoutRetrying() async {
        let counter = LockedCounter()
        ZAIStubURLProtocol.responder = { request in
            counter.increment()
            let http = HTTPURLResponse(url: request.url!, statusCode: 401,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"error":{"message":"token expired or incorrect"}}"#.utf8))
        }
        defer { ZAIStubURLProtocol.responder = nil }

        do {
            _ = try await makeProvider(
                retryPolicy: RetryPolicy(maxRetries: 2, baseDelaySeconds: 0)
            ).send(LLMRequest(model: "glm-4.7-flash", messages: [.user("hello")]))
            Issue.record("expected an authentication error")
        } catch {
            // A 401 maps to a plain, provider-named message, not raw JSON, and
            // is not retried (a bad key will not fix itself).
            #expect(error as? LLMError == .authenticationFailed(provider: "Z.ai"))
            #expect(counter.value == 1)
        }
    }

    private static let cannedZAIResponse = """
    {
      "id": "chatcmpl-1",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "Hi"
          },
          "finish_reason": "stop"
        }
      ],
      "usage": {
        "prompt_tokens": 1,
        "completion_tokens": 1,
        "total_tokens": 2
      }
    }
    """

    private func makeProvider(retryPolicy: RetryPolicy = .standard) -> ZAIProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ZAIStubURLProtocol.self]
        return ZAIProvider(apiKey: "test-key",
                           endpoint: URL(string: "https://unit.test/chat")!,
                           urlSession: URLSession(configuration: config),
                           retryPolicy: retryPolicy)
    }
}

/// A `URLProtocol` that returns a canned response and captures the outbound
/// request, for offline provider tests.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        Self.capturedBody = Self.bodyData(from: request)
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Separate stub so Z.ai provider tests can run independently from Anthropic tests.
final class ZAIStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        Self.capturedBody = Self.bodyData(from: request)
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
