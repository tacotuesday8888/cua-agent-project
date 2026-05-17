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

        let diagnostics = await computer.diagnose()
        emit(.diagnostics(diagnostics))
        guard diagnostics.isReady else {
            return fail(diagnostics.failureSummary)
        }

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
                text: "Action failed: \(describe(error))",
                isError: true
            )))
        }
    }

    /// Perform a computer action and return the tool-result content.
    private func execute(tool: AgentTool, input: JSONValue) async throws -> [ToolResult.Content] {
        switch tool {
        case .listApps:
            let apps = try await computer.listApps()
            return [.text(renderApps(apps))]

        case .getAppState:
            let includeScreenshot = input["include_screenshot"]?.boolValue ?? false
            let state = try await observeState(includeScreenshot: includeScreenshot)
            var content: [ToolResult.Content] = [
                .text(UITreeRenderer.compactText(state.snapshot))
            ]
            if let screenshot = state.screenshot {
                content.append(.image(ImageBlock(base64Data: screenshot.base64EncodedString())))
            }
            return content

        case .click:
            let id = try requireElementID(input, tool: tool)
            try await computer.click(elementID: id)
            return try await observedResult("Clicked \(id).")

        case .setValue:
            let id = try requireElementID(input, tool: tool)
            let value = try requireString(input, "value", tool: tool)
            try await computer.setValue(elementID: id, value: value)
            return try await observedResult("Set \(id) to \"\(value)\".")

        case .typeText:
            if let id = try optionalElementID(input, primaryKey: "element_index") {
                try await computer.click(elementID: id)
            }
            let text = try requireString(input, "text", tool: tool)
            try await computer.typeText(text)
            return try await observedResult("Typed text.")

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
                elementID: try optionalElementID(input, primaryKey: "element_index"),
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

        case .drag:
            let from = try requireElementID(input, key: "from_element_index", tool: tool)
            let to = try requireElementID(input, key: "to_element_index", tool: tool)
            try await computer.drag(fromElementID: from, toElementID: to)
            return try await observedResult("Dragged \(from) to \(to).")

        case .performSecondaryAction:
            let id = try requireElementID(input, tool: tool)
            let action = try requireString(input, "action", tool: tool)
            try await computer.performSecondaryAction(elementID: id, action: action)
            return try await observedResult("Performed \(action) on \(id).")

        case .askUser, .done:
            return []  // handled in `dispatch`
        }
    }

    // MARK: - Helpers

    private func observeTree() async throws -> UITreeSnapshot {
        (try await observeState(includeScreenshot: false)).snapshot
    }

    private func observeState(includeScreenshot: Bool) async throws -> ComputerAppState {
        let state = try await computer.getAppState(includeScreenshot: includeScreenshot)
        latestSnapshot = state.snapshot
        emit(.observedTree(elementCount: state.snapshot.root.flattened.count))
        return state
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

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
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

    private func requireElementID(
        _ input: JSONValue,
        key: String = "element_index",
        tool: AgentTool
    ) throws -> String {
        if let id = try optionalElementID(input, primaryKey: key) {
            return id
        }
        throw AgentError.invalidToolInput(tool: tool.rawValue, detail: "missing \(key)")
    }

    private func optionalElementID(_ input: JSONValue, primaryKey: String) throws -> String? {
        if let explicitID = input["element_id"]?.stringValue {
            return explicitID
        }
        guard let raw = input[primaryKey] else { return nil }
        if let index = raw.intValue {
            return "e\(index)"
        }
        if let string = raw.stringValue {
            return string.hasPrefix("e") ? string : "e\(string)"
        }
        throw AgentError.invalidToolInput(
            tool: primaryKey,
            detail: "\(primaryKey) must be an integer or string"
        )
    }

    private func renderApps(_ apps: [ComputerAppInfo]) -> String {
        guard !apps.isEmpty else { return "No apps available." }
        return apps.map { app in
            var parts = [app.name]
            if let bundleIdentifier = app.bundleIdentifier {
                parts.append("bundle:\(bundleIdentifier)")
            }
            if let processIdentifier = app.processIdentifier {
                parts.append("pid:\(processIdentifier)")
            }
            if app.isTarget {
                parts.append("target")
            }
            return parts.joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    private func actionSummary(tool: AgentTool, input: JSONValue) -> String {
        switch tool {
        case .click:
            let id = (try? optionalElementID(input, primaryKey: "element_index")) ?? "?"
            if let label = latestSnapshot?.element(id: id)?.label, !label.isEmpty {
                return "Click \"\(label)\""
            }
            return "Click \(id)"
        case .setValue:
            return "Type \"\(input["value"]?.stringValue ?? "")\""
        case .typeText:
            return "Type text"
        case .scroll:
            return "Scroll \(input["direction"]?.stringValue ?? "")"
        case .pressKey:
            return "Press \(input["key"]?.stringValue ?? "key")"
        case .listApps:
            return "List apps"
        case .getAppState:
            return "Read the screen"
        case .drag:
            return "Drag"
        case .performSecondaryAction:
            return "Perform \(input["action"]?.stringValue ?? "secondary action")"
        case .askUser:
            return "Ask a question"
        case .done:
            return "Finish"
        }
    }
}
