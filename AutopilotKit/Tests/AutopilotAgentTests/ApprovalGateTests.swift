import AutopilotCore
import AutopilotLLM
import AutopilotMemory
import Foundation
import Testing
@testable import AutopilotAgent

struct ApprovalGateTests {
    private func notesComputer() -> MockComputer {
        let field = UIElement(id: "e2", role: "AXTextField", label: "Note", value: "")
        let delete = UIElement(id: "e3", role: "AXButton", label: "Delete Note")
        let save = UIElement(id: "e4", role: "AXButton", label: "Save")
        let root = UIElement(id: "e1", role: "AXWindow", label: "Notes",
                             children: [field, delete, save])
        return MockComputer(appName: "Notes", root: root, windowTitle: "Notes")
    }

    private func toolResponse(id: String, tool: String, input: JSONValue) -> LLMResponse {
        LLMResponse(
            content: [.toolUse(ToolUse(id: id, name: tool, input: input))],
            stopReason: .toolUse,
            usage: .init(inputTokens: 1, outputTokens: 1)
        )
    }

    private func config() -> AgentConfiguration {
        AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero)
    }

    @Test func firstWriteAsksThenTrustsTheApp() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "type_text", input: ["element_index": 2, "text": "one"]),
            toolResponse(id: "t2", tool: "type_text", input: ["element_index": 2, "text": "two"]),
            toolResponse(id: "t3", tool: "done", input: ["summary": "Done."])
        ])
        let interaction = CountingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: notesComputer(),
            interaction: interaction,
            configuration: config(),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "type twice")
        #expect(outcome.status == .completed)
        // The first write asks; the second runs free, the app being trusted.
        #expect(interaction.approvalsRequested == 1)
    }

    @Test func destructiveActionAsksEvenAfterTheAppIsTrusted() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "type_text", input: ["element_index": 2, "text": "hi"]),
            toolResponse(id: "t2", tool: "click", input: ["element_index": 3]),
            toolResponse(id: "t3", tool: "done", input: ["summary": "Done."])
        ])
        let interaction = CountingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: notesComputer(),
            interaction: interaction,
            configuration: config(),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "type, then delete the note")
        // The write asks once; the destructive delete asks again despite trust.
        #expect(interaction.approvalsRequested == 2)
    }

    @Test func declinedActionRetryIsBlockedWithoutPromptingAgain() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 4]),
            toolResponse(id: "t2", tool: "click", input: ["element_id": "e4"]),
            toolResponse(id: "t3", tool: "done", input: ["summary": "Done."])
        ])
        let interaction = CountingDenyingInteraction()
        let computer = notesComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: config(),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "try saving")

        #expect(outcome.status == .completed)
        #expect(interaction.approvalsRequested == 1)
        #expect(await computer.performedActions.isEmpty)
    }

    @Test func declinedActionRetryIgnoresUnusedJSONFields() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 4]),
            toolResponse(
                id: "t2",
                tool: "click",
                input: ["element_id": "e4", "unused_reason": "try again"]
            ),
            toolResponse(id: "t3", tool: "done", input: ["summary": "Done."])
        ])
        let interaction = CountingDenyingInteraction()
        let computer = notesComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: config(),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "try saving")

        #expect(interaction.approvalsRequested == 1)
        #expect(await computer.performedActions.isEmpty)
    }

    @Test func decliningOneActionStillAllowsAReviewOfADifferentAction() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 4]),
            toolResponse(id: "t2", tool: "type_text", input: ["element_index": 2, "text": "safe note"]),
            toolResponse(id: "t3", tool: "done", input: ["summary": "Done."])
        ])
        let interaction = CountingDenyingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: notesComputer(),
            interaction: interaction,
            configuration: config(),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "try two alternatives")

        #expect(interaction.approvalsRequested == 2)
    }

    @Test func decliningOneClickStillAllowsAReviewOfADifferentTarget() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 4]),
            toolResponse(id: "t2", tool: "click", input: ["element_index": 3]),
            toolResponse(id: "t3", tool: "done", input: ["summary": "Done."])
        ])
        let interaction = CountingDenyingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: notesComputer(),
            interaction: interaction,
            configuration: config(),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "try two buttons")

        #expect(interaction.approvalsRequested == 2)
    }

    @Test func declinedElementIDIsReReviewedWhenTheTargetChanges() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_id": "e4"]),
            toolResponse(id: "t2", tool: "click", input: ["element_id": "e4"]),
            toolResponse(id: "t3", tool: "done", input: ["summary": "Done."])
        ])
        let computer = notesComputer()
        let interaction = RetargetingDenyingInteraction(
            computer: computer,
            replacementRoot: UIElement(
                id: "e1",
                role: "AXWindow",
                label: "Notes",
                children: [
                    UIElement(id: "e2", role: "AXTextField", label: "Note", value: ""),
                    UIElement(id: "e3", role: "AXButton", label: "Delete Note"),
                    UIElement(id: "e4", role: "AXButton", label: "Archive")
                ]
            )
        )
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: config(),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "try a changed button")

        #expect(interaction.approvalsRequested == 2)
        #expect(await computer.performedActions.isEmpty)
    }

    @Test func declinedKeyPressRetryUsesCanonicalKeysAndModifiers() async {
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "press_key",
                input: ["key": "Delete", "modifiers": ["shift", "command", "command"]]
            ),
            toolResponse(
                id: "t2",
                tool: "press_key",
                input: ["key": "del", "modifiers": ["command", "shift"]]
            ),
            toolResponse(id: "t3", tool: "done", input: ["summary": "Done."])
        ])
        let interaction = CountingDenyingInteraction()
        let computer = notesComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: config(),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "try destructive shortcut")

        #expect(interaction.approvalsRequested == 1)
        #expect(await computer.performedActions.isEmpty)
    }

    @Test func permanentlyTrustedAppSkipsTheFirstWritePrompt() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "type_text", input: ["element_index": 2, "text": "hi"]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let interaction = CountingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: notesComputer(),
            interaction: interaction,
            configuration: config(),
            memory: makeTestMemory(),
            permanentlyTrustedApps: ["Notes"]
        )

        _ = await session.run(task: "type a note")
        #expect(interaction.approvalsRequested == 0)
    }

    @Test func willPerformSurfacesTheActionTarget() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 4]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let collector = EventCollector()
        let session = AgentSession(
            llm: llm,
            computer: notesComputer(),
            interaction: AutomaticApproval(),
            configuration: config(),
            memory: makeTestMemory(),
            eventHandler: { collector.append($0) }
        )

        _ = await session.run(task: "click Save")

        let target = collector.all().compactMap { event -> ActionTarget? in
            if case .willPerform(_, let target, _) = event { return target }
            return nil
        }.first
        #expect(target?.elementID == "e4")
        #expect(target?.label == "Save")
        #expect(target?.description == "Click \"Save\"")
    }
}

