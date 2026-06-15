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
    @Test func accessModeDisplayNamesAreProductFacing() {
        #expect(LLMAccessMode.appManaged.displayName == "Mac Autopilot Basic")
        #expect(LLMAccessMode.bringYourOwnKey.displayName == "Bring Your Own Key")
        #expect(LLMAccessMode.existingSubscription.displayName == "Existing AI Account")
    }

    @Test func knownProviderCapabilitiesAreExplicit() {
        #expect(LLMProviderDescriptor.anthropic.identifier == "anthropic")
        #expect(LLMProviderDescriptor.anthropic.accessMode == .bringYourOwnKey)
        #expect(LLMProviderDescriptor.anthropic.supportsToolCalls)
        #expect(LLMProviderDescriptor.anthropic.supportsImageInput)
        #expect(LLMProviderDescriptor.anthropic.supportsPromptCaching)
        #expect(LLMProviderDescriptor.anthropic.apiKeyEnvironment == "ANTHROPIC_API_KEY")
        #expect(LLMProviderDescriptor.anthropic.keychainAccount == "AutopilotAnthropicAPIKey")
        #expect(LLMProviderDescriptor.anthropic.defaultModelDescriptor.identifier == "claude-sonnet-4-6")

        #expect(LLMProviderDescriptor.openai.identifier == "openai")
        #expect(LLMProviderDescriptor.openai.accessMode == .bringYourOwnKey)
        #expect(LLMProviderDescriptor.openai.defaultModel == "gpt-5.4-mini")
        #expect(LLMProviderDescriptor.openai.supportsToolCalls)
        #expect(LLMProviderDescriptor.openai.supportsImageInput)
        // OpenAI caches automatically; we emit no cache_control breakpoints.
        #expect(!LLMProviderDescriptor.openai.supportsPromptCaching)
        #expect(LLMProviderDescriptor.openai.apiKeyEnvironment == "OPENAI_API_KEY")
        #expect(LLMProviderDescriptor.openai.keychainAccount == "AutopilotOpenAIAPIKey")
        #expect(LLMProviderDescriptor.openai.defaultModelDescriptor.supportsImageInput)

        #expect(LLMProviderDescriptor.openAICompatible.identifier == "openai-compatible")
        #expect(LLMProviderDescriptor.openAICompatible.displayName == "OpenAI-compatible endpoint")
        #expect(LLMProviderDescriptor.openAICompatible.accessMode == .bringYourOwnKey)
        #expect(LLMProviderDescriptor.openAICompatible.allowsCustomModelID)
        #expect(LLMProviderDescriptor.openAICompatible.defaultModel == "custom-model")
        #expect(LLMProviderDescriptor.openAICompatible.supportsToolCalls)
        #expect(!LLMProviderDescriptor.openAICompatible.supportsImageInput)
        #expect(LLMProviderDescriptor.openAICompatible.apiKeyEnvironment.isEmpty)
        #expect(LLMProviderDescriptor.openAICompatible.keychainAccount == "AutopilotOpenAICompatibleAPIKey")

        // Hosted uses sign-in, not a local API key, so the key fields are empty.
        #expect(LLMProviderDescriptor.hosted.identifier == "hosted")
        #expect(LLMProviderDescriptor.hosted.displayName == "Mac Autopilot Basic")
        #expect(LLMProviderDescriptor.hosted.accessMode == .appManaged)
        #expect(LLMProviderDescriptor.hosted.defaultModel == "gpt-5.4-mini")
        #expect(LLMProviderDescriptor.hosted.defaultModelDescriptor.displayName == "GPT-5.4 Mini")
        #expect(LLMProviderDescriptor.hosted.supportsToolCalls)
        #expect(LLMProviderDescriptor.hosted.supportsImageInput)
        #expect(LLMProviderDescriptor.hosted.apiKeyEnvironment.isEmpty)
        #expect(LLMProviderDescriptor.hosted.keychainAccount.isEmpty)

        #expect(LLMProviderDescriptor.chatGPTAccount.identifier == "chatgpt-account")
        #expect(LLMProviderDescriptor.chatGPTAccount.displayName == "ChatGPT subscription")
        #expect(LLMProviderDescriptor.chatGPTAccount.accessMode == .existingSubscription)
        #expect(LLMProviderDescriptor.chatGPTAccount.supportsToolCalls)
        #expect(!LLMProviderDescriptor.chatGPTAccount.supportsImageInput)
        #expect(LLMProviderDescriptor.chatGPTAccount.apiKeyEnvironment.isEmpty)
        #expect(LLMProviderDescriptor.chatGPTAccount.keychainAccount.isEmpty)

        #expect(LLMProviderDescriptor.anthropicSubscription.accessMode == .existingSubscription)
        #expect(LLMProviderDescriptor.anthropicSubscription.displayName == "Claude subscription")
        #expect(LLMProviderDescriptor.anthropicSubscription.defaultModel == "automatic")
        #expect(LLMProviderDescriptor.anthropicSubscription.supportsToolCalls)
        #expect(!LLMProviderDescriptor.anthropicSubscription.supportsImageInput)
        #expect(!LLMProviderDescriptor.anthropicSubscription.supportsPromptCaching)
        #expect(LLMProviderDescriptor.anthropicSubscription.keychainAccount.isEmpty)
    }

    @Test func modelLookupFallsBackToTheDefaultModel() {
        let model = LLMProviderDescriptor.openai.modelDescriptor(for: "unknown-model")
        #expect(model.identifier == "gpt-5.4-mini")
        #expect(model.supportsToolCalls)
        #expect(model.supportsImageInput)
    }

    @Test func customModelLookupPreservesCompatibleModelIDs() {
        let model = LLMProviderDescriptor.openAICompatible.modelDescriptor(for: "qwen/qwen3-coder")
        #expect(model.identifier == "qwen/qwen3-coder")
        #expect(model.displayName == "qwen/qwen3-coder")
        #expect(model.supportsToolCalls)
        #expect(!model.supportsImageInput)
        #expect(!model.supportsPromptCaching)
    }
}

