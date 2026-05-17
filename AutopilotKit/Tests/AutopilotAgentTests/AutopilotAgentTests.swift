@testable import AutopilotAgent
import Testing

struct AutopilotAgentTests {
    @Test func moduleImports() {
        let tools = AgentTool.allCases

        #expect(tools.contains(.done))
    }
}
