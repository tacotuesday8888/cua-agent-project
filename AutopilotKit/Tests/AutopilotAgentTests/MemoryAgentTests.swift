import AutopilotCore
import AutopilotLLM
import AutopilotMemory
import Testing
@testable import AutopilotAgent

struct MemoryAgentTests {
    private func musicComputer() -> MockComputer {
        let field = UIElement(id: "e2", role: "AXTextField", label: "Search", value: "")
        let root = UIElement(id: "e1", role: "AXWindow", label: "Music", children: [field])
        return MockComputer(appName: "Music", root: root, windowTitle: "Library")
    }

    private func toolResponse(id: String, tool: String, input: JSONValue) -> LLMResponse {
        LLMResponse(
            content: [.toolUse(ToolUse(id: id, name: tool, input: input))],
            stopReason: .toolUse,
            usage: .init(inputTokens: 1, outputTokens: 1)
        )
    }

    private func textResponse(_ text: String) -> LLMResponse {
        LLMResponse(
            content: [.text(text)],
            stopReason: .endTurn,
            usage: .init(inputTokens: 1, outputTokens: 1)
        )
    }

    private func config() -> AgentConfiguration {
        AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero)
    }

    @Test func explicitRememberPromptStoresMemoryWithoutRunningATask() async {
        let memory = makeTestMemory()
        let llm = ScriptedLLMProvider([])  // the agent loop must not run
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: config(),
            memory: memory
        )

        let outcome = await session.run(task: "remember: I always reply in lowercase")
        #expect(outcome.status == .completed)
        #expect(outcome.summary == "Saved to memory.")

        let stored = await memory.all()
        #expect(stored.count == 1)
        #expect(stored.first?.text == "I always reply in lowercase")
        #expect(stored.first?.source == .explicit)

        let requests = await llm.requests
        #expect(requests.isEmpty)
    }

    @Test func recalledMemoryEntersTheSystemPrompt() async {
        let memory = makeTestMemory()
        await memory.add(MemoryItem(text: "signs emails with —M", source: .explicit))
        let llm = ScriptedLLMProvider([textResponse("All set.")])
        let collector = EventCollector()
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: config(),
            memory: memory,
            eventHandler: { collector.append($0) }
        )

        _ = await session.run(task: "open the library")

        let requests = await llm.requests
        #expect(requests.first?.system?.contains("signs emails with —M") == true)
        #expect(collector.all().contains {
            if case .memoryRecalled(let items) = $0 { return items.count == 1 }
            return false
        })
    }

    @Test func acceptedProposeMemoryIsStoredWithItsScope() async {
        let memory = makeTestMemory()
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "propose_memory",
                input: ["text": "prefers jazz", "scope": "app", "scope_value": "Music"]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AcceptingMemoryInteraction(),
            configuration: config(),
            memory: memory
        )

        _ = await session.run(task: "play something")

        let stored = await memory.all()
        #expect(stored.count == 1)
        #expect(stored.first?.text == "prefers jazz")
        #expect(stored.first?.scope == .app("Music"))
        #expect(stored.first?.source == .proposed)
    }

    @Test func contactMemoryWithoutContactNameFallsBackToGlobal() async {
        let memory = makeTestMemory()
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "propose_memory",
                input: ["text": "prefers concise replies", "scope": "contact"]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AcceptingMemoryInteraction(),
            configuration: config(),
            memory: memory
        )

        _ = await session.run(task: "play something")

        let stored = await memory.all()
        #expect(stored.first?.scope == .global)
    }

    @Test func declinedProposeMemoryIsNotStored() async {
        let memory = makeTestMemory()
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "propose_memory",
                input: ["text": "prefers jazz", "scope": "global"]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        // AutomaticApproval declines proposed memories by default.
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: config(),
            memory: memory
        )

        _ = await session.run(task: "play something")
        #expect(await memory.all().isEmpty)
    }

    @Test func proposeMemoryEmitsProposedAndStoredEvents() async {
        let memory = makeTestMemory()
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "propose_memory",
                input: ["text": "likes dark mode", "scope": "global"]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let collector = EventCollector()
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AcceptingMemoryInteraction(),
            configuration: config(),
            memory: memory,
            eventHandler: { collector.append($0) }
        )

        _ = await session.run(task: "play something")

        #expect(collector.all().contains {
            if case .memoryProposed(let proposal) = $0 {
                return proposal.text == "likes dark mode"
            }
            return false
        })
        #expect(collector.all().contains {
            if case .memoryStored = $0 { return true }
            return false
        })
    }
}
