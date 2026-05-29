import AutopilotCore
import Foundation

/// A repeatable real-app validation task loaded by the smoke CLI.
public struct AgentValidationScenario: Codable, Equatable, Sendable {
    public var id: String
    public var app: String
    public var task: String
    public var provider: String?
    public var maxSteps: Int?
    public var includeScreenshot: Bool?
    public var expect: AgentValidationExpectations

    public init(
        id: String,
        app: String,
        task: String,
        provider: String? = nil,
        maxSteps: Int? = nil,
        includeScreenshot: Bool? = nil,
        expect: AgentValidationExpectations = AgentValidationExpectations()
    ) {
        self.id = id
        self.app = app
        self.task = task
        self.provider = provider
        self.maxSteps = maxSteps
        self.includeScreenshot = includeScreenshot
        self.expect = expect
    }
}

/// Expected outcomes for a validation scenario. Every non-nil field becomes a
/// report check.
public struct AgentValidationExpectations: Codable, Equatable, Sendable {
    public var finalStatus: String?
    public var stateContainsText: String?
    public var toolUsed: String?
    public var noActionFailures: Bool?
    public var windowTitleContainsText: String?

    public init(
        finalStatus: String? = nil,
        stateContainsText: String? = nil,
        toolUsed: String? = nil,
        noActionFailures: Bool? = nil,
        windowTitleContainsText: String? = nil
    ) {
        self.finalStatus = finalStatus
        self.stateContainsText = stateContainsText
        self.toolUsed = toolUsed
        self.noActionFailures = noActionFailures
        self.windowTitleContainsText = windowTitleContainsText
    }
}

public struct AgentValidationCheck: Codable, Equatable, Sendable {
    public var name: String
    public var passed: Bool
    public var detail: String

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

public struct AgentValidationReport: Codable, Equatable, Sendable {
    public var scenarioID: String
    public var passed: Bool
    public var checks: [AgentValidationCheck]
    public var summary: String

    public init(scenarioID: String, checks: [AgentValidationCheck]) {
        self.scenarioID = scenarioID
        self.checks = checks
        self.passed = checks.allSatisfy(\.passed)
        self.summary = passed
            ? "Scenario \(scenarioID) passed \(checks.count) check(s)."
            : "Scenario \(scenarioID) failed \(checks.filter { !$0.passed }.count) of \(checks.count) check(s)."
    }
}

public enum AgentValidationEvaluator {
    public static func evaluate(
        scenario: AgentValidationScenario,
        outcome: AgentOutcome,
        events: [AgentEvent],
        finalSnapshot: UITreeSnapshot?
    ) -> AgentValidationReport {
        var checks: [AgentValidationCheck] = []
        let expect = scenario.expect

        if let finalStatus = expect.finalStatus {
            let actual = statusString(outcome.status)
            checks.append(AgentValidationCheck(
                name: "finalStatus",
                passed: actual == finalStatus,
                detail: "expected \(finalStatus), got \(actual)"
            ))
        }

        if let text = expect.stateContainsText {
            let found = finalSnapshot?.root.flattened.contains { element in
                element.label?.contains(text) == true
                    || element.value?.contains(text) == true
            } ?? false
            checks.append(AgentValidationCheck(
                name: "stateContainsText",
                passed: found,
                detail: found ? "found \"\(text)\"" : "did not find \"\(text)\""
            ))
        }

        if let tool = expect.toolUsed {
            let used = events.contains { event in
                if case .performed(let performedTool, _) = event {
                    return performedTool.rawValue == tool
                }
                return false
            }
            checks.append(AgentValidationCheck(
                name: "toolUsed",
                passed: used,
                detail: used ? "used \(tool)" : "did not use \(tool)"
            ))
        }

        if let noActionFailures = expect.noActionFailures {
            let failureCount = events.filter {
                if case .actionFailed = $0 { return true }
                return false
            }.count
            let passed = noActionFailures ? failureCount == 0 : failureCount > 0
            checks.append(AgentValidationCheck(
                name: "noActionFailures",
                passed: passed,
                detail: "\(failureCount) action failure(s)"
            ))
        }

        if let text = expect.windowTitleContainsText {
            let title = finalSnapshot?.windowTitle ?? ""
            checks.append(AgentValidationCheck(
                name: "windowTitleContainsText",
                passed: title.contains(text),
                detail: title.isEmpty ? "no window title" : "window title: \(title)"
            ))
        }

        return AgentValidationReport(scenarioID: scenario.id, checks: checks)
    }

    private static func statusString(_ status: AgentOutcome.Status) -> String {
        switch status {
        case .completed: "completed"
        case .stopped: "stopped"
        case .failed: "failed"
        }
    }
}
