import AutopilotCore
import AutopilotLLM
import AutopilotMemory
import Foundation
import Testing
@testable import AutopilotAgent

struct RiskClassifierTests {
    private func buttonSnapshot(label: String) -> UITreeSnapshot {
        let button = UIElement(id: "e2", role: "AXButton", label: label)
        let root = UIElement(id: "e1", role: "AXWindow", children: [button])
        return UITreeSnapshot(appName: "App", root: root)
    }

    private func fieldSnapshot(value: String) -> UITreeSnapshot {
        let field = UIElement(id: "e2", role: "AXTextField", label: "Note", value: value)
        let root = UIElement(id: "e1", role: "AXWindow", children: [field])
        return UITreeSnapshot(appName: "App", root: root)
    }

    @Test func readingAndScrollingAreSafe() {
        let classifier = RiskClassifier()
        #expect(classifier.assess(tool: .getAppState, input: [:], snapshot: nil) == .safe)
        #expect(classifier.assess(tool: .listApps, input: [:], snapshot: nil) == .safe)
        #expect(classifier.assess(
            tool: .scroll,
            input: ["direction": "down"],
            snapshot: nil
        ) == .safe)
    }

    @Test func ordinaryClickIsWrite() {
        let risk = RiskClassifier().assess(
            tool: .click,
            input: ["element_index": 2],
            snapshot: buttonSnapshot(label: "Play")
        )
        #expect(risk == .write)
    }

    @Test func destructiveButtonIsDestructive() {
        let risk = RiskClassifier().assess(
            tool: .click,
            input: ["element_index": 2],
            snapshot: buttonSnapshot(label: "Delete Playlist")
        )
        #expect(risk == .destructive)
    }

    @Test func typingAndDraggingAreWrite() {
        let classifier = RiskClassifier()
        #expect(classifier.assess(
            tool: .typeText,
            input: ["text": "hello"],
            snapshot: nil
        ) == .write)
        #expect(classifier.assess(
            tool: .drag,
            input: ["from_element_index": 2, "to_element_index": 3],
            snapshot: nil
        ) == .write)
    }

    @Test func setValueOntoEmptyFieldIsWrite() {
        let risk = RiskClassifier().assess(
            tool: .setValue,
            input: ["element_index": 2, "value": "jazz"],
            snapshot: fieldSnapshot(value: "")
        )
        #expect(risk == .write)
    }

    @Test func setValueOntoFilledFieldIsDestructive() {
        let risk = RiskClassifier().assess(
            tool: .setValue,
            input: ["element_index": 2, "value": "jazz"],
            snapshot: fieldSnapshot(value: "existing draft")
        )
        #expect(risk == .destructive)
    }

    @Test func commandDeleteKeyPressIsDestructive() {
        let risk = RiskClassifier().assess(
            tool: .pressKey,
            input: ["key": "delete", "modifiers": ["command"]],
            snapshot: nil
        )
        #expect(risk == .destructive)
    }

    @Test func plainKeyPressIsWrite() {
        let risk = RiskClassifier().assess(
            tool: .pressKey,
            input: ["key": "return"],
            snapshot: nil
        )
        #expect(risk == .write)
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

    @Test func includesProposeMemoryTool() {
        #expect(ToolCatalog.all.contains { $0.name == "propose_memory" })
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
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
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
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
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
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
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

    @Test func failedActionResultCarriesFreshAppState() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 99]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let computer = musicComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "click missing")

        let requests = await llm.requests
        let toolResult = requests.last?.messages.last?.content.compactMap { block -> ToolResult? in
            if case .toolResult(let result) = block { return result }
            return nil
        }.first
        let text = toolResult?.content.compactMap { content -> String? in
            if case .text(let text) = content { return text }
            return nil
        }.joined(separator: "\n") ?? ""

        #expect(toolResult?.isError == true)
        #expect(text.contains("No element e99"))
        // A failed action re-reads the app so the model recovers at once,
        // rather than spending a turn calling get_app_state itself.
        #expect(text.contains("Current state of Music"))
        #expect(text.contains("\"Play\""))
    }

    @Test func failedActionEmitsActionFailedEvent() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 99]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let collector = EventCollector()
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory(),
            eventHandler: { collector.append($0) }
        )

        _ = await session.run(task: "click missing")

        let failure = collector.all().compactMap { event -> (AgentTool, String)? in
            if case .actionFailed(let tool, let reason) = event { return (tool, reason) }
            return nil
        }.first
        #expect(failure?.0 == .click)
        #expect(failure?.1.contains("No element e99") == true)
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
            configuration: AgentConfiguration(model: "test", highlightDwell: .zero),
            memory: makeTestMemory()
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
            configuration: AgentConfiguration(model: "test", highlightDwell: .zero),
            memory: makeTestMemory()
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
            configuration: AgentConfiguration(model: "test", highlightDwell: .zero),
            memory: makeTestMemory(),
            eventHandler: { collector.append($0) }
        )

        _ = await session.run(task: "noop")

        let events = collector.all()
        #expect(events.contains { if case .started = $0 { true } else { false } })
        #expect(events.contains { if case .finished = $0 { true } else { false } })
    }

    @Test func typeTextWithElementIndexUsesFocusedTypingPath() async {
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "type_text",
                input: ["element_index": 2, "text": "focused text"]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let computer = musicComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 5, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "type into search")
        #expect(outcome.status == .completed)

        let actions = await computer.performedActions
        #expect(actions == ["typeText:e2:focused text"])
    }

    @Test func longRunPrunesStaleObservations() async {
        var responses = (1...8).map { index in
            toolResponse(id: "g\(index)", tool: "get_app_state", input: [:])
        }
        responses.append(toolResponse(id: "fin", tool: "done", input: ["summary": "Done."]))
        let llm = ScriptedLLMProvider(responses)
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(
                model: "test",
                maxSteps: 12,
                highlightDwell: .zero,
                liveObservationWindow: 3
            ),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "read repeatedly")
        #expect(outcome.status == .completed)

        let requests = await llm.requests
        // The first request carries only the initial tree — nothing to prune.
        #expect(occurrences(of: "App: Music", in: allText(in: requests[0])) == 1)
        // The final request has seen the initial tree plus eight get_app_state
        // reads, but only the observation window stays verbatim.
        let finalText = allText(in: requests[requests.count - 1])
        #expect(occurrences(of: "App: Music", in: finalText) == 3)
        #expect(occurrences(of: "Earlier app state omitted", in: finalText) >= 1)
    }

    @Test func prunedTranscriptKeepsToolResultPairing() async {
        var responses = (1...6).map { index in
            toolResponse(id: "g\(index)", tool: "get_app_state", input: [:])
        }
        responses.append(toolResponse(id: "fin", tool: "done", input: ["summary": "Done."]))
        let llm = ScriptedLLMProvider(responses)
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(
                model: "test",
                maxSteps: 10,
                highlightDwell: .zero,
                liveObservationWindow: 2
            ),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "read repeatedly")
        #expect(outcome.status == .completed)

        // Every tool_use must still have a matching tool_result, pruned or not.
        let requests = await llm.requests
        let finalMessages = requests[requests.count - 1].messages
        let toolUseIDs = Set(finalMessages.flatMap { message in
            message.content.compactMap { block -> String? in
                if case .toolUse(let use) = block { return use.id }
                return nil
            }
        })
        let toolResultIDs = Set(finalMessages.flatMap { message in
            message.content.compactMap { block -> String? in
                if case .toolResult(let result) = block { return result.toolUseID }
                return nil
            }
        })
        #expect(toolUseIDs == toolResultIDs)
    }

    @Test func accumulatesTokenUsageAcrossSteps() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "get_app_state", input: [:]),
            toolResponse(id: "t2", tool: "get_app_state", input: [:]),
            toolResponse(id: "t3", tool: "done", input: ["summary": "Done."])
        ])
        let collector = EventCollector()
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory(),
            eventHandler: { collector.append($0) }
        )

        _ = await session.run(task: "read twice")

        let usage = collector.all().compactMap { event -> (Int, Int)? in
            if case .tokenUsage(let input, let output) = event { return (input, output) }
            return nil
        }
        // One usage event per LLM call, each carrying the cumulative tally.
        #expect(usage.count == 3)
        #expect(usage.map(\.0) == [1, 2, 3])
        #expect(usage.last?.1 == 3)
    }

    @Test func warnsModelWhenStepBudgetRunsLow() async {
        let llm = ScriptedLLMProvider((1...3).map { index in
            toolResponse(id: "g\(index)", tool: "get_app_state", input: [:])
        })
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 3, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "never finishes")
        #expect(outcome.status == .failed)
        #expect(outcome.summary.contains("3-step limit"))

        let requests = await llm.requests
        #expect(requests.count == 3)
        #expect(!allText(in: requests[0]).contains("Step budget"))
        #expect(allText(in: requests[1]).contains("2 steps remain"))
        #expect(allText(in: requests[2]).contains("only 1 step remains"))
    }

    private func allText(in request: LLMRequest) -> String {
        request.messages.flatMap { message in
            message.content.flatMap { block -> [String] in
                switch block {
                case .text(let text):
                    return [text]
                case .toolResult(let result):
                    return result.content.compactMap { content in
                        if case .text(let text) = content { return text }
                        return nil
                    }
                case .toolUse, .image:
                    return []
                }
            }
        }
        .joined(separator: "\n")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }
}

