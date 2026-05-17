import AutopilotCore
import AutopilotLLM
import AutopilotMemory
import Foundation

/// Configuration for an agent run.
public struct AgentConfiguration: Sendable {
    /// The model identifier passed to the LLM provider.
    public var model: String
    /// Maximum perceive → decide → act steps before giving up.
    public var maxSteps: Int
    /// Maximum tokens generated per LLM call.
    public var maxTokens: Int
    /// How long the agent surfaces an action's target before an un-gated action
    /// runs, so the UI can highlight it. Tests use `.zero`.
    public var highlightDwell: Duration
    /// How many recent UI-tree observations stay verbatim in the transcript.
    /// Older ones are replaced with a short placeholder so a long run's context
    /// does not grow with every screen it has ever read.
    public var liveObservationWindow: Int

    public init(
        model: String,
        maxSteps: Int = 25,
        maxTokens: Int = 4096,
        highlightDwell: Duration = .milliseconds(400),
        liveObservationWindow: Int = 3
    ) {
        self.model = model
        self.maxSteps = maxSteps
        self.maxTokens = maxTokens
        self.highlightDwell = highlightDwell
        self.liveObservationWindow = max(1, liveObservationWindow)
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
    private let memory: MemoryStore
    private let emit: @Sendable (AgentEvent) -> Void
    private let classifier = RiskClassifier()
    private let promptParser = PromptParser()

    private var messages: [LLMMessage] = []
    private var latestSnapshot: UITreeSnapshot?
    /// Per-app write trust accrued during this run.
    private var trust: TrustStore
    /// Memory recalled at the start of the run, woven into the system prompt.
    private var recalledMemory: [MemoryItem] = []
    /// The task being run, kept so a pruned initial message can be rebuilt.
    private var task = ""
    /// Tool-use ids whose results embed a full UI-tree render, so the
    /// transcript compactor can find and prune the stale ones.
    private var observationToolUseIDs: Set<String> = []

    /// Cumulative provider token usage across the run's LLM calls.
    private var cumulativeUsage = LLMResponse.Usage(inputTokens: 0, outputTokens: 0)

    /// Placeholder left where a stale UI-tree observation was pruned.
    private static let prunedObservationNote = """
    [Earlier app state omitted to keep context small. Call get_app_state to \
    re-read the current screen.]
    """

    /// Steps remaining at or below which the model is warned to wrap up.
    private static let budgetWarningThreshold = 5

    public init(
        llm: any LLMProvider,
        computer: any ComputerControl,
        interaction: any UserInteraction,
        configuration: AgentConfiguration,
        memory: MemoryStore,
        permanentlyTrustedApps: Set<String> = [],
        eventHandler: @escaping @Sendable (AgentEvent) -> Void = { _ in }
    ) {
        self.llm = llm
        self.computer = computer
        self.interaction = interaction
        self.configuration = configuration
        self.memory = memory
        self.trust = TrustStore(permanentlyTrusted: permanentlyTrustedApps)
        self.emit = eventHandler
    }

    /// Run `task` to completion and return the outcome.
    public func run(task: String) async -> AgentOutcome {
        self.task = task
        emit(.started(task: task))

        // A "remember:" prompt is a storage instruction, not an app task.
        let explicitMemories = promptParser.explicitMemories(in: task)
        if !explicitMemories.isEmpty {
            return await storeExplicitMemories(explicitMemories)
        }

        let preparation = await computer.prepare()
        if !preparation.isEmpty {
            emit(.prepared(summary: preparation))
        }

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

        recalledMemory = await memory.relevant(appName: computer.appName)
        if !recalledMemory.isEmpty {
            emit(.memoryRecalled(recalledMemory))
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

        for stepIndex in 0..<configuration.maxSteps {
            if Task.isCancelled { return stop() }
            emit(.thinking)
            compactTranscript()

            let response: LLMResponse
            do {
                response = try await llm.send(buildRequest())
            } catch {
                return fail("LLM error: \(error.localizedDescription)")
            }
            recordUsage(response.usage)
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
            appendBudgetNote(
                stepsRemaining: configuration.maxSteps - stepIndex - 1,
                to: &results
            )
            messages.append(LLMMessage(role: .user, content: results))
        }

        return fail(
            "Stopped after the \(configuration.maxSteps)-step limit without an explicit finish."
        )
    }

    /// Add `usage` to the run total and surface the running tally.
    private func recordUsage(_ usage: LLMResponse.Usage) {
        cumulativeUsage = LLMResponse.Usage(
            inputTokens: cumulativeUsage.inputTokens + usage.inputTokens,
            outputTokens: cumulativeUsage.outputTokens + usage.outputTokens
        )
        emit(.tokenUsage(
            inputTokens: cumulativeUsage.inputTokens,
            outputTokens: cumulativeUsage.outputTokens
        ))
    }

    /// When the step budget is running low, append a note to the last tool
    /// result so the model wraps up while it still has steps to do so.
    private func appendBudgetNote(stepsRemaining: Int, to results: inout [LLMContentBlock]) {
        guard stepsRemaining <= Self.budgetWarningThreshold,
              let lastIndex = results.lastIndex(where: {
                  if case .toolResult = $0 { return true }
                  return false
              }),
              case .toolResult(let result) = results[lastIndex] else {
            return
        }
        let note = stepsRemaining <= 1
            ? """
            Step budget: only 1 step remains. Call done now with a summary of \
            what you accomplished — any further action will not run.
            """
            : """
            Step budget: \(stepsRemaining) steps remain before the run stops. \
            Finish the task or call done soon.
            """
        results[lastIndex] = .toolResult(ToolResult(
            toolUseID: result.toolUseID,
            content: result.content + [.text(note)],
            isError: result.isError
        ))
    }

    // MARK: - Memory

    /// Store the memories from a "remember:" prompt, then finish — there is no
    /// app task to run.
    private func storeExplicitMemories(_ memories: [MemoryItem]) async -> AgentOutcome {
        var stored = 0
        for item in memories where await memory.add(item) {
            emit(.memoryStored(item))
            stored += 1
        }
        let summary = stored == 0 ? "Already in memory." : "Saved to memory."
        emit(.finished(summary: summary))
        return AgentOutcome(status: .completed, summary: summary)
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

        case .proposeMemory:
            await handleProposeMemory(use, into: &results)
            return nil

        default:
            await performAction(tool: tool, use: use, into: &results)
            return nil
        }
    }

    /// Handle a `propose_memory` call: surface the proposal, and store it if
    /// the user approves.
    private func handleProposeMemory(
        _ use: ToolUse,
        into results: inout [LLMContentBlock]
    ) async {
        let text = (use.input["text"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: "propose_memory needs non-empty text.",
                isError: true
            )))
            return
        }

