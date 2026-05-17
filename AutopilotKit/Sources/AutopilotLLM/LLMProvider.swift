/// A provider-agnostic interface to a chat LLM with tool-use support.
///
/// Conforming types adapt a specific vendor API (Anthropic, OpenAI, a local
/// model, …) to one request/response shape, so the agent never depends on a
/// particular model or vendor. The v1 default is `AnthropicProvider`.
public protocol LLMProvider: Sendable {
    /// A short identifier for logging and telemetry, e.g. "anthropic".
    var identifier: String { get }

    /// Send a request and await the model's response.
    func send(_ request: LLMRequest) async throws -> LLMResponse
}
