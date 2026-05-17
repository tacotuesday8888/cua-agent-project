import AutopilotCore
import AutopilotLLM
import Foundation
import Testing
@testable import AutopilotAgent

struct RiskClassifierTests {
    private func snapshot(buttonLabel: String) -> UITreeSnapshot {
        let button = UIElement(id: "e2", role: "AXButton", label: buttonLabel)
        let root = UIElement(id: "e1", role: "AXWindow", children: [button])
        return UITreeSnapshot(appName: "App", root: root)
    }

    @Test func destructiveButtonIsRisky() {
        let risk = RiskClassifier().assess(
            tool: .click,
            input: ["element_index": 2],
            snapshot: snapshot(buttonLabel: "Delete Playlist")
        )
        #expect(risk == .risky)
    }

    @Test func ordinaryButtonIsSafe() {
        let risk = RiskClassifier().assess(
            tool: .click,
            input: ["element_index": 2],
            snapshot: snapshot(buttonLabel: "Play")
        )
        #expect(risk == .safe)
    }

    @Test func nonClickToolsAreSafe() {
        let classifier = RiskClassifier()
        #expect(classifier.assess(tool: .getAppState, input: [:], snapshot: nil) == .safe)
        #expect(classifier.assess(tool: .setValue, input: [:], snapshot: nil) == .safe)
        #expect(classifier.assess(tool: .scroll, input: [:], snapshot: nil) == .safe)
    }
}

struct ToolCatalogTests {
    @Test func exposesComputerUseToolSurface() {
        let names = Set(ToolCatalog.all.map(\.name))
        #expect(names.isSuperset(of: Set([
            "list_apps",
            "get_app_state",
            "click",
            "scroll",
            "type_text",
            "press_key",
            "set_value",
            "drag",
            "perform_secondary_action"
        ])))
        #expect(!names.contains("read_tree"))
        #expect(!names.contains("click_element"))
        #expect(!names.contains("key"))
        #expect(!names.contains("screenshot"))
    }
}

struct AgentSessionTests {
    private func musicComputer() -> MockComputer {
        let field = UIElement(id: "e2", role: "AXTextField", label: "Search", value: "")
        let button = UIElement(id: "e3", role: "AXButton", label: "Play", actions: ["AXShowMenu"])
        let root = UIElement(id: "e1", role: "AXWindow", label: "Music",
                             children: [field, button])
        return MockComputer(appName: "Music", root: root, windowTitle: "Library")
    }

    private func toolResponse(id: String, tool: String, input: JSONValue) -> LLMResponse {
        LLMResponse(
            content: [.toolUse(ToolUse(id: id, name: tool, input: input))],
            stopReason: .toolUse,
            usage: .init(inputTokens: 1, outputTokens: 1)
        )
    }

    @Test func runsToolSequenceToCompletion() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "set_value",
                         input: ["element_index": 2, "value": "jazz"]),
            toolResponse(id: "t2", tool: "click", input: ["element_index": 3]),
            toolResponse(id: "t3", tool: "done", input: ["summary": "Played jazz."])
        ])
        let computer = musicComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10)
        )

        let outcome = await session.run(task: "Play some jazz")
        #expect(outcome.status == .completed)
        #expect(outcome.summary == "Played jazz.")

        let actions = await computer.performedActions
        #expect(actions == ["setValue:e2=jazz", "click:e3"])
    }

    @Test func runsComputerUseToolSurface() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "list_apps", input: [:]),
            toolResponse(id: "t2", tool: "get_app_state", input: [:]),
            toolResponse(id: "t3", tool: "type_text", input: ["text": "blue note"]),
            toolResponse(id: "t4", tool: "press_key", input: ["key": "return"]),
            toolResponse(id: "t5", tool: "drag",
                         input: ["from_element_index": 2, "to_element_index": 3]),
            toolResponse(id: "t6", tool: "perform_secondary_action",
                         input: ["element_index": 3, "action": "AXShowMenu"]),
            toolResponse(id: "t7", tool: "done", input: ["summary": "Done."])
        ])
        let computer = musicComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10)
        )

        let outcome = await session.run(task: "exercise tools")
        #expect(outcome.status == .completed)

        let actions = await computer.performedActions
        #expect(actions == [
            "typeText:blue note",
            "key:return",
            "drag:e2->e3",
            "secondary:e3:AXShowMenu"
        ])
    }

    @Test func invalidElementReturnsRecoveryInstruction() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 99]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let computer = musicComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10)
        )

        _ = await session.run(task: "click missing")

        let requests = await llm.requests
        #expect(requests.count == 2)
        let toolResult = requests.last?.messages.last?.content.compactMap { block -> ToolResult? in
            if case .toolResult(let result) = block { return result }
            return nil
        }.first

        #expect(toolResult?.isError == true)
        let text = toolResult?.content.compactMap { content -> String? in
            if case .text(let text) = content { return text }
            return nil
        }.joined(separator: "\n") ?? ""
        #expect(text.contains("No element e99"))
        #expect(text.contains("Call get_app_state again"))

        let actions = await computer.performedActions
        #expect(actions.isEmpty)
    }

    @Test func failedDiagnosticsStopsBeforeLLMCall() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "done", input: ["summary": "Should not run."])
        ])
        let computer = UnreadyComputer(appName: "BrokenApp")
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test")
        )

        let outcome = await session.run(task: "do something")
        #expect(outcome.status == .failed)
        #expect(outcome.summary.contains("Driver readiness check found 1 failure"))
        #expect(outcome.summary.contains("Accessibility permission"))

        let requests = await llm.requests
        #expect(requests.isEmpty)
    }

    @Test func deniedRiskyActionIsNotPerformed() async {
        let deleteButton = UIElement(id: "e2", role: "AXButton", label: "Delete Playlist")
        let root = UIElement(id: "e1", role: "AXWindow", children: [deleteButton])
        let computer = MockComputer(appName: "Music", root: root)
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 2]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Did not delete."])
        ])
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: DenyingInteraction(),
            configuration: AgentConfiguration(model: "test")
        )

        let outcome = await session.run(task: "delete the playlist")
        #expect(outcome.status == .completed)
        let actions = await computer.performedActions
        #expect(actions.isEmpty)
    }

    @Test func emitsLifecycleEvents() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "done", input: ["summary": "Done."])
        ])
        let collector = EventCollector()
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test"),
            eventHandler: { collector.append($0) }
        )

        _ = await session.run(task: "noop")

        let events = collector.all()
        #expect(events.contains { if case .started = $0 { true } else { false } })
        #expect(events.contains { if case .finished = $0 { true } else { false } })
    }
}

