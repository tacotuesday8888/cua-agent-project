import AutopilotCore
import AutopilotLLM
import Foundation

/// Configuration for an agent run.
public struct AgentConfiguration: Sendable {
    /// The model identifier passed to the LLM provider.
    public var model: String
    /// Maximum perceive → decide → act steps before giving up.
    public var maxSteps: Int
    /// Maximum tokens generated per LLM call.
    public var maxTokens: Int

    public init(model: String, maxSteps: Int = 25, maxTokens: Int = 4096) {
        self.model = model
        self.maxSteps = maxSteps
        self.maxTokens = maxTokens
    }
}

/// The result of an agent run.
public struct AgentOutcome: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case completed
        case stopped
        case failed
    }

    public let status: Status
    public let summary: String

    public init(status: Status, summary: String) {
        self.status = status
        self.summary = summary
    }
}

/// Drives one task to completion: the perceive → decide → act → verify loop,
/// scoped to a single app.
///
/// Cancel the surrounding `Task` to stop a run early (the kill switch).
public actor AgentSession {
    private let llm: any LLMProvider
    private let computer: any ComputerControl
    private let interaction: any UserInteraction
    private let configuration: AgentConfiguration
    private let emit: @Sendable (AgentEvent) -> Void
    private let classifier = RiskClassifier()

    private var messages: [LLMMessage] = []
    private var latestSnapshot: UITreeSnapshot?

    public init(
        llm: any LLMProvider,
        computer: any ComputerControl,
        interaction: any UserInteraction,
        configuration: AgentConfiguration,
        eventHandler: @escaping @Sendable (AgentEvent) -> Void = { _ in }
    ) {
        self.llm = llm
        self.computer = computer
        self.interaction = interaction
        self.configuration = configuration
        self.emit = eventHandler
    }

    /// Run `task` to completion and return the outcome.
    public func run(task: String) async -> AgentOutcome {
        emit(.started(task: task))

        let initialTree: UITreeSnapshot
        do {
            initialTree = try await observeTree()
        } catch {
            return fail("Could not read \(computer.appName): \(error.localizedDescription)")
        }

        messages = [
            LLMMessage(role: .user, content: [
                .text("""
                Task: \(task)

                Current state of \(computer.appName):
                \(UITreeRenderer.compactText(initialTree))
                """)
            ])
        ]

        for _ in 0..<configuration.maxSteps {
            if Task.isCancelled { return stop() }
            emit(.thinking)

            let response: LLMResponse
            do {
                response = try await llm.send(buildRequest())
            } catch {
                return fail("LLM error: \(error.localizedDescription)")
            }
            messages.append(LLMMessage(role: .assistant, content: response.content))

            let assistantText = response.text
            if !assistantText.isEmpty { emit(.message(assistantText)) }

            let toolUses = response.toolUses
            if toolUses.isEmpty {
                let summary = assistantText.isEmpty ? "Finished." : assistantText
                emit(.finished(summary: summary))
                return AgentOutcome(status: .completed, summary: summary)
            }

            var results: [LLMContentBlock] = []
            for use in toolUses {
                if Task.isCancelled { return stop() }
                if let outcome = await dispatch(use, into: &results) {
                    return outcome
                }
            }
            messages.append(LLMMessage(role: .user, content: results))
        }

        return fail("Reached the \(configuration.maxSteps)-step limit.")
    }

    // MARK: - Step handling

    /// Handle one tool call. Returns a non-nil outcome when the run should end.
    private func dispatch(
        _ use: ToolUse,
        into results: inout [LLMContentBlock]
    ) async -> AgentOutcome? {
        guard let tool = AgentTool(rawValue: use.name) else {
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: "Unknown tool: \(use.name)",
                isError: true
            )))
            return nil
        }

        switch tool {
        case .done:
            let summary = use.input["summary"]?.stringValue ?? "Task complete."
            emit(.finished(summary: summary))
            return AgentOutcome(status: .completed, summary: summary)

        case .askUser:
            let question = use.input["question"]?.stringValue ?? ""
            let answer = await interaction.askQuestion(question)
            emit(.askedUser(question: question, answer: answer))
            results.append(.toolResult(ToolResult(toolUseID: use.id, text: answer)))
            return nil

        default:
            await performAction(tool: tool, use: use, into: &results)
            return nil
        }
    }

    private func performAction(
        tool: AgentTool,
        use: ToolUse,
        into results: inout [LLMContentBlock]
    ) async {
        let summary = actionSummary(tool: tool, input: use.input)
        let risk = classifier.assess(tool: tool, input: use.input, snapshot: latestSnapshot)
        emit(.willPerform(tool: tool, summary: summary, risk: risk))

        if risk == .risky {
            emit(.awaitingConfirmation(summary: summary))
            let approved = await interaction.confirmRiskyAction(summary: summary)
            if !approved {
                emit(.confirmationDenied(summary: summary))
                results.append(.toolResult(ToolResult(
                    toolUseID: use.id,
                    text: "The user declined this action. Do not retry it; choose an alternative or finish."
                )))
                return
            }
        }

        do {
            let content = try await execute(tool: tool, input: use.input)
            emit(.performed(tool: tool, summary: summary))
            results.append(.toolResult(ToolResult(toolUseID: use.id, content: content)))
        } catch {
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: "Action failed: \(error)",
                isError: true
            )))
        }
    }

    /// Perform a computer action and return the tool-result content.
    private func execute(tool: AgentTool, input: JSONValue) async throws -> [ToolResult.Content] {
        switch tool {
        case .readTree:
            let tree = try await observeTree()
            return [.text(UITreeRenderer.compactText(tree))]

        case .clickElement:
            let id = try requireString(input, "element_id", tool: tool)
            try await computer.click(elementID: id)
            return try await observedResult("Clicked \(id).")

        case .setValue:
            let id = try requireString(input, "element_id", tool: tool)
            let value = try requireString(input, "value", tool: tool)
            try await computer.setValue(elementID: id, value: value)
            return try await observedResult("Set \(id) to \"\(value)\".")

        case .scroll:
            let directionRaw = try requireString(input, "direction", tool: tool)
            guard let direction = ScrollDirection(rawValue: directionRaw) else {
                throw AgentError.invalidToolInput(
                    tool: tool.rawValue,
                    detail: "invalid direction \(directionRaw)"
                )
            }
            let amount = input["amount"]?.intValue ?? 3
            try await computer.scroll(
                elementID: input["element_id"]?.stringValue,
                direction: direction,
                amount: amount
            )
            return try await observedResult("Scrolled \(directionRaw).")

        case .pressKey:
            let key = try requireString(input, "key", tool: tool)
            let modifiers = (input["modifiers"]?.arrayValue ?? [])
                .compactMap(\.stringValue)
                .compactMap(KeyPress.Modifier.init(rawValue:))
            try await computer.pressKey(KeyPress(key: key, modifiers: modifiers))
            return try await observedResult("Pressed \(key).")

        case .screenshot:
            let data = try await computer.captureScreenshot()
            return [
                .text("Screenshot of \(computer.appName):"),
                .image(ImageBlock(base64Data: data.base64EncodedString()))
            ]

        case .askUser, .done:
            return []  // handled in `dispatch`
        }
    }

    // MARK: - Helpers

    private func observeTree() async throws -> UITreeSnapshot {
        let tree = try await computer.captureTree()
        latestSnapshot = tree
        emit(.observedTree(elementCount: tree.root.flattened.count))
        return tree
    }

    /// Pair a short message with a freshly-read tree, so the model can verify
    /// the action's effect before continuing.
    private func observedResult(_ prefix: String) async throws -> [ToolResult.Content] {
        let tree = try await observeTree()
        return [.text("""
        \(prefix)

        Updated state of \(computer.appName):
        \(UITreeRenderer.compactText(tree))
        """)]
    }

    private func buildRequest() -> LLMRequest {
        LLMRequest(
            model: configuration.model,
            system: SystemPrompt.build(appName: computer.appName),
            messages: messages,
            tools: ToolCatalog.all,
            maxTokens: configuration.maxTokens
        )
    }

    private func stop() -> AgentOutcome {
        emit(.stopped)
        return AgentOutcome(status: .stopped, summary: "Stopped by the user.")
    }

    private func fail(_ reason: String) -> AgentOutcome {
        emit(.failed(reason: reason))
        return AgentOutcome(status: .failed, summary: reason)
    }

    private func requireString(
        _ input: JSONValue,
        _ key: String,
        tool: AgentTool
    ) throws -> String {
        guard let value = input[key]?.stringValue else {
            throw AgentError.invalidToolInput(tool: tool.rawValue, detail: "missing \(key)")
        }
        return value
    }

    private func actionSummary(tool: AgentTool, input: JSONValue) -> String {
        switch tool {
        case .clickElement:
            let id = input["element_id"]?.stringValue ?? "?"
            if let label = latestSnapshot?.element(id: id)?.label, !label.isEmpty {
                return "Click \"\(label)\""
            }
            return "Click \(id)"
        case .setValue:
            return "Type \"\(input["value"]?.stringValue ?? "")\""
        case .scroll:
            return "Scroll \(input["direction"]?.stringValue ?? "")"
        case .pressKey:
            return "Press \(input["key"]?.stringValue ?? "key")"
        case .screenshot:
            return "Take a screenshot"
        case .readTree:
            return "Read the screen"
        case .askUser:
            return "Ask a question"
        case .done:
            return "Finish"
        }
    }
}
