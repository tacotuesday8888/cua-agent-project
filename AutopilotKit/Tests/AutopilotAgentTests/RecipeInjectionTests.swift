import AutopilotCore
import AutopilotLLM
import AutopilotMemory
import Foundation
import Testing
@testable import AutopilotAgent

/// A saved workflow can carry a "recipe" — hints learned from an earlier run —
/// that are injected into the system prompt as a prior. The agent still re-reads
/// and verifies the live screen; the recipe is guidance, not a script.
struct RecipeInjectionTests {
    @Test func recipeSectionAppearsWhenProvided() {
        let prompt = SystemPrompt.build(
            appName: "Mail",
            recipe: "Click Compose, then fill the To field."
        )
        #expect(prompt.contains("Saved workflow guidance"))
        #expect(prompt.contains("Click Compose, then fill the To field."))
        // The framing must keep the live tree authoritative, not the hint.
        #expect(prompt.contains("source of truth"))
    }

    @Test func recipeSectionAbsentWhenNilOrEmpty() {
        #expect(!SystemPrompt.build(appName: "Mail").contains("Saved workflow guidance"))
        #expect(!SystemPrompt.build(appName: "Mail", recipe: "")
            .contains("Saved workflow guidance"))
        #expect(!SystemPrompt.build(appName: "Mail", recipe: "   \n  ")
            .contains("Saved workflow guidance"))
    }

    @Test func configuredRecipeReachesTheRequestSystemPrompt() async {
        let llm = ScriptedLLMProvider([
            LLMResponse(
                content: [.toolUse(ToolUse(id: "t1", name: "done", input: ["summary": "ok"]))],
                stopReason: .toolUse,
                usage: .init(inputTokens: 1, outputTokens: 1)
            )
        ])
        let root = UIElement(id: "e1", role: "AXWindow", label: "Mail")
        let computer = MockComputer(appName: "Mail", root: root, windowTitle: "Inbox")
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(
                model: "test",
                maxSteps: 5,
                highlightDwell: .zero,
                recipe: "Click Compose, then fill the To field."
            ),
            memory: MemoryStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true))
        )

        _ = await session.run(task: "Email Maya")

        let requests = await llm.requests
        #expect(requests.first?.system?.contains("Click Compose, then fill the To field.") == true)
    }

    @Test func ordinaryRunHasNoRecipeSection() async {
        let llm = ScriptedLLMProvider([
            LLMResponse(
                content: [.toolUse(ToolUse(id: "t1", name: "done", input: ["summary": "ok"]))],
                stopReason: .toolUse,
                usage: .init(inputTokens: 1, outputTokens: 1)
            )
        ])
        let root = UIElement(id: "e1", role: "AXWindow", label: "Mail")
        let computer = MockComputer(appName: "Mail", root: root, windowTitle: "Inbox")
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 5, highlightDwell: .zero),
            memory: MemoryStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true))
        )

        _ = await session.run(task: "Email Maya")

        let requests = await llm.requests
        #expect(requests.first?.system?.contains("Saved workflow guidance") == false)
    }
}