struct ComputerUseSmokeRunnerTests {
    private func fixtureComputer() -> MockComputer {
        let field = UIElement(
            id: "e2",
            role: "AXTextField",
            identifier: "fixture.input",
            label: "Search",
            value: ""
        )
        let button = UIElement(
            id: "e3",
            role: "AXButton",
            identifier: "fixture.button",
            label: "Run",
            actions: ["AXShowMenu"]
        )
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
            "set_value",
            "type_text",
            "press_key",
            "drag",
            "perform_secondary_action"
        ])

        let actions = await computer.performedActions
        #expect(actions == [
            "click:e3",
            "scroll:down:2",
            "setValue:e2=direct value",
            "typeText:e2:typed value",
            "key:return",
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

    @Test func fixturePlanResolvesAccessibilityIdentifiers() throws {
        let input = UIElement(
            id: "e10",
            role: "AXTextField",
            identifier: "fixture.input"
        )
        let scroll = UIElement(
            id: "e11",
            role: "AXScrollArea",
            identifier: "fixture.scroll"
        )
        let button = UIElement(
            id: "e12",
            role: "AXButton",
            identifier: "fixture.button",
            actions: ["AXPress"]
        )
        let source = UIElement(
            id: "e13",
            role: "AXGroup",
            identifier: "fixture.source"
        )
        let target = UIElement(
            id: "e14",
            role: "AXGroup",
            identifier: "fixture.target"
        )
        let snapshot = UITreeSnapshot(
            appName: "Fixture",
            root: UIElement(
                id: "e0",
                role: "AXWindow",
                children: [input, scroll, button, source, target]
            )
        )

        let plan = try ComputerUseSmokePlan.autopilotFixturePlan(
            for: snapshot,
            identifiers: ComputerUseSmokeFixtureIdentifiers(
                clickIdentifier: "fixture.button",
                scrollIdentifier: "fixture.scroll",
                textIdentifier: "fixture.input",
                dragFromIdentifier: "fixture.source",
                dragToIdentifier: "fixture.target",
                secondaryIdentifier: "fixture.button",
                secondaryAction: "AXPress"
            )
        )

        #expect(plan.clickElementIndex == 12)
        #expect(plan.scrollElementIndex == 11)
        #expect(plan.textElementIndex == 10)
        #expect(plan.dragFromElementIndex == 13)
        #expect(plan.dragToElementIndex == 14)
        #expect(plan.secondaryElementIndex == 12)
        #expect(plan.secondaryAction == "AXPress")
    }

    @Test func smokeRunnerCanResolvePlanFromCurrentState() async {
        let computer = fixtureComputer()
        let report = await ComputerUseSmokeRunner().run(
            computer: computer,
            planForState: { state in
                try ComputerUseSmokePlan.autopilotFixturePlan(
                    for: state.snapshot,
                    identifiers: ComputerUseSmokeFixtureIdentifiers(
                        clickIdentifier: "fixture.button",
                        scrollIdentifier: nil,
                        textIdentifier: "fixture.input",
                        dragFromIdentifier: "fixture.input",
                        dragToIdentifier: "fixture.button",
                        secondaryIdentifier: "fixture.button",
                        secondaryAction: "AXShowMenu"
                    )
                )
            }
        )

        #expect(report.passed)
        #expect(report.steps.map(\.toolName) == [
            "list_apps",
            "get_app_state",
            "click",
            "scroll",
            "set_value",
            "type_text",
            "press_key",
            "drag",
            "perform_secondary_action"
        ])
    }
}