struct ComputerUseSmokeRunnerTests {
    private func fixtureComputer() -> MockComputer {
        let field = UIElement(id: "e2", role: "AXTextField", label: "Search", value: "")
        let button = UIElement(id: "e3", role: "AXButton", label: "Run", actions: ["AXShowMenu"])
        let root = UIElement(id: "e1", role: "AXWindow", label: "Fixture",
                             children: [field, button])
        return MockComputer(appName: "Fixture", root: root, windowTitle: "Fixture")
    }

    private func fixturePlan(
        clickElementIndex: Int = 3,
        textElementIndex: Int = 2
    ) -> ComputerUseSmokePlan {
        ComputerUseSmokePlan(
            clickElementIndex: clickElementIndex,
            scrollElementIndex: nil,
            scrollDirection: .down,
            scrollAmount: 2,
            textElementIndex: textElementIndex,
            setValue: "direct value",
            typeText: "typed value",
            keyPress: KeyPress(key: "return"),
            dragFromElementIndex: 2,
            dragToElementIndex: 3,
            secondaryElementIndex: 3,
            secondaryAction: "AXShowMenu"
        )
    }

    @Test func smokeRunnerCoversNineToolSurface() async {
        let computer = fixtureComputer()
        let report = await ComputerUseSmokeRunner().run(
            computer: computer,
            plan: fixturePlan()
        )

        #expect(report.passed)
        #expect(report.steps.map(\.toolName) == [
            "list_apps",
            "get_app_state",
            "click",
            "scroll",
            "type_text",
            "press_key",
            "set_value",
            "drag",
            "perform_secondary_action"
        ])

        let actions = await computer.performedActions
        #expect(actions == [
            "click:e3",
            "scroll:down:2",
            "typeText:typed value",
            "key:return",
            "setValue:e2=direct value",
            "drag:e2->e3",
            "secondary:e3:AXShowMenu"
        ])
    }

    @Test func smokeRunnerStopsOnFirstFailedTool() async {
        let computer = fixtureComputer()
        let report = await ComputerUseSmokeRunner().run(
            computer: computer,
            plan: fixturePlan(clickElementIndex: 99)
        )

        #expect(!report.passed)
        #expect(report.steps.map(\.toolName) == [
            "list_apps",
            "get_app_state",
            "click"
        ])
        #expect(report.steps.last?.detail.contains("No element e99") == true)

        let actions = await computer.performedActions
        #expect(actions.isEmpty)
    }
}

/// A `UserInteraction` that declines every risky action, for tests.
struct DenyingInteraction: UserInteraction {
    func confirmRiskyAction(summary: String) async -> Bool { false }
    func askQuestion(_ question: String) async -> String { "" }
}

/// A thread-safe sink that records emitted `AgentEvent`s for assertions.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func all() -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

actor UnreadyComputer: ComputerControl {
    nonisolated let appName: String

    init(appName: String) {
        self.appName = appName
    }

    func diagnose() async -> ComputerDiagnostics {
        ComputerDiagnostics(appName: appName, checks: [
            ComputerDiagnosticCheck(
                id: "accessibility",
                status: .failed,
                title: "Accessibility permission",
                detail: "Missing.",
                recovery: "Grant Accessibility."
            )
        ])
    }

    func captureTree() async throws -> UITreeSnapshot {
        throw AgentError.computer("captureTree should not be called")
    }

    func click(elementID: String) async throws {
        throw AgentError.computer("click should not be called")
    }

    func setValue(elementID: String, value: String) async throws {
        throw AgentError.computer("setValue should not be called")
    }

    func scroll(elementID: String?, direction: ScrollDirection, amount: Int) async throws {
        throw AgentError.computer("scroll should not be called")
    }

    func pressKey(_ key: KeyPress) async throws {
        throw AgentError.computer("pressKey should not be called")
    }

    func captureScreenshot() async throws -> Data {
        throw AgentError.computer("captureScreenshot should not be called")
    }
}
