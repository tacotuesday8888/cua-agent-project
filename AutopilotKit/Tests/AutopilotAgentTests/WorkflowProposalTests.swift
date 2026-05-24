import AutopilotCore
import AutopilotLLM
import Testing
@testable import AutopilotAgent

/// The agent can propose saving a finished task as a reusable workflow. The
/// engine surfaces the proposal and reports the user's choice; persistence lives
/// in the UI layer, so these tests cover the engine contract only.
struct WorkflowProposalTests {
    private func mailComputer() -> MockComputer {
        let root = UIElement(id: "e1", role: "AXWindow", label: "Mail")
        return MockComputer(appName: "Mail", root: root, windowTitle: "Inbox")
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

    @Test func acceptedProposeWorkflowConfirmsAndEmitsEvents() async {
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "propose_workflow",
                input: [
                    "name": "Weekly report",
                    "goal_template": "Email {{recipient}} the report",
                    "recipe": "Open Compose first, then fill To."
                ]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let collector = EventCollector()
        let session = AgentSession(
            llm: llm,
            computer: mailComputer(),
            interaction: AcceptingWorkflowInteraction(),
            configuration: config(),
            memory: makeTestMemory(),
            eventHandler: { collector.append($0) }
        )

        let outcome = await session.run(task: "Email Maya the report")
        #expect(outcome.status == .completed)

        #expect(collector.all().contains {
            if case .workflowProposed(let proposal) = $0 {
                return proposal.name == "Weekly report"
                    && proposal.recipe == "Open Compose first, then fill To."
            }
            return false
        })
        #expect(collector.all().contains {
            if case .workflowSaved(let name) = $0 { return name == "Weekly report" }
            return false
        })

        let requests = await llm.requests
        let recovery = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recovery.contains("Saved \"Weekly report\""))
    }

    @Test func declinedProposeWorkflowIsReportedNotSaved() async {
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "propose_workflow",
                input: ["name": "Weekly report", "goal_template": "Email {{recipient}}"]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let collector = EventCollector()
        // AutomaticApproval declines proposed workflows by default.
        let session = AgentSession(
            llm: llm,
            computer: mailComputer(),
            interaction: AutomaticApproval(),
            configuration: config(),
            memory: makeTestMemory(),
            eventHandler: { collector.append($0) }
        )

        _ = await session.run(task: "Email Maya")

        #expect(collector.all().contains {
            if case .workflowProposed = $0 { return true }
            return false
        })
        #expect(!collector.all().contains {
            if case .workflowSaved = $0 { return true }
            return false
        })

        let requests = await llm.requests
        let recovery = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recovery.contains("chose not to save"))
    }

    @Test func proposeWorkflowMissingNameReturnsToolError() async {
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "propose_workflow",
                input: ["goal_template": "Email {{recipient}}"]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let session = AgentSession(
            llm: llm,
            computer: mailComputer(),
            interaction: AcceptingWorkflowInteraction(),
            configuration: config(),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "Email Maya")

        let requests = await llm.requests
        let recovery = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recovery.contains("Invalid input for propose_workflow"))
        #expect(recovery.contains("name must be a non-empty string"))
    }

    @Test func proposeWorkflowMissingGoalReturnsToolError() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "propose_workflow", input: ["name": "X"]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let session = AgentSession(
            llm: llm,
            computer: mailComputer(),
            interaction: AcceptingWorkflowInteraction(),
            configuration: config(),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "Email Maya")

        let requests = await llm.requests
        let recovery = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recovery.contains("goal_template must be a non-empty string"))
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
}
