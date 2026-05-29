import AutopilotCore
import Foundation
import Testing
@testable import AutopilotAgent

struct AgentValidationScenarioTests {
    @Test func decodesScenarioShape() throws {
        let json = """
        {
          "id": "textedit-note",
          "app": "TextEdit",
          "task": "Type hello",
          "provider": "openai",
          "maxSteps": 8,
          "includeScreenshot": true,
          "expect": {
            "finalStatus": "completed",
            "stateContainsText": "hello",
            "toolUsed": "type_text",
            "noActionFailures": true,
            "windowTitleContainsText": "Untitled"
          }
        }
        """

        let scenario = try JSONDecoder().decode(
            AgentValidationScenario.self,
            from: Data(json.utf8)
        )

        #expect(scenario.id == "textedit-note")
        #expect(scenario.app == "TextEdit")
        #expect(scenario.maxSteps == 8)
        #expect(scenario.includeScreenshot == true)
        #expect(scenario.expect.stateContainsText == "hello")
    }

    @Test func evaluatorReportsPassingChecks() {
        let scenario = AgentValidationScenario(
            id: "fixture",
            app: "Fixture",
            task: "Set field",
            expect: AgentValidationExpectations(
                finalStatus: "completed",
                stateContainsText: "done",
                toolUsed: "set_value",
                noActionFailures: true,
                windowTitleContainsText: "Fixture"
            )
        )
        let snapshot = snapshot(
            appName: "Fixture",
            windowTitle: "Fixture Window",
            root: UIElement(
                id: "e1",
                role: "AXWindow",
                children: [
                    UIElement(id: "e2", role: "AXTextField", label: "Input", value: "done")
                ]
            )
        )

        let report = AgentValidationEvaluator.evaluate(
            scenario: scenario,
            outcome: AgentOutcome(status: .completed, summary: "Done."),
            events: [.performed(tool: .setValue, summary: "Set e2.")],
            finalSnapshot: snapshot
        )

        #expect(report.passed)
        #expect(report.checks.count == 5)
        #expect(report.checks.allSatisfy { $0.passed })
    }

    @Test func evaluatorReportsFailedChecks() {
        let scenario = AgentValidationScenario(
            id: "fixture",
            app: "Fixture",
            task: "Set field",
            expect: AgentValidationExpectations(
                finalStatus: "completed",
                stateContainsText: "expected",
                toolUsed: "click",
                noActionFailures: true,
                windowTitleContainsText: "Fixture"
            )
        )
        let report = AgentValidationEvaluator.evaluate(
            scenario: scenario,
            outcome: AgentOutcome(status: .failed, summary: "Nope."),
            events: [
                .performed(tool: .setValue, summary: "Set e2."),
                .actionFailed(tool: .click, reason: "missed")
            ],
            finalSnapshot: snapshot(appName: "Fixture", windowTitle: "Other", root: UIElement(
                id: "e1",
                role: "AXWindow",
                children: [UIElement(id: "e2", role: "AXTextField", value: "actual")]
            ))
        )

        #expect(!report.passed)
        #expect(report.checks.filter { !$0.passed }.count == 5)
    }

    private func snapshot(
        appName: String,
        windowTitle: String,
        root: UIElement
    ) -> UITreeSnapshot {
        UITreeSnapshot(appName: appName, windowTitle: windowTitle, root: root)
    }
}
