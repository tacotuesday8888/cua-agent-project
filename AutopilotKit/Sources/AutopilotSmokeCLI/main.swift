import AutopilotAgent
import AutopilotCore
import AutopilotLLM
import AutopilotMac
import Darwin
import Foundation

@main
struct AutopilotSmokeCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.contains("--help"), !arguments.contains("-h") else {
            printUsage()
            return
        }

        let target = value(after: "--app", in: arguments) ?? "AutopilotFixtureApp"
        let includeScreenshot = arguments.contains("--include-screenshot")
        let runAgentLoop = arguments.contains("--agent-loop")
        let app = await MainActor.run {
            AppLocator().runningApp(matching: target)
        }

        guard let app else {
            fputs("No running app matched '\(target)'.\n\n", stderr)
            printUsage()
            exit(2)
        }

        let computer = MacComputer(
            pid: app.processID,
            appName: app.name,
            bundleIdentifier: app.bundleIdentifier
        )

        let diagnostics = await computer.diagnose()
        printDiagnostics(diagnostics)
        guard diagnostics.isReady else {
            exit(2)
        }

        if runAgentLoop {
            let passed = await runAgentLoopSmoke(
                computer: computer,
                includeScreenshot: includeScreenshot
            )
            exit(passed ? 0 : 1)
        }

        let report = await ComputerUseSmokeRunner().run(
            computer: computer,
            includeScreenshot: includeScreenshot,
            planForState: { state in
                try ComputerUseSmokePlan.autopilotFixturePlan(
                    for: state.snapshot
                )
            }
        )

        print("")
        print(report.summary)
        for step in report.steps {
            print("- \(step.status.rawValue): \(step.toolName) - \(step.detail)")
        }

        exit(report.passed ? 0 : 1)
    }

    private static func runAgentLoopSmoke(
        computer: MacComputer,
        includeScreenshot: Bool
    ) async -> Bool {
        let plan: ComputerUseSmokePlan
        do {
            let state = try await computer.getAppState(includeScreenshot: false)
            plan = try ComputerUseSmokePlan.autopilotFixturePlan(
                for: state.snapshot
            )
        } catch {
            fputs("Could not resolve fixture smoke plan: \(error.localizedDescription)\n", stderr)
            return false
        }

        print("")
        print("Running scripted AgentSession smoke loop...")

        let recorder = AgentSmokeEventRecorder()
        let llm = ScriptedLLMProvider(agentLoopResponses(
            plan: plan,
            includeScreenshot: includeScreenshot
        ))
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "scripted-smoke", maxSteps: 12),
            eventHandler: { event in
                recorder.append(event)
                if let line = formatAgentEvent(event) {
                    print(line)
                }
            }
        )

        let outcome = await session.run(
            task: "Exercise the computer-use driver surface against the fixture app."
        )

        let expectedTools: [AgentTool] = [
            .listApps,
            .getAppState,
            .click,
            .scroll,
            .setValue,
            .typeText,
            .pressKey,
            .drag,
            .performSecondaryAction
        ]
        let performedTools = recorder.performedTools()
        let passed = outcome.status == .completed && performedTools == expectedTools

        print("")
        print("Agent loop outcome: \(outcome.status) - \(outcome.summary)")
        if !passed {
            print("Expected performed tools: \(expectedTools.map(\.rawValue).joined(separator: ", "))")
            print("Actual performed tools: \(performedTools.map(\.rawValue).joined(separator: ", "))")
        }

        return passed
    }

    private static func agentLoopResponses(
        plan: ComputerUseSmokePlan,
        includeScreenshot: Bool
    ) -> [LLMResponse] {
        var scrollInput: [String: JSONValue] = [
            "direction": .string(plan.scrollDirection.rawValue),
            "amount": .int(plan.scrollAmount)
        ]
        if let scrollElementIndex = plan.scrollElementIndex {
            scrollInput["element_index"] = .int(scrollElementIndex)
        }

        return [
            toolResponse(id: "smoke-1", tool: .listApps, input: [:]),
            toolResponse(
                id: "smoke-2",
                tool: .getAppState,
                input: ["include_screenshot": .bool(includeScreenshot)]
            ),
            toolResponse(
                id: "smoke-3",
                tool: .click,
                input: ["element_index": .int(plan.clickElementIndex)]
            ),
            toolResponse(
                id: "smoke-4",
                tool: .scroll,
                input: .object(scrollInput)
            ),
            toolResponse(
                id: "smoke-5",
                tool: .setValue,
                input: [
                    "element_index": .int(plan.textElementIndex),
                    "value": .string(plan.setValue)
                ]
            ),
            toolResponse(
                id: "smoke-6",
                tool: .typeText,
                input: [
                    "element_index": .int(plan.textElementIndex),
                    "text": .string(plan.typeText)
                ]
            ),
            toolResponse(
                id: "smoke-7",
                tool: .pressKey,
                input: [
                    "key": .string(plan.keyPress.key),
                    "modifiers": .array(plan.keyPress.modifiers.map { .string($0.rawValue) })
                ]
            ),
            toolResponse(
                id: "smoke-8",
                tool: .drag,
                input: [
                    "from_element_index": .int(plan.dragFromElementIndex),
                    "to_element_index": .int(plan.dragToElementIndex)
                ]
            ),
            toolResponse(
                id: "smoke-9",
                tool: .performSecondaryAction,
                input: [
                    "element_index": .int(plan.secondaryElementIndex),
                    "action": .string(plan.secondaryAction)
                ]
            ),
            toolResponse(
                id: "smoke-10",
                tool: .done,
                input: ["summary": "Agent smoke loop completed."]
            )
        ]
    }

    private static func toolResponse(
        id: String,
        tool: AgentTool,
        input: JSONValue
    ) -> LLMResponse {
        LLMResponse(
            content: [.toolUse(ToolUse(
                id: id,
                name: tool.rawValue,
                input: input
            ))],
            stopReason: .toolUse,
            usage: .init(inputTokens: 1, outputTokens: 1)
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }

    private static func printDiagnostics(_ diagnostics: ComputerDiagnostics) {
        print(diagnostics.summary)
        for check in diagnostics.checks {
            var line = "- \(check.status.rawValue): \(check.title) - \(check.detail)"
            if let recovery = check.recovery, !recovery.isEmpty {
                line += " \(recovery)"
            }
            print(line)
        }
    }

    private static func printUsage() {
        print("""
        Usage:
          swift run --package-path AutopilotKit AutopilotFixtureApp
          swift run --package-path AutopilotKit AutopilotSmokeCLI [--app AutopilotFixtureApp] [--include-screenshot] [--agent-loop]

        The fixture app must be running and the smoke runner process must have
        Accessibility permission in System Settings > Privacy & Security.
        """)
    }

}