/// A `MemoryStore` backed by a unique temporary directory, for tests.
func makeTestMemory() -> MemoryStore {
    MemoryStore(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
}

/// A `UserInteraction` that declines every approval and memory prompt.
struct DenyingInteraction: UserInteraction {
    func requestApproval(_ request: ApprovalRequest) async -> Bool { false }
    func askQuestion(_ question: String) async -> String { "" }
    func confirmMemory(_ proposal: MemoryProposal) async -> Bool { false }
}

/// A `UserInteraction` that approves every action and saves every proposed
/// memory, for tests of the accept paths.
struct AcceptingMemoryInteraction: UserInteraction {
    func requestApproval(_ request: ApprovalRequest) async -> Bool { true }
    func askQuestion(_ question: String) async -> String { "" }
    func confirmMemory(_ proposal: MemoryProposal) async -> Bool { true }
}

/// A `UserInteraction` that approves every action and counts how many times it
/// was asked, for tests of the per-app trust gate.
final class CountingInteraction: UserInteraction, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func requestApproval(_ request: ApprovalRequest) async -> Bool {
        lock.withLock { count += 1 }
        return true
    }

    func askQuestion(_ question: String) async -> String { "" }
    func confirmMemory(_ proposal: MemoryProposal) async -> Bool { false }

    /// How many approval requests have been made so far.
    var approvalsRequested: Int {
        lock.withLock { count }
    }
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
