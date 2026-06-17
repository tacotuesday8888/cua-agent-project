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
            "windowTitleContainsText": "Untitled",
            "approvalRequestsByTier": {
              "write": 1,
              "destructive": 1
            },
            "actionsByRiskTier": {
              "write": 2,
              "destructive": 1
            }
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
        #expect(scenario.expect.approvalRequestsByTier == ["write": 1, "destructive": 1])
        #expect(scenario.expect.actionsByRiskTier == ["write": 2, "destructive": 1])
    }

    @Test func decodesLegacyScenarioWithoutApprovalExpectations() throws {
        let json = """
        {
          "id": "legacy-fixture",
          "app": "AutopilotFixtureApp",
          "task": "Exercise fixture",
          "expect": {
            "finalStatus": "completed"
          }
        }
        """

        let scenario = try JSONDecoder().decode(
            AgentValidationScenario.self,
            from: Data(json.utf8)
        )

        #expect(scenario.expect.approvalRequestsByTier == nil)
        #expect(scenario.expect.actionsByRiskTier == nil)
    }

    @Test func committedScenarioFixturesDecodeAndHaveRunnableShape() throws {
        let fixtureURLs = try FileManager.default.contentsOfDirectory(
            at: committedScenarioDirectory(),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(!fixtureURLs.isEmpty, "Expected at least one committed validation scenario fixture.")

        var seenIDs = Set<String>()
        for fixtureURL in fixtureURLs {
            let scenario = try JSONDecoder().decode(
                AgentValidationScenario.self,
                from: Data(contentsOf: fixtureURL)
            )
            let expectedID = fixtureURL.deletingPathExtension().lastPathComponent

            #expect(scenario.id == expectedID, "\(fixtureURL.lastPathComponent) id should match its file name.")
            #expect(!scenario.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(seenIDs.insert(scenario.id).inserted, "Duplicate scenario id: \(scenario.id).")
            #expect(!scenario.app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!scenario.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(scenario.provider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true)
            #expect(scenario.maxSteps.map { $0 > 0 } ?? true)
            #expect(scenario.expect.hasAtLeastOneCheck)
        }
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

    @Test func evaluatorReportsPassingRiskAndApprovalTierCounts() {
        let scenario = AgentValidationScenario(
            id: "approval-gate",
            app: "Fixture",
            task: "Exercise approvals",
            expect: AgentValidationExpectations(
                finalStatus: "completed",
                approvalRequestsByTier: [
                    "write": 1,
                    "destructive": 1
                ],
                actionsByRiskTier: [
                    "write": 2,
                    "destructive": 1
                ]
            )
        )
        let target = ActionTarget(appName: "Fixture", description: "Set field")
        let report = AgentValidationEvaluator.evaluate(
            scenario: scenario,
            outcome: AgentOutcome(status: .completed, summary: "Done."),
            events: [
                .willPerform(tool: .setValue, target: target, tier: .write),
                .awaitingConfirmation(ApprovalRequest(
                    appName: "Fixture",
                    tier: .write,
                    target: target,
                    summary: "Set field"
                )),
                .performed(tool: .setValue, summary: "Set field"),
                .willPerform(tool: .click, target: target, tier: .write),
                .performed(tool: .click, summary: "Click Run"),
                .willPerform(tool: .setValue, target: target, tier: .destructive),
                .awaitingConfirmation(ApprovalRequest(
                    appName: "Fixture",
                    tier: .destructive,
                    target: target,
                    summary: "Overwrite field"
                ))
            ],
            finalSnapshot: nil
        )

        #expect(report.passed)
        #expect(report.checks.count == 3)
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

    @Test func evaluatorReportsFailedRiskAndApprovalTierCounts() {
        let scenario = AgentValidationScenario(
            id: "approval-gate",
            app: "Fixture",
            task: "Exercise approvals",
            expect: AgentValidationExpectations(
                approvalRequestsByTier: ["write": 1, "destructive": 0],
                actionsByRiskTier: ["write": 2, "destructive": 0]
            )
        )
        let target = ActionTarget(appName: "Fixture", description: "Delete draft")
        let report = AgentValidationEvaluator.evaluate(
            scenario: scenario,
            outcome: AgentOutcome(status: .completed, summary: "Done."),
            events: [
                .willPerform(tool: .setValue, target: target, tier: .write),
                .awaitingConfirmation(ApprovalRequest(
                    appName: "Fixture",
                    tier: .write,
                    target: target,
                    summary: "Set field"
                )),
                .willPerform(tool: .click, target: target, tier: .destructive),
                .awaitingConfirmation(ApprovalRequest(
                    appName: "Fixture",
                    tier: .destructive,
                    target: target,
                    summary: "Delete draft"
                ))
            ],
            finalSnapshot: nil
        )

        #expect(!report.passed)
        #expect(report.checks.filter { !$0.passed }.count == 2)
    }

    @Test func evaluatorFailsUnknownRiskTierExpectation() {
        let scenario = AgentValidationScenario(
            id: "approval-gate",
            app: "Fixture",
            task: "Exercise approvals",
            expect: AgentValidationExpectations(
                approvalRequestsByTier: ["destuctive": 1]
            )
        )
        let report = AgentValidationEvaluator.evaluate(
            scenario: scenario,
            outcome: AgentOutcome(status: .completed, summary: "Done."),
            events: [],
            finalSnapshot: nil
        )

        #expect(!report.passed)
        #expect(report.checks.first?.name == "approvalRequestsByTier")
        #expect(report.checks.first?.detail.contains("unknown tier") == true)
    }

    private func snapshot(
        appName: String,
        windowTitle: String,
        root: UIElement
    ) -> UITreeSnapshot {
        UITreeSnapshot(appName: appName, windowTitle: windowTitle, root: root)
    }

    private func committedScenarioDirectory() throws -> URL {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var checkedPaths: [String] = []

        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("docs/validation/scenarios", isDirectory: true)
            checkedPaths.append(candidate.path)

            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }

            directory.deleteLastPathComponent()
        }

        throw MissingScenarioDirectory(checkedPaths: checkedPaths)
    }
}

private extension AgentValidationExpectations {
    var hasAtLeastOneCheck: Bool {
        finalStatus != nil
            || stateContainsText != nil
            || toolUsed != nil
            || noActionFailures != nil
            || windowTitleContainsText != nil
            || approvalRequestsByTier?.isEmpty == false
            || actionsByRiskTier?.isEmpty == false
    }
}

private struct MissingScenarioDirectory: Error, CustomStringConvertible {
    var checkedPaths: [String]

    var description: String {
        "Could not find docs/validation/scenarios. Checked: \(checkedPaths.joined(separator: ", "))"
    }
}
