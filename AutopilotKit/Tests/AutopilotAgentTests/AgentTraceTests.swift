import AutopilotCore
import AutopilotLLM
import AutopilotMemory
import Foundation
import Testing
@testable import AutopilotAgent

struct AgentTraceEventTests {
    @Test func eventConversionKeepsActionMetadata() throws {
        let target = ActionTarget(
            appName: "TextEdit",
            elementID: "e4",
            role: "AXButton",
            label: "Run",
            identifier: "run-button",
            turnIdentifier: 2,
            description: "Click \"Run\"",
            frame: ElementFrame(x: 10, y: 20, width: 30, height: 40)
        )

        let event = AgentTraceEvent(agentEvent: .willPerform(
            tool: .click,
            target: target,
            tier: .write
        ))

        #expect(event.kind == .willPerform)
        #expect(event.tool == "click")
        #expect(event.riskTier == "write")
        #expect(event.target == target)
    }

    @Test func jsonlRecorderWritesEventsAndArtifacts() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let recorder = try JSONLAgentRunRecorder(directory: directory)

        recorder.record(AgentTraceEvent(
            kind: .runStarted,
            task: "type a note",
            appName: "TextEdit"
        ))
        let artifact = recorder.recordArtifact(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            suggestedFilename: "first screenshot.png"
        )
        recorder.record(AgentTraceEvent(kind: .screenshotCaptured, artifactPath: artifact))

        let traceURL = directory.appending(path: "trace.jsonl")
        let lines = try String(contentsOf: traceURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(AgentTraceEvent.self, from: Data(lines[0].utf8))
        let second = try decoder.decode(AgentTraceEvent.self, from: Data(lines[1].utf8))

        #expect(first.kind == .runStarted)
        #expect(first.task == "type a note")
        #expect(second.kind == .screenshotCaptured)
        #expect(second.artifactPath == "first-screenshot.png")
        #expect(FileManager.default.fileExists(
            atPath: directory.appending(path: "first-screenshot.png").path
        ))
    }

    @Test func agentSessionRecordsTrajectoryEvents() async {
        let recorder = MemoryTraceRecorder()
        let root = UIElement(id: "e1", role: "AXWindow", children: [
            UIElement(id: "e2", role: "AXTextField", label: "Input", isValueSettable: true)
        ])
        let computer = MockComputer(appName: "Fixture", root: root, windowTitle: "Fixture")
        let llm = ScriptedLLMProvider([
            LLMResponse(
                content: [.toolUse(ToolUse(
                    id: "t1",
                    name: "set_value",
                    input: ["element_index": 2, "value": "trace value"]
                ))],
                stopReason: .toolUse,
                usage: .init(inputTokens: 3, outputTokens: 2)
            ),
            LLMResponse(
                content: [.toolUse(ToolUse(
                    id: "t2",
                    name: "done",
                    input: ["summary": "Done."]
                ))],
                stopReason: .toolUse,
                usage: .init(inputTokens: 4, outputTokens: 1)
            )
        ])
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 5, highlightDwell: .zero),
            memory: MemoryStore(directory: URL.temporaryDirectory.appending(path: UUID().uuidString)),
            recorder: recorder
        )

        let outcome = await session.run(task: "Set the input")

        #expect(outcome.status == .completed)
        let kinds = recorder.events.map(\.kind)
        #expect(kinds.contains(.runStarted))
        #expect(kinds.contains(.willPerform))
        #expect(kinds.contains(.performed))
        #expect(kinds.contains(.finished))
        #expect(recorder.events.contains { $0.kind == .tokenUsage && $0.inputTokens == 7 })
    }

    @Test func unchangedActionRecordsVerificationAndWarnsModel() async {
        let recorder = MemoryTraceRecorder()
        let root = UIElement(id: "e1", role: "AXWindow", children: [
            UIElement(id: "e2", role: "AXButton", label: "Run")
        ])
        let computer = MockComputer(appName: "Fixture", root: root, windowTitle: "Fixture")
        let llm = ScriptedLLMProvider([
            LLMResponse(
                content: [.toolUse(ToolUse(
                    id: "t1",
                    name: "click",
                    input: ["element_index": 2]
                ))],
                stopReason: .toolUse,
                usage: .init(inputTokens: 1, outputTokens: 1)
            ),
            LLMResponse(
                content: [.toolUse(ToolUse(
                    id: "t2",
                    name: "done",
                    input: ["summary": "Stopped after no-op."]
                ))],
                stopReason: .toolUse,
                usage: .init(inputTokens: 1, outputTokens: 1)
            )
        ])
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 5, highlightDwell: .zero),
            memory: MemoryStore(directory: URL.temporaryDirectory.appending(path: UUID().uuidString)),
            recorder: recorder
        )

        _ = await session.run(task: "Click Run")

        let requests = await llm.requests
        let recoveryText = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recoveryText.contains("No visible accessibility-tree change was detected"))
        #expect(recoveryText.contains("wait once, re-read, choose a different current element, or ask the user"))
        let verification = recorder.events.first { $0.kind == .actionVerified }?.verification
        #expect(verification?.status == .unchanged)
    }
}

private final class MemoryTraceRecorder: AgentRunRecording, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [AgentTraceEvent] = []

    func record(_ event: AgentTraceEvent) {
        lock.withLock { events.append(event) }
    }
}

private func allText(in request: LLMRequest) -> String {
    request.messages.flatMap(\.content).compactMap { block in
        if case .text(let text) = block { return text }
        if case .toolResult(let result) = block {
            return result.content.compactMap { content in
                if case .text(let text) = content { return text }
                return nil
            }.joined(separator: "\n")
        }
        return nil
    }
    .joined(separator: "\n")
}