struct SubscriptionOAuthTests {
    @Test func chatGPTSubscriptionOAuthMatchesCodexStyleFlowWithoutExternalStorage() {
        let config = SubscriptionOAuthProviderID.chatGPTCodex.configuration
        let url = config.authorizationURL(codeChallenge: "challenge", state: "state")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })

        #expect(config.clientID == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(config.redirectURI == "http://localhost:1455/auth/callback")
        #expect(config.tokenRequestEncoding == .form)
        #expect(query["client_id"] == config.clientID)
        #expect(query["scope"] == "openid profile email offline_access")
        #expect(query["codex_cli_simplified_flow"] == "true")
        #expect(query["originator"] == "mac-autopilot")
        #expect(SubscriptionOAuthProviderID.chatGPTCodex.keychainAccount.contains("openai-codex"))
    }

    @Test func claudeSubscriptionOAuthMatchesAnthropicSubscriptionFlow() {
        let config = SubscriptionOAuthProviderID.anthropic.configuration
        let url = config.authorizationURL(codeChallenge: "challenge", state: "verifier")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })

        #expect(config.clientID == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(config.redirectURI == "http://localhost:53692/callback")
        #expect(config.tokenRequestEncoding == .json)
        #expect(query["code"] == "true")
        #expect(query["state"] == "verifier")
        #expect(query["scope"]?.contains("user:inference") == true)
        #expect(SubscriptionOAuthProviderID.anthropic.keychainAccount.contains("anthropic"))
    }

    @Test func refreshUsesProviderSpecificTokenEncodingAndExtractsChatGPTAccountID() async throws {
        let recorder = OAuthTransportRecorder(
            responseBody: """
            {"access_token":"\(Self.jwt(accountID: "acct_123"))","refresh_token":"next-refresh","expires_in":3600}
            """
        )
        let client = SubscriptionOAuthTokenClient { request in
            await recorder.respond(to: request)
        }
        let credential = SubscriptionOAuthCredential(
            provider: .chatGPTCodex,
            accessToken: "old",
            refreshToken: "old-refresh",
            expiresAt: .distantPast
        )

        let refreshed = try await client.refresh(credential)

        #expect(refreshed.refreshToken == "next-refresh")
        #expect(refreshed.accountID == "acct_123")
        let request = await recorder.requests.first
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(data: request?.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
    }

    @Test func anthropicRefreshUsesJSONTokenBody() async throws {
        let recorder = OAuthTransportRecorder(
            responseBody: """
            {"access_token":"sk-ant-oat-test","refresh_token":"next-refresh","expires_in":3600}
            """
        )
        let client = SubscriptionOAuthTokenClient { request in
            await recorder.respond(to: request)
        }
        let credential = SubscriptionOAuthCredential(
            provider: .anthropic,
            accessToken: "old",
            refreshToken: "old-refresh",
            expiresAt: .distantPast
        )

        let refreshed = try await client.refresh(credential)

        #expect(refreshed.accessToken == "sk-ant-oat-test")
        let request = await recorder.requests.first
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: String]
        #expect(body?["grant_type"] == "refresh_token")
        #expect(body?["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }

    @Test func anthropicBrowserSignInUsesPKCEVerifierAsOAuthState() async throws {
        let recorder = OAuthTransportRecorder(
            responseBody: """
            {"access_token":"sk-ant-oat-test","refresh_token":"next-refresh","expires_in":3600}
            """
        )
        let client = SubscriptionOAuthTokenClient { request in
            await recorder.respond(to: request)
        }
        let flow = SubscriptionOAuthBrowserSignIn(
            tokenClient: client,
            timeoutSeconds: 10
        ) { authorizationURL in
            let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
            let redirectURI = try #require(query["redirect_uri"])
            let state = try #require(query["state"])

            var callback = try #require(URLComponents(string: redirectURI))
            callback.queryItems = [
                URLQueryItem(name: "code", value: "test-code"),
                URLQueryItem(name: "state", value: state)
            ]
            _ = try await URLSession.shared.data(from: try #require(callback.url))
        }

        let credential = try await flow.signIn(provider: .anthropic)

        #expect(credential.accessToken == "sk-ant-oat-test")
        let request = try #require(await recorder.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        let codeVerifier = try #require(body["code_verifier"])
        #expect(body["grant_type"] == "authorization_code")
        #expect(body["code"] == "test-code")
        #expect(body["state"] == codeVerifier)
        #expect(!codeVerifier.isEmpty)
    }

    private static func jwt(accountID: String) -> String {
        let payload: [String: Any] = [
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}

@Suite(.serialized)
struct ChatGPTSubscriptionProviderTests {
    @Test func sendsCodexResponsesRequestWithOAuthHeadersAndDecodesText() async throws {
        ChatGPTStubURLProtocol.capturedRequest = nil
        ChatGPTStubURLProtocol.capturedBody = nil
        ChatGPTStubURLProtocol.responder = { request in
            let stream = """
            data: {"type":"response.output_text.delta","delta":"Hi "}

            data: {"type":"response.output_text.delta","delta":"there"}

            data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}}

            """
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["content-type": "text/event-stream"]
            )!
            return (http, Data(stream.utf8))
        }
        defer {
            ChatGPTStubURLProtocol.responder = nil
            ChatGPTStubURLProtocol.capturedRequest = nil
            ChatGPTStubURLProtocol.capturedBody = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatGPTStubURLProtocol.self]
        let provider = ChatGPTSubscriptionProvider(
            credentialProvider: { providerID in
                #expect(providerID == .chatGPTCodex)
                return SubscriptionOAuthCredential(
                    provider: .chatGPTCodex,
                    accessToken: "chatgpt-token",
                    refreshToken: "refresh",
                    expiresAt: Date().addingTimeInterval(3600),
                    accountID: "acct_123"
                )
            },
            urlSession: URLSession(configuration: config),
            retryPolicy: RetryPolicy(maxRetries: 0, baseDelaySeconds: 0)
        )

        let response = try await provider.send(LLMRequest(
            model: "automatic",
            system: "sys",
            messages: [.user("hello")]
        ))

        let request = try #require(ChatGPTStubURLProtocol.capturedRequest)
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer chatgpt-token")
        #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "acct_123")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
        #expect(request.value(forHTTPHeaderField: "originator") == "mac-autopilot")

        let body = try #require(ChatGPTStubURLProtocol.capturedBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["model"] as? String == "gpt-5.4")
        #expect(payload["instructions"] as? String == "sys")
        #expect(payload["stream"] as? Bool == true)
        #expect(payload["store"] as? Bool == false)

        #expect(response.text == "Hi there")
        #expect(response.stopReason == .endTurn)
        #expect(response.usage.inputTokens == 3)
        #expect(response.usage.outputTokens == 2)
    }

    @Test func decodesCodexFunctionCall() async throws {
        ChatGPTStubURLProtocol.responder = { request in
            let stream = """
            data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"click","arguments":""}}

            data: {"type":"response.function_call_arguments.delta","delta":"{\\"element_index\\":"}

            data: {"type":"response.function_call_arguments.done","arguments":"{\\"element_index\\":3}"}

            data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":1}}}

            """
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(stream.utf8))
        }
        defer { ChatGPTStubURLProtocol.responder = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatGPTStubURLProtocol.self]
        let provider = ChatGPTSubscriptionProvider(
            credentialProvider: { _ in
                SubscriptionOAuthCredential(
                    provider: .chatGPTCodex,
                    accessToken: "chatgpt-token",
                    refreshToken: "refresh",
                    expiresAt: Date().addingTimeInterval(3600),
                    accountID: "acct_123"
                )
            },
            urlSession: URLSession(configuration: config),
            retryPolicy: RetryPolicy(maxRetries: 0, baseDelaySeconds: 0)
        )

        let response = try await provider.send(LLMRequest(
            model: "gpt-5.4",
            messages: [.user("Click")],
            tools: [
                ToolDefinition(
                    name: "click",
                    description: "Click an element.",
                    inputSchema: ["type": "object"]
                )
            ]
        ))

        #expect(response.stopReason == .toolUse)
        #expect(response.toolUses.first?.name == "click")
        #expect(response.toolUses.first?.input["element_index"]?.intValue == 3)
    }
}

private actor OAuthTransportRecorder {
    private(set) var requests: [URLRequest] = []
    private let responseBody: String

    init(responseBody: String) {
        self.responseBody = responseBody
    }

    func respond(to request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            Data(responseBody.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

struct LLMErrorTests {
    @Test func authenticationFailedMessageNamesTheProviderAndIsActionable() {
        #expect(
            LLMError.authenticationFailed(provider: "OpenAI").errorDescription
                == "The saved OpenAI API key is invalid or expired. Update the API key and run again."
        )
        #expect(
            LLMError.authenticationFailed(provider: "Anthropic").errorDescription
                == "The saved Anthropic API key is invalid or expired. Update the API key and run again."
        )
        #expect(
            LLMError.accountAuthenticationFailed(provider: "Claude").errorDescription
                == "Sign in with Claude again, then run the task."
        )
    }

    @Test func authenticationFailedDoesNotLeakRawProviderBody() {
        // Unlike `.http`, the 401 path must not surface raw provider JSON or a
        // bare status code to the user.
        let message = LLMError.authenticationFailed(provider: "OpenAI").errorDescription ?? ""
        #expect(!message.contains("{"))
        #expect(!message.contains("HTTP"))
    }

    @Test func serviceErrorPassesTheBackendMessageThrough() {
        // The hosted backend already writes user-facing messages; surface them as-is.
        #expect(
            LLMError.service(message: "Monthly usage limit reached.").errorDescription
                == "Monthly usage limit reached."
        )
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

    @Test func oauthBearerAuthenticationUsesClaudeSubscriptionHeaders() async throws {
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

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        _ = try await AnthropicProvider(
            oauthToken: "sk-ant-oat-test",
            identifier: "anthropic-subscription",
            urlSession: URLSession(configuration: config),
            retryPolicy: RetryPolicy(maxRetries: 0, baseDelaySeconds: 0)
        ).send(LLMRequest(
            model: "claude-sonnet-4-6",
            system: "sys",
            messages: [.user("hello")]
        ))

        let request = try #require(StubURLProtocol.capturedRequest)
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-ant-oat-test")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta")?.contains("oauth-2025-04-20") == true)
        #expect(request.value(forHTTPHeaderField: "x-app") == "cli")

        let body = try #require(StubURLProtocol.capturedBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try #require(payload["system"] as? [[String: Any]])
        #expect((system.first?["text"] as? String)?.contains("Claude Code") == true)
        #expect(system.last?["text"] as? String == "sys")
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
struct OpenAIProviderTests {
    @Test func decodesResponseWithToolCall() async throws {
        OpenAIStubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(Self.cannedResponse.utf8))
        }
        defer { OpenAIStubURLProtocol.responder = nil }

        let response = try await makeProvider().send(
            LLMRequest(model: "gpt-5.4-mini", system: "sys", messages: [.user("hello")])
        )
        #expect(response.stopReason == .toolUse)
        #expect(response.text == "Hi")
        #expect(response.toolUses.first?.name == "done")
        #expect(response.toolUses.first?.input["summary"]?.stringValue == "ok")
        #expect(response.usage.inputTokens == 12)
        #expect(response.usage.outputTokens == 7)
        // OpenAI's prompt_tokens already includes cached tokens — no double count.
        #expect(response.usage.totalInputTokens == 12)
    }

    @Test func requestUsesMaxCompletionTokensNotMaxTokens() async throws {
        OpenAIStubURLProtocol.capturedBody = nil
        OpenAIStubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(Self.cannedResponse.utf8))
        }
        defer {
            OpenAIStubURLProtocol.responder = nil
            OpenAIStubURLProtocol.capturedBody = nil
        }

        let tool = ToolDefinition(
            name: "done",
            description: "Finish the task.",
            inputSchema: ["type": "object", "properties": ["summary": ["type": "string"]], "required": ["summary"]]
        )
        _ = try await makeProvider().send(LLMRequest(
            model: "gpt-5.4-mini",
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
            maxTokens: 256
        ))

        let body = try #require(OpenAIStubURLProtocol.capturedBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // GPT-5.x requires max_completion_tokens and rejects max_tokens.
        #expect(payload["max_completion_tokens"] as? Int == 256)
        #expect(payload["max_tokens"] == nil)

        let messages = try #require(payload["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(messages[3]["tool_call_id"] as? String == "call_1")
        #expect(messages[3]["content"] as? String == "Done.")
        let assistantToolCalls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        let function = try #require(assistantToolCalls.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "done")
    }

    @Test func compatibleEndpointCanUseMaxTokensAndOmitAuthorization() async throws {
        OpenAIStubURLProtocol.capturedRequest = nil
        OpenAIStubURLProtocol.capturedBody = nil
        OpenAIStubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(Self.cannedResponse.utf8))
        }
        defer {
            OpenAIStubURLProtocol.responder = nil
            OpenAIStubURLProtocol.capturedRequest = nil
            OpenAIStubURLProtocol.capturedBody = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenAIStubURLProtocol.self]
        let provider = OpenAIProvider(
            apiKey: "",
            endpoint: URL(string: "http://localhost:11434/v1/chat/completions")!,
            urlSession: URLSession(configuration: config),
            retryPolicy: RetryPolicy(maxRetries: 0, baseDelaySeconds: 0),
            requiresAPIKey: false,
            tokenLimitParameter: .maxTokens
        )

        _ = try await provider.send(LLMRequest(
            model: "llama3.2",
            messages: [.user("hello")],
            maxTokens: 128
        ))

        let request = try #require(OpenAIStubURLProtocol.capturedRequest)
        #expect(request.value(forHTTPHeaderField: "authorization") == nil)
        let body = try #require(OpenAIStubURLProtocol.capturedBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["max_tokens"] as? Int == 128)
        #expect(payload["max_completion_tokens"] == nil)
    }

    @Test func encodesImagesAndRelocatesToolResultImages() async throws {
        OpenAIStubURLProtocol.capturedBody = nil
        OpenAIStubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(Self.cannedResponse.utf8))
        }
        defer {
            OpenAIStubURLProtocol.responder = nil
            OpenAIStubURLProtocol.capturedBody = nil
        }

        _ = try await makeProvider().send(LLMRequest(
            model: "gpt-5.4-mini",
            messages: [
                LLMMessage(role: .user, content: [.text("look"), .image(ImageBlock(base64Data: "BBB"))]),
                LLMMessage(role: .user, content: [
                    .toolResult(ToolResult(
                        toolUseID: "call_9",
                        content: [.text("tree"), .image(ImageBlock(base64Data: "AAA"))]
                    ))
                ])
            ]
        ))

        let body = try #require(OpenAIStubURLProtocol.capturedBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: Any]])

        // Inline image: the first user message uses a parts array with image_url.
        let firstParts = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(firstParts.contains { $0["type"] as? String == "text" && $0["text"] as? String == "look" })
        let inlineImage = firstParts.first { $0["type"] as? String == "image_url" }
        #expect(((inlineImage?["image_url"] as? [String: Any])?["url"] as? String) == "data:image/png;base64,BBB")

        // The tool message carries only string text; its image is relocated to a
        // following user message (OpenAI tool messages cannot carry images).
        let toolIndex = try #require(messages.firstIndex { $0["role"] as? String == "tool" })
        #expect(messages[toolIndex]["content"] as? String == "tree")
        #expect(messages[toolIndex + 1]["role"] as? String == "user")
        let relocated = try #require(messages[toolIndex + 1]["content"] as? [[String: Any]])
        #expect(relocated.contains {
            $0["type"] as? String == "image_url"
                && (($0["image_url"] as? [String: Any])?["url"] as? String) == "data:image/png;base64,AAA"
        })
    }

    @Test func invalidAPIKeyReturnsFriendlyAuthErrorWithoutRetrying() async {
        let counter = LockedCounter()
        OpenAIStubURLProtocol.responder = { request in
            counter.increment()
            let http = HTTPURLResponse(url: request.url!, statusCode: 401,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8))
        }
        defer { OpenAIStubURLProtocol.responder = nil }

        do {
            _ = try await makeProvider(
                retryPolicy: RetryPolicy(maxRetries: 2, baseDelaySeconds: 0)
            ).send(LLMRequest(model: "gpt-5.4-mini", messages: [.user("hello")]))
            Issue.record("expected an authentication error")
        } catch {
            #expect(error as? LLMError == .authenticationFailed(provider: "OpenAI"))
            #expect(counter.value == 1)
        }
    }

    @Test func retriesTransientServerError() async throws {
        let counter = LockedCounter()
        OpenAIStubURLProtocol.responder = { request in
            if counter.increment() == 1 {
                let http = HTTPURLResponse(url: request.url!, statusCode: 503,
                                           httpVersion: nil, headerFields: nil)!
                return (http, Data(#"{"error":"unavailable"}"#.utf8))
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(Self.cannedResponse.utf8))
        }
        defer { OpenAIStubURLProtocol.responder = nil }

        let response = try await makeProvider(
            retryPolicy: RetryPolicy(maxRetries: 1, baseDelaySeconds: 0)
        ).send(LLMRequest(model: "gpt-5.4-mini", messages: [.user("hello")]))
        #expect(response.text == "Hi")
        #expect(counter.value == 2)
    }

    @Test func doesNotRetryClientError() async {
        let counter = LockedCounter()
        OpenAIStubURLProtocol.responder = { request in
            counter.increment()
            let http = HTTPURLResponse(url: request.url!, statusCode: 400,
                                       httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"error":"bad request"}"#.utf8))
        }
        defer { OpenAIStubURLProtocol.responder = nil }

        do {
            _ = try await makeProvider(
                retryPolicy: RetryPolicy(maxRetries: 2, baseDelaySeconds: 0)
            ).send(LLMRequest(model: "gpt-5.4-mini", messages: [.user("x")]))
            Issue.record("expected a client error to be thrown")
        } catch {
            #expect(error is LLMError)
            #expect(counter.value == 1)
        }
    }

    @Test func missingAPIKeyThrows() async {
        do {
            _ = try await OpenAIProvider(apiKey: "")
                .send(LLMRequest(model: "gpt-5.4-mini", messages: [.user("x")]))
            Issue.record("expected a missing-API-key error")
        } catch {
            #expect(error as? LLMError == .missingAPIKey)
        }
    }

    private static let cannedResponse = """
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
                "function": { "name": "done", "arguments": "{\\"summary\\":\\"ok\\"}" }
              }
            ]
          },
          "finish_reason": "tool_calls"
        }
      ],
      "usage": { "prompt_tokens": 12, "completion_tokens": 7, "total_tokens": 19 }
    }
    """

    private func makeProvider(retryPolicy: RetryPolicy = .standard) -> OpenAIProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenAIStubURLProtocol.self]
        return OpenAIProvider(apiKey: "test-key",
                              endpoint: URL(string: "https://unit.test/openai")!,
                              urlSession: URLSession(configuration: config),
                              retryPolicy: retryPolicy)
    }
}

