@testable import AutopilotCore
import Testing

struct AutopilotCoreTests {
    @Test func moduleImports() {
        let level = RiskLevel.safe

        #expect(level.rawValue == "safe")
    }
}
