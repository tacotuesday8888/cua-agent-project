import AutopilotCore
import Foundation
import Testing
@testable import AutopilotLLM

struct LLMResponseTests {
    @Test func extractsToolUsesAndText() {
        let response = LLMResponse(
            content: [
                .text("Working on it."),
                .toolUse(ToolUse(id: "t1", name: "click_element",
                                 input: ["element_id": "e3"]))
            ],
            stopReason: .toolUse,
            usage: .init(inputTokens: 10, outputTokens: 5)
        )
        #expect(response.text == "Working on it.")
        #expect(response.toolUses.count == 1)
        #expect(response.toolUses.first?.name == "click_element")
        #expect(response.toolUses.first?.input["element_id"]?.stringValue == "e3")
    }

    @Test func textOnlyResponseHasNoToolUses() {
        let response = LLMResponse(
            content: [.text("done")],
            stopReason: .endTurn,
            usage: .init(inputTokens: 1, outputTokens: 1)
        )
        #expect(response.toolUses.isEmpty)
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

    private func makeProvider() -> AnthropicProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AnthropicProvider(apiKey: "test-key",
                                 urlSession: URLSession(configuration: config))
    }
}

/// A `URLProtocol` that returns a canned response, for offline provider tests.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
}
