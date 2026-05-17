/// A test `LLMProvider` that returns a pre-scripted sequence of responses and
/// records the requests it received.
///
/// Useful for unit tests, SwiftUI previews, and offline demos — anywhere a
/// real model call is undesirable.
public actor ScriptedLLMProvider: LLMProvider {
    public nonisolated let identifier = "scripted-mock"

    private var pending: [LLMResponse]
    private var receivedRequests: [LLMRequest] = []

    public init(_ responses: [LLMResponse]) {
        self.pending = responses
    }

    public func send(_ request: LLMRequest) async throws -> LLMResponse {
        receivedRequests.append(request)
        guard !pending.isEmpty else {
            throw LLMError.invalidResponse("scripted provider exhausted")
        }
        return pending.removeFirst()
    }

    /// The requests this provider has received, in order.
    public var requests: [LLMRequest] {
        receivedRequests
    }
}