        let proposal = MemoryProposal(text: text, scope: memoryScope(from: use.input))
        emit(.memoryProposed(proposal))

        if await interaction.confirmMemory(proposal) {
            let item = MemoryItem(text: text, scope: proposal.scope, source: .proposed)
            await memory.add(item)
            emit(.memoryStored(item))
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: "Saved to memory."
            )))
        } else {
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: "The user chose not to save that. Continue with the task."
            )))
        }
    }

    /// Resolve the `scope` / `scope_value` inputs of a `propose_memory` call.
    private func memoryScope(from input: JSONValue) -> MemoryScope {
        switch input["scope"]?.stringValue {
        case "app":
            return .app(input["scope_value"]?.stringValue ?? computer.appName)
        case "contact":
            let contact = (input["scope_value"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return contact.isEmpty ? .global : .contact(contact)
        default:
            return .global
        }
    }

    private func performAction(
        tool: AgentTool,
        use: ToolUse,
        into results: inout [LLMContentBlock]
    ) async {
        let target = makeActionTarget(tool: tool, input: use.input)
        let tier = classifier.assess(tool: tool, input: use.input, snapshot: latestSnapshot)
        emit(.willPerform(tool: tool, target: target, tier: tier))

        guard await gate(tier: tier, target: target) else {
            emit(.confirmationDenied(summary: target.description))
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: "The user declined this action. Do not retry it; choose an alternative or finish."
            )))
            return
        }

        // The highlight dwell is cancellable; if the user hit Stop, do not act.
        guard !Task.isCancelled else {
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: "Stopped by the user before this action ran."
            )))
            return
        }

        do {
            let content = try await execute(tool: tool, input: use.input)
            emit(.performed(tool: tool, summary: target.description))
            // Every tool but `list_apps` returns the freshly-read tree, so its
            // result is an observation the transcript compactor can prune.
            if tool != .listApps {
                observationToolUseIDs.insert(use.id)
            }
            results.append(.toolResult(ToolResult(toolUseID: use.id, content: content)))
        } catch {
            let reason = describe(error)
            emit(.actionFailed(tool: tool, reason: reason))
            let failure = await failureText(reason: reason)
            if failure.embeddedTree {
                observationToolUseIDs.insert(use.id)
            }
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: failure.text,
                isError: true
            )))
        }
    }

    /// Build the tool-result text for a failed action.
    ///
    /// When the app is still readable, the current state is re-read and
    /// appended so the model can recover on its next step instead of acting on
    /// stale element ids from before the failure. `embeddedTree` reports
    /// whether a re-read tree was appended, so the caller can mark the result
    /// as a prunable observation.
    private func failureText(reason: String) async -> (text: String, embeddedTree: Bool) {
        let prefix = "Action failed: \(reason)"
        guard !Task.isCancelled, let tree = try? await observeTree() else {
            return (prefix, false)
        }
        return ("""
        \(prefix)

        The app state has been re-read — use the element indexes below, not \
        earlier ones. Current state of \(computer.appName):
        \(UITreeRenderer.compactText(tree))
        """, true)
    }

    /// Apply the approval gate. Returns whether the action may run.
    ///
    /// - `safe`: runs after a brief highlight dwell.
    /// - `write`: runs freely once the app is trusted; otherwise the user is
    ///   asked, and the app becomes trusted for the session on approval.
    /// - `destructive`: always asks; trust is never consulted or granted.
    private func gate(tier: RiskLevel, target: ActionTarget) async -> Bool {
        switch tier {
        case .safe:
            await dwell()
            return true

        case .write:
            if trust.isTrusted(app: computer.appName) {
                await dwell()
                return true
            }
            let approved = await requestApproval(tier: tier, target: target)
            if approved {
                trust.recordSessionTrust(app: computer.appName)
            }
            return approved

        case .destructive:
            return await requestApproval(tier: tier, target: target)
        }
    }

    private func requestApproval(tier: RiskLevel, target: ActionTarget) async -> Bool {
        let request = ApprovalRequest(
            appName: computer.appName,
            tier: tier,
            target: target,
            summary: target.description
        )
        emit(.awaitingConfirmation(request))
        return await interaction.requestApproval(request)
    }

    /// Hold briefly so the UI can highlight the target before an un-gated
    /// action fires. Cancellation ends the wait immediately.
    private func dwell() async {
        guard configuration.highlightDwell > .zero else { return }
        try? await Task.sleep(for: configuration.highlightDwell)
    }

    /// Describe what an action will interact with, for the highlight overlay
    /// and the approval prompt.
    private func makeActionTarget(tool: AgentTool, input: JSONValue) -> ActionTarget {
        let description = actionSummary(tool: tool, input: input)
        let primaryKey = tool == .drag ? "from_element_index" : "element_index"
        let elementID = try? optionalElementID(input, primaryKey: primaryKey)
        if let elementID, let element = latestSnapshot?.element(id: elementID) {
            return ActionTarget(
                appName: computer.appName,
                elementID: elementID,
                role: element.role,
                label: element.label,
                description: description,
                frame: element.frame
            )
        }
        return ActionTarget(appName: computer.appName, description: description)
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
            let id = try optionalElementID(input, primaryKey: "element_index")
            let text = try requireString(input, "text", tool: tool)
            try await computer.typeText(text, into: id)
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

        case .askUser, .proposeMemory, .done:
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

    /// Replace all but the most recent few UI-tree observations with a short
    /// placeholder, so a long run's context stays bounded instead of carrying
    /// every screen it has ever read. Tool-use/tool-result pairing is kept
    /// intact — only the stale result *content* is shrunk.
    private func compactTranscript() {
        let window = configuration.liveObservationWindow

        // Observation carriers, oldest first: the initial task message (which
        // embeds the first tree), then every tool result that embedded a tree.
        var carriers: [(message: Int, block: Int?)] = [(0, nil)]
        for (messageIndex, message) in messages.enumerated() {
            for (blockIndex, block) in message.content.enumerated() {
                guard case .toolResult(let result) = block,
                      observationToolUseIDs.contains(result.toolUseID) else {
                    continue
                }
                carriers.append((messageIndex, blockIndex))
            }
        }
        guard carriers.count > window else { return }

        for carrier in carriers.dropLast(window) {
            guard let blockIndex = carrier.block else {
                messages[0] = LLMMessage(role: .user, content: [
                    .text("Task: \(task)\n\n\(Self.prunedObservationNote)")
                ])
                continue
            }
            messages[carrier.message] = stubbingObservation(
                at: blockIndex,
                in: messages[carrier.message]
            )
        }
    }

    /// Return a copy of `message` with the tool-result block at `index` shrunk
    /// to the prune placeholder, preserving its tool-use id and error flag.
    private func stubbingObservation(at index: Int, in message: LLMMessage) -> LLMMessage {
        var content = message.content
        guard case .toolResult(let result) = content[index] else { return message }
        content[index] = .toolResult(ToolResult(
            toolUseID: result.toolUseID,
            content: [.text(Self.prunedObservationNote)],
            isError: result.isError
        ))
        return LLMMessage(role: message.role, content: content)
    }

    private func buildRequest() -> LLMRequest {
        LLMRequest(
            model: configuration.model,
            system: SystemPrompt.build(appName: computer.appName, memories: recalledMemory),
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
        case .proposeMemory:
            return "Propose a memory"
        case .done:
            return "Finish"
        }
    }
}