@Suite(.serialized)
struct HostedProviderTests {
    private func makeProvider(token: String?, retryPolicy: RetryPolicy = .standard) -> HostedProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HostedStubURLProtocol.self]
        return HostedProvider(
            endpoint: URL(string: "https://unit.test/llmProxy")!,
            tokenProvider: { token },
            urlSession: URLSession(configuration: config),
            retryPolicy: retryPolicy
        )
    }

    @Test func notSignedInFailsWithoutCallingTheNetwork() async {
        let counter = LockedCounter()
        HostedStubURLProtocol.responder = { request in
            counter.increment()
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data("{}".utf8))
        }
        defer { HostedStubURLProtocol.responder = nil }

        do {
            _ = try await makeProvider(token: nil)
                .send(LLMRequest(model: "gpt-5.4", messages: [.user("hi")]))
            Issue.record("expected a sign-in error")
        } catch {
            #expect(error as? LLMError == .service(message: "Sign in to use hosted AI."))
            #expect(counter.value == 0) // never reached the backend
        }
    }

    @Test func decodesResultEnvelopeIntoResponse() async throws {
        HostedStubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {"result":{"content":[{"type":"text","text":"Hi"},{"type":"toolUse","id":"t1","name":"done","input":{"summary":"ok"}}],"stopReason":"toolUse","usage":{"inputTokens":12,"outputTokens":7}}}
            """
            return (http, Data(json.utf8))
        }
        defer { HostedStubURLProtocol.responder = nil }

        let response = try await makeProvider(token: "tok")
            .send(LLMRequest(model: "gpt-5.4", messages: [.user("hi")]))
        #expect(response.text == "Hi")
        #expect(response.stopReason == .toolUse)
        #expect(response.toolUses.first?.name == "done")
        #expect(response.toolUses.first?.input["summary"]?.stringValue == "ok")
        #expect(response.usage.inputTokens == 12)
        #expect(response.usage.outputTokens == 7)
    }

    @Test func sendsDataEnvelopeWithBearerToken() async throws {
        HostedStubURLProtocol.capturedRequest = nil
        HostedStubURLProtocol.capturedBody = nil
        HostedStubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"result":{"content":[],"stopReason":"endTurn","usage":{"inputTokens":0,"outputTokens":0}}}"#.utf8))
        }
        defer {
            HostedStubURLProtocol.responder = nil
            HostedStubURLProtocol.capturedRequest = nil
            HostedStubURLProtocol.capturedBody = nil
        }

        _ = try await makeProvider(token: "tok").send(
            LLMRequest(model: "gpt-5.4", system: "sys", messages: [.user("hello")])
        )

        let request = try #require(HostedStubURLProtocol.capturedRequest)
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer tok")
        let body = try #require(HostedStubURLProtocol.capturedBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let envelope = try #require(json)
        let data = try #require(envelope["data"] as? [String: Any])
        #expect(data["model"] as? String == "gpt-5.4")
        #expect(data["system"] as? String == "sys")
        let messages = try #require(data["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["text"] as? String == "hello")
    }

    @Test func relocatesToolResultImagesAndLooksUpToolName() async throws {
        HostedStubURLProtocol.capturedBody = nil
        HostedStubURLProtocol.responder = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"result":{"content":[],"stopReason":"endTurn","usage":{"inputTokens":0,"outputTokens":0}}}"#.utf8))
        }
        defer {
            HostedStubURLProtocol.responder = nil
            HostedStubURLProtocol.capturedBody = nil
        }

        _ = try await makeProvider(token: "tok").send(LLMRequest(
            model: "gpt-5.4",
            messages: [
                LLMMessage(role: .assistant, content: [
                    .toolUse(ToolUse(id: "c1", name: "get_app_state", input: .object([:]))),
                ]),
                LLMMessage(role: .user, content: [
                    .toolResult(ToolResult(
                        toolUseID: "c1",
                        content: [.text("tree"), .image(ImageBlock(base64Data: "AAA"))]
                    )),
                ]),
            ]
        ))

        let body = try #require(HostedStubURLProtocol.capturedBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let data = try #require((json?["data"]) as? [String: Any])
        let messages = try #require(data["messages"] as? [[String: Any]])

        // The assistant tool call is preserved.
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let toolCalls = try #require(assistant["toolCalls"] as? [[String: Any]])
        #expect(toolCalls.first?["name"] as? String == "get_app_state")

        // The tool-result message carries text + the name looked up from the call.
        let toolResultMessage = try #require(messages.first { $0["toolResults"] != nil })
        let toolResults = try #require(toolResultMessage["toolResults"] as? [[String: Any]])
        #expect(toolResults.first?["name"] as? String == "get_app_state")
        #expect(toolResults.first?["text"] as? String == "tree")

        // The tool-result image is relocated into a following user message.
        let imageMessage = try #require(messages.first { ($0["images"] as? [[String: Any]])?.isEmpty == false })
        #expect(imageMessage["role"] as? String == "user")
        let images = try #require(imageMessage["images"] as? [[String: Any]])
        #expect(images.first?["dataBase64"] as? String == "AAA")
    }

    @Test func callableErrorMapsToServiceMessageAndIsNotRetried() async {
        let counter = LockedCounter()
        HostedStubURLProtocol.responder = { request in
            counter.increment()
            let http = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"error":{"message":"Monthly usage limit reached.","status":"RESOURCE_EXHAUSTED"}}"#.utf8))
        }
        defer { HostedStubURLProtocol.responder = nil }

        do {
            _ = try await makeProvider(token: "tok", retryPolicy: RetryPolicy(maxRetries: 2, baseDelaySeconds: 0))
                .send(LLMRequest(model: "gpt-5.4", messages: [.user("hi")]))
            Issue.record("expected a service error")
        } catch {
            #expect(error as? LLMError == .service(message: "Monthly usage limit reached."))
            #expect(counter.value == 1)
        }
    }

    @Test func networkFailureMapsToNetworkError() async {
        HostedStubURLProtocol.responder = nil // makes the stub fail the request
        do {
            _ = try await makeProvider(token: "tok", retryPolicy: RetryPolicy(maxRetries: 0, baseDelaySeconds: 0))
                .send(LLMRequest(model: "gpt-5.4", messages: [.user("hi")]))
            Issue.record("expected a network error")
        } catch {
            guard case LLMError.network = error else {
                Issue.record("expected .network, got \(error)")
                return
            }
        }
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

final class OpenAIStubURLProtocol: URLProtocol {
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

final class ChatGPTStubURLProtocol: URLProtocol {
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

/// Separate stub so hosted-provider tests run independently from the others.
final class HostedStubURLProtocol: URLProtocol {
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
