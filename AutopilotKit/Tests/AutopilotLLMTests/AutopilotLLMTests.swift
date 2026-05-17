@testable import AutopilotLLM
import Testing

struct AutopilotLLMTests {
    @Test func moduleImports() {
        let message = LLMMessage.user("hello")

        #expect(message.role == .user)
    }
}