private final class AgentSmokeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func performedTools() -> [AgentTool] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { event in
            if case .performed(let tool, _) = event {
                return tool
            }
            return nil
        }
    }
}

private func formatAgentEvent(_ event: AgentEvent) -> String? {
    switch event {
    case .started(let task):
        return "- started: \(task)"
    case .diagnostics(let diagnostics):
        return "- diagnostics: \(diagnostics.summary)"
    case .thinking:
        return "- thinking"
    case .observedTree(let elementCount):
        return "- observed_tree: \(elementCount) element(s)"
    case .message(let message):
        return "- message: \(message)"
    case .willPerform(let tool, let summary, let risk):
        return "- will_perform: \(tool.rawValue) - \(summary) (\(risk.rawValue))"
    case .awaitingConfirmation(let summary):
        return "- awaiting_confirmation: \(summary)"
    case .confirmationDenied(let summary):
        return "- confirmation_denied: \(summary)"
    case .performed(let tool, let summary):
        return "- performed: \(tool.rawValue) - \(summary)"
    case .askedUser(let question, let answer):
        return "- asked_user: \(question) -> \(answer)"
    case .finished(let summary):
        return "- finished: \(summary)"
    case .failed(let reason):
        return "- failed: \(reason)"
    case .stopped:
        return "- stopped"
    }
}