private final class CountingDenyingInteraction: UserInteraction, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func requestApproval(_ request: ApprovalRequest) async -> Bool {
        lock.withLock { count += 1 }
        return false
    }

    func askQuestion(_ question: String) async -> String { "" }
    func confirmMemory(_ proposal: MemoryProposal) async -> Bool { false }
    func confirmWorkflow(_ proposal: WorkflowProposal) async -> Bool { false }

    var approvalsRequested: Int {
        lock.withLock { count }
    }
}

private final class RetargetingDenyingInteraction: UserInteraction, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let computer: MockComputer
    private let replacementRoot: UIElement

    init(computer: MockComputer, replacementRoot: UIElement) {
        self.computer = computer
        self.replacementRoot = replacementRoot
    }

    func requestApproval(_ request: ApprovalRequest) async -> Bool {
        let currentCount = lock.withLock {
            count += 1
            return count
        }
        if currentCount == 1 {
            await computer.replaceRoot(replacementRoot)
        }
        return false
    }

    func askQuestion(_ question: String) async -> String { "" }
    func confirmMemory(_ proposal: MemoryProposal) async -> Bool { false }
    func confirmWorkflow(_ proposal: WorkflowProposal) async -> Bool { false }

    var approvalsRequested: Int {
        lock.withLock { count }
    }
}
