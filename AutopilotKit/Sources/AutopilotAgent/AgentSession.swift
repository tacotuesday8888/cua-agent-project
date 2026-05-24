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
    /// Whether the active model/provider can receive screenshot image blocks.
    /// Text-only providers still get the accessibility tree, but screenshot
    /// requests are answered with an explicit omission note.
    public var supportsImageInput: Bool
    /// Optional guidance from a saved workflow ("recipe"), woven into the system
    /// prompt as hints. The agent still re-reads and verifies the live screen;
    /// the recipe is a prior, not a script. Empty/nil for ordinary runs.
    public var recipe: String?

    public init(
        model: String,
        maxSteps: Int = 25,
        maxTokens: Int = 4096,
        highlightDwell: Duration = .milliseconds(400),
        liveObservationWindow: Int = 3,
        supportsImageInput: Bool = true,
        recipe: String? = nil
    ) {
        self.model = model
        self.maxSteps = maxSteps
        self.maxTokens = maxTokens
        self.highlightDwell = highlightDwell
        self.liveObservationWindow = max(1, liveObservationWindow)
        self.supportsImageInput = supportsImageInput
        self.recipe = recipe
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

    /// The model conversation, which keeps its own context bounded.
    private var transcript = Transcript()
    private var latestSnapshot: UITreeSnapshot?
    /// Per-app write trust accrued during this run.
    private var trust: TrustStore
    /// Memory recalled at the start of the run, woven into the system prompt.
    private var recalledMemory: [MemoryItem] = []

    /// Cumulative provider token usage across the run's LLM calls.
    private var cumulativeUsage = LLMResponse.Usage(inputTokens: 0, outputTokens: 0)
    /// Signature of the most recent guarded action, for loop detection.
    private var lastActionSignature: String?
    /// How many times in a row the same action signature has been seen.
    private var consecutiveActionRepeats = 0
    /// Consecutive action failures where the app could not be re-read — a
    /// strong signal the target app has closed or stopped responding.
    private var consecutiveUnreadableFailures = 0

    /// Note appended after a guarded action repeats its predecessor once.
    private static let repeatedActionNote = """
    You just repeated an action identical to your previous one. Repeating it \
    again will stop the run. Try a different element or approach, or call done \
    if the task cannot be completed.
    """

    /// Steps remaining at or below which the model is warned to wrap up.
    private static let budgetWarningThreshold = 5

    /// Consecutive unreadable-app failures at which a run gives up.
    private static let unreadableFailureLimit = 2
    private static let defaultScrollAmount = 3
    private static let maxScrollAmount = 20

    /// Tools where repeating the identical call signals a stuck loop.
    /// Traversal tools such as scroll and press_key are intentionally excluded,
    /// since repeating those is a normal way to move through content.
    private static let loopGuardedTools: Set<AgentTool> = [
        .click, .setValue, .drag, .performSecondaryAction
    ]

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
            if Task.isCancelled { return stop() }
            return fail("Could not read \(computer.appName): \(error.localizedDescription)")
        }

        recalledMemory = await memory.relevant(appName: computer.appName, taskText: task)
        if !recalledMemory.isEmpty {
            emit(.memoryRecalled(recalledMemory))
        }

        transcript.begin(
            task: task,
            appName: computer.appName,
            initialTreeText: UITreeRenderer.compactText(initialTree),
            liveObservationWindow: configuration.liveObservationWindow
        )

        for stepIndex in 0..<configuration.maxSteps {
            if Task.isCancelled { return stop() }
            if consecutiveUnreadableFailures >= Self.unreadableFailureLimit {
                return fail("""
                Lost contact with \(computer.appName) after \
                \(consecutiveUnreadableFailures) failed attempts to read it — \
                it may have closed or stopped responding.
                """)
            }
            emit(.thinking)
            transcript.compact()

            let response: LLMResponse
            do {
                response = try await llm.send(buildRequest())
            } catch {
                // A cancelled provider call is the user's kill switch, not a
                // run failure — report it as a stop.
                if Task.isCancelled { return stop() }
                return fail("LLM error: \(error.localizedDescription)")
            }
            recordUsage(response.usage)
            transcript.appendAssistant(response.content)

            let assistantText = response.text
            if !assistantText.isEmpty { emit(.message(assistantText)) }

            let toolUses = response.toolUses
            if toolUses.isEmpty {
                // No tool calls ends the run — but cleanly only if the model
                // chose to stop. A reply cut off at the token limit has not
                // finished; reporting it as completed would be a false success.
                if response.stopReason == .maxTokens {
                    return fail("""
                    The model's reply was cut off at the response token limit \
                    before it finished the task or called done.
                    """)
                }
                let summary = assistantText.isEmpty ? "Finished." : assistantText
                emit(.finished(summary: summary))
                return AgentOutcome(status: .completed, summary: summary)
            }

            var results: [LLMContentBlock] = []
            if let use = toolUses.first {
                if Task.isCancelled { return stop() }
                if let outcome = await dispatch(use, into: &results) {
                    return outcome
                }
            }
            if toolUses.count > 1 {
                appendSkippedToolUseErrors(Array(toolUses.dropFirst()), into: &results)
            }
            appendBudgetNote(
                stepsRemaining: configuration.maxSteps - stepIndex - 1,
                to: &results
            )
            transcript.appendToolResults(results)
        }

        return fail(
            "Stopped after the \(configuration.maxSteps)-step limit without an explicit finish."
        )
    }

    /// Add `usage` to the run total and surface the running tally. The emitted
    /// input figure includes prompt-cache tokens, so a cached run is not
    /// under-counted once the system prompt and tools are served from cache.
    private func recordUsage(_ usage: LLMResponse.Usage) {
        cumulativeUsage = LLMResponse.Usage(
            inputTokens: cumulativeUsage.inputTokens + usage.inputTokens,
            outputTokens: cumulativeUsage.outputTokens + usage.outputTokens,
            cacheCreationInputTokens:
                cumulativeUsage.cacheCreationInputTokens + usage.cacheCreationInputTokens,
            cacheReadInputTokens:
                cumulativeUsage.cacheReadInputTokens + usage.cacheReadInputTokens
        )
        emit(.tokenUsage(
            inputTokens: cumulativeUsage.totalInputTokens,
            outputTokens: cumulativeUsage.outputTokens
        ))
    }

    /// When the step budget is running low, append a note to the last tool
    /// result so the model wraps up while it still has steps to do so.
    private func appendBudgetNote(stepsRemaining: Int, to results: inout [LLMContentBlock]) {
        guard stepsRemaining <= Self.budgetWarningThreshold else { return }
        let note = stepsRemaining <= 1
            ? """
            Step budget: only 1 step remains. Call done now with a summary of \
            what you accomplished — any further action will not run.
            """
            : """
            Step budget: \(stepsRemaining) steps remain before the run stops. \
            Finish the task or call done soon.
            """
        appendNote(note, to: &results)
    }

    /// Append `note` as an extra text block on the last tool result, so the
    /// model reads it alongside that result. Tool-use pairing is unaffected.
    private func appendNote(_ note: String, to results: inout [LLMContentBlock]) {
        guard let lastIndex = results.lastIndex(where: {
                  if case .toolResult = $0 { return true }
                  return false
              }),
              case .toolResult(let result) = results[lastIndex] else {
            return
        }
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
        var failures = 0
        for item in memories {
            switch await memory.addReporting(item) {
            case .stored:
                emit(.memoryStored(item))
                stored += 1
            case .duplicate, .cleared:
                break
            case .failed(let message):
                emit(.storageFailed(message))
                failures += 1
            }
        }
        let summary = if failures > 0 && stored == 0 {
            "Could not save memory."
        } else if stored == 0 {
            "Already in memory."
        } else {
            "Saved to memory."
        }
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
            let summary = Self.completionSummary(from: use.input["summary"]?.stringValue)
            emit(.finished(summary: summary))
            return AgentOutcome(status: .completed, summary: summary)

        case .askUser:
            let question = (use.input["question"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else {
                appendToolInputError(
                    AgentError.invalidToolInput(
                        tool: tool.rawValue,
                        detail: "question must be a non-empty string"
                    ),
                    toolUseID: use.id,
                    into: &results
                )
                return nil
            }
            let answer = await interaction.askQuestion(question)
            emit(.askedUser(question: question, answer: answer))
            results.append(.toolResult(ToolResult(toolUseID: use.id, text: answer)))
            return nil

        case .proposeMemory:
            await handleProposeMemory(use, into: &results)
            return nil

        case .proposeWorkflow:
            await handleProposeWorkflow(use, into: &results)
            return nil

        default:
            do {
                try validateInput(tool: tool, input: use.input)
                try preflightAction(tool: tool, input: use.input)
            } catch {
                appendToolInputError(error, toolUseID: use.id, into: &results)
                return nil
            }

            let repeats = registerAction(tool: tool, input: use.input)
            let guarded = Self.loopGuardedTools.contains(tool)
            if guarded, repeats >= 2 {
                return loopFailure(tool: tool)
            }
            await performAction(tool: tool, use: use, into: &results)
            if guarded, repeats == 1 {
                appendNote(Self.repeatedActionNote, to: &results)
            }
            return nil
        }
    }

    /// Enforce the control loop's one-tool-per-step contract. Extra tool calls
    /// in one model response are not executed, because the model has not yet
    /// seen the first tool's updated app state.
    private func appendSkippedToolUseErrors(
        _ toolUses: [ToolUse],
        into results: inout [LLMContentBlock]
    ) {
        for use in toolUses {
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: """
                Skipped \(use.name): call exactly one tool per step. Review the \
                first tool's result, then choose the next single tool call.
                """,
                isError: true
            )))
        }
    }

    /// Return a tool-result error for malformed model input before approval
    /// prompts or macOS actions run. A bad schema call is a model recovery
    /// problem, not something the user should be asked to approve.
    private func appendToolInputError(
        _ error: Error,
        toolUseID: String,
        into results: inout [LLMContentBlock]
    ) {
        results.append(.toolResult(ToolResult(
            toolUseID: toolUseID,
            text: """
            \(describe(error)) Fix the tool input and try again, or call done \
            if the task cannot continue.
            """,
            isError: true
        )))
    }

    /// Update the repeat tracker and return how many times in a row this exact
    /// tool call has now been seen (0 = first, 1 = repeated once, …).
    private func registerAction(tool: AgentTool, input: JSONValue) -> Int {
        let signature = actionSignature(tool: tool, input: input)
        if signature == lastActionSignature {
            consecutiveActionRepeats += 1
        } else {
            lastActionSignature = signature
            consecutiveActionRepeats = 0
        }
        return consecutiveActionRepeats
    }

    /// A stable string identifying a tool call, so identical calls compare
    /// equal regardless of key ordering in the model's JSON.
    private func actionSignature(tool: AgentTool, input: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(normalizedActionInput(tool: tool, input: input)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return "\(tool.rawValue) \(json)"
    }

    private func normalizedActionInput(tool: AgentTool, input: JSONValue) -> JSONValue {
        guard var object = input.objectValue else { return input }
        func normalize(primaryKey: String, canonicalKey: String = "element_id") {
            guard let id = try? ElementReference.optionalID(
                from: input,
                primaryKey: primaryKey,
                tool: tool
            ) else { return }
            object[canonicalKey] = .string(id)
            object.removeValue(forKey: primaryKey)
            if canonicalKey != "element_id" {
                object.removeValue(forKey: "element_id")
            }
        }

        switch tool {
        case .click, .setValue, .typeText, .scroll, .performSecondaryAction:
            normalize(primaryKey: "element_index")
        case .drag:
            normalize(primaryKey: "from_element_index", canonicalKey: "from_element_id")
            normalize(primaryKey: "to_element_index", canonicalKey: "to_element_id")
        case .listApps, .getAppState, .pressKey, .wait, .askUser, .proposeMemory,
             .proposeWorkflow, .done:
            break
        }
        return .object(object)
    }

    /// End the run because the model is stuck repeating one action.
    private func loopFailure(tool: AgentTool) -> AgentOutcome {
        fail("""
        Stopped: the same \(tool.rawValue) action was repeated three times in \
        a row without making progress.
        """)
    }

    /// Handle a `propose_memory` call: surface the proposal, and store it if
    /// the user approves.
    private func handleProposeMemory(
        _ use: ToolUse,
        into results: inout [LLMContentBlock]
    ) async {
        let proposal: MemoryProposal
        do {
            proposal = try memoryProposal(from: use.input)
        } catch {
            appendToolInputError(error, toolUseID: use.id, into: &results)
            return
        }

        emit(.memoryProposed(proposal))

        if await interaction.confirmMemory(proposal) {
            let item = MemoryItem(text: proposal.text, scope: proposal.scope, source: .proposed)
            switch await memory.addReporting(item) {
            case .stored:
                emit(.memoryStored(item))
                results.append(.toolResult(ToolResult(
                    toolUseID: use.id,
                    text: "Saved to memory."
                )))
            case .duplicate, .cleared:
                results.append(.toolResult(ToolResult(
                    toolUseID: use.id,
                    text: "Already in memory."
                )))
            case .failed(let message):
                emit(.storageFailed(message))
                results.append(.toolResult(ToolResult(
                    toolUseID: use.id,
                    text: "\(message) Continue without saved memory.",
                    isError: true
                )))
            }
        } else {
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: "The user chose not to save that. Continue with the task."
            )))
        }
    }

    /// Validate and resolve the input of a `propose_memory` call.
    private func memoryProposal(from input: JSONValue) throws -> MemoryProposal {
        let text = (input["text"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AgentError.invalidToolInput(
                tool: AgentTool.proposeMemory.rawValue,
                detail: "text must be a non-empty string"
            )
        }

        let rawScope = (input["scope"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scope: MemoryScope
        switch rawScope {
        case "global":
            scope = .global
        case "app":
            let app = (input["scope_value"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            scope = .app(app.isEmpty ? computer.appName : app)
        case "contact":
            let contact = (input["scope_value"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contact.isEmpty else {
                throw AgentError.invalidToolInput(
                    tool: AgentTool.proposeMemory.rawValue,
                    detail: "scope_value is required when scope is contact"
                )
            }
            scope = .contact(contact)
        default:
            throw AgentError.invalidToolInput(
                tool: AgentTool.proposeMemory.rawValue,
                detail: "scope must be global, app, or contact"
            )
        }

        return MemoryProposal(text: text, scope: scope)
    }

    /// Handle a `propose_workflow` call: surface the proposal and let the user
    /// approve saving it for reuse. Persistence lives in the UI's
    /// `confirmWorkflow`, so the engine stays decoupled from the workflow store.
    private func handleProposeWorkflow(
        _ use: ToolUse,
        into results: inout [LLMContentBlock]
    ) async {
        let proposal: WorkflowProposal
        do {
            proposal = try workflowProposal(from: use.input)
        } catch {
            appendToolInputError(error, toolUseID: use.id, into: &results)
            return
        }

        emit(.workflowProposed(proposal))

        if await interaction.confirmWorkflow(proposal) {
            emit(.workflowSaved(proposal.name))
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: "Saved \"\(proposal.name)\" as a reusable workflow."
            )))
        } else {
            results.append(.toolResult(ToolResult(
                toolUseID: use.id,
                text: "The user chose not to save that workflow. Continue with the task."
            )))
        }
    }

    /// Validate and resolve the input of a `propose_workflow` call.
    private func workflowProposal(from input: JSONValue) throws -> WorkflowProposal {
        let name = (input["name"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AgentError.invalidToolInput(
                tool: AgentTool.proposeWorkflow.rawValue,
                detail: "name must be a non-empty string"
            )
        }

        let goalTemplate = (input["goal_template"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goalTemplate.isEmpty else {
            throw AgentError.invalidToolInput(
                tool: AgentTool.proposeWorkflow.rawValue,
                detail: "goal_template must be a non-empty string"
            )
        }

        let recipe = (input["recipe"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkflowProposal(name: name, goalTemplate: goalTemplate, recipe: recipe)
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
            // result is an observation the transcript can later prune.
            if tool != .listApps {
                transcript.recordObservation(toolUseID: use.id)
            }
            results.append(.toolResult(ToolResult(toolUseID: use.id, content: content)))
        } catch {
            let reason = describe(error)
            emit(.actionFailed(tool: tool, reason: reason))
            let failure = await failureText(reason: reason, target: target)
            if failure.embeddedTree {
                transcript.recordObservation(toolUseID: use.id)
            } else {
                // The app could not be re-read after the failure — track it,
                // so a closed or hung app ends the run instead of flailing.
                consecutiveUnreadableFailures += 1
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
    private func failureText(
        reason: String,
        target: ActionTarget
    ) async -> (text: String, embeddedTree: Bool) {
        let prefix = """
        Action failed: \(reason)

        Failed target: \(targetRecoverySummary(target)). Element ids are \
        snapshot-local; do not retry an old element_index blindly.
        """
        guard !Task.isCancelled, let tree = try? await observeTree() else {
            return (prefix, false)
        }
        return ("""
        \(prefix)

        The app state has been re-read — call get_app_state if you need another \
        refresh, then choose a current element_index that matches the target's \
        role, label, identifier, or frame. Current state of \(computer.appName):
        \(UITreeRenderer.compactText(tree))
        """, true)
    }

    private func targetRecoverySummary(_ target: ActionTarget) -> String {
        var parts = [target.description]
        if let elementID = target.elementID { parts.append("old id \(elementID)") }
        if let role = target.role, !role.isEmpty { parts.append("role \(role)") }
        if let label = target.label, !label.isEmpty { parts.append("label \"\(label)\"") }
        if let identifier = target.identifier, !identifier.isEmpty {
            parts.append("identifier \(identifier)")
        }
        if let value = target.value, !value.isEmpty { parts.append("value \"\(value)\"") }
        if let turn = target.turnIdentifier { parts.append("snapshot turn \(turn)") }
        return parts.joined(separator: ", ")
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
        let elementID = try? optionalElementID(input, primaryKey: primaryKey, tool: tool)
        if let elementID, let element = latestSnapshot?.element(id: elementID) {
            return ActionTarget(
                appName: computer.appName,
                elementID: elementID,
                role: element.role,
                label: element.label,
                identifier: element.identifier,
                value: element.value,
                turnIdentifier: latestSnapshot?.turnIdentifier,
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
            let requestedScreenshot = input["include_screenshot"]?.boolValue ?? false
            let includeScreenshot = requestedScreenshot && configuration.supportsImageInput
            let state = try await observeState(includeScreenshot: includeScreenshot)
            var content: [ToolResult.Content] = [
                .text(UITreeRenderer.compactText(state.snapshot))
            ]
            if requestedScreenshot && !configuration.supportsImageInput {
                content.append(.text("""
                Screenshot omitted: the selected provider cannot inspect image \
                input. Use the accessibility tree above, or ask the user for \
                clarification if the visual state is ambiguous.
                """))
            }
            if let warning = state.screenshotWarning {
                content.append(.text("""
                \(warning) The accessibility tree above is still current. Use \
                it to continue, or ask the user if visual details are required.
                """))
            }
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
            let id = try optionalElementID(input, primaryKey: "element_index", tool: tool)
            let text = try requireString(input, "text", tool: tool)
            try await computer.typeText(text, into: id)
            return try await observedResult("Typed text.")

        case .scroll:
            let direction = try requireScrollDirection(input, tool: tool)
            let amount = try scrollAmount(input, tool: tool)
            try await computer.scroll(
                elementID: try optionalElementID(input, primaryKey: "element_index", tool: tool),
                direction: direction,
                amount: amount
            )
            return try await observedResult("Scrolled \(direction.rawValue).")

        case .pressKey:
            let key = try requireString(input, "key", tool: tool)
            let modifiers = try keyModifiers(input, tool: tool)
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

        case .wait:
            let seconds = Self.waitSeconds(input)
            if seconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            return try await observedResult("Waited \(seconds)s for the UI to settle.")

        case .askUser, .proposeMemory, .proposeWorkflow, .done:
            return []  // handled in `dispatch`
        }
    }

    /// The wait duration, clamped to a small, safe range so the model cannot
    /// stall a run. Missing or non-numeric input defaults to one second.
    private static func waitSeconds(_ input: JSONValue) -> Double {
        let requested = input["seconds"]?.doubleValue ?? 1
        return min(max(requested, 0), 5)
    }

    // MARK: - Helpers

    private func observeTree() async throws -> UITreeSnapshot {
        (try await observeState(includeScreenshot: false)).snapshot
    }

    private func observeState(includeScreenshot: Bool) async throws -> ComputerAppState {
        let state = try await computer.getAppState(includeScreenshot: includeScreenshot)
        latestSnapshot = state.snapshot
        // A successful read means the app is reachable again.
        consecutiveUnreadableFailures = 0
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
            system: SystemPrompt.build(
                appName: computer.appName,
                memories: recalledMemory,
                recipe: configuration.recipe
            ),
            messages: transcript.messages,
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

    private static func completionSummary(from rawSummary: String?) -> String {
        let summary = (rawSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "Task complete." : summary
    }

    /// Validate tool input before approvals/highlights. This keeps malformed
    /// model calls from surfacing as confusing user approval prompts.
    private func validateInput(tool: AgentTool, input: JSONValue) throws {
        switch tool {
        case .listApps:
            return
        case .getAppState:
            if let raw = input["include_screenshot"], raw.boolValue == nil {
                throw AgentError.invalidToolInput(
                    tool: tool.rawValue,
                    detail: "include_screenshot must be true or false"
                )
            }
        case .click:
            _ = try requireElementID(input, tool: tool)
        case .setValue:
            _ = try requireElementID(input, tool: tool)
            _ = try requireString(input, "value", tool: tool)
        case .typeText:
            _ = try optionalElementID(input, primaryKey: "element_index", tool: tool)
            _ = try requireString(input, "text", tool: tool)
        case .scroll:
            _ = try optionalElementID(input, primaryKey: "element_index", tool: tool)
            _ = try requireScrollDirection(input, tool: tool)
            _ = try scrollAmount(input, tool: tool)
        case .pressKey:
            _ = try requireString(input, "key", tool: tool)
            _ = try keyModifiers(input, tool: tool)
        case .drag:
            _ = try requireElementID(input, key: "from_element_index", tool: tool)
            _ = try requireElementID(input, key: "to_element_index", tool: tool)
        case .performSecondaryAction:
            _ = try requireElementID(input, tool: tool)
            _ = try requireString(input, "action", tool: tool)
        case .wait, .askUser, .proposeMemory, .proposeWorkflow, .done:
            return
        }
    }

    /// Validate references against the latest app state before approvals or
    /// highlights. This keeps stale but well-formed element ids from producing
    /// approval prompts for actions that cannot possibly run.
    private func preflightAction(tool: AgentTool, input: JSONValue) throws {
        switch tool {
        case .click:
            _ = try requireEnabledElement(input, key: "element_index", tool: tool)
        case .setValue:
            let element = try requireEnabledElement(input, key: "element_index", tool: tool)
            guard element.isValueSettable else {
                throw AgentError.invalidToolInput(
                    tool: tool.rawValue,
                    detail: """
                    \(element.id) is not marked settable. Use type_text with \
                    this element_index, or choose an editable element marked settable
                    """
                )
            }
        case .typeText:
            if let element = try optionalExistingElement(input, key: "element_index", tool: tool) {
                try ensureEnabled(element, tool: tool)
            }
        case .scroll:
            _ = try optionalExistingElement(input, key: "element_index", tool: tool)
        case .drag:
            _ = try requireEnabledElement(input, key: "from_element_index", tool: tool)
            _ = try requireEnabledElement(input, key: "to_element_index", tool: tool)
        case .performSecondaryAction:
            let element = try requireEnabledElement(input, key: "element_index", tool: tool)
            let action = try requireString(input, "action", tool: tool)
            guard element.actions.contains(action) else {
                throw ComputerControlError.unavailableAction(
                    elementID: element.id,
                    action: action
                )
            }
        case .listApps, .getAppState, .pressKey, .wait, .askUser, .proposeMemory,
             .proposeWorkflow, .done:
            return
        }
    }

    private func requireExistingElement(
        _ input: JSONValue,
        key: String,
        tool: AgentTool
    ) throws -> UIElement {
        let id = try requireElementID(input, key: key, tool: tool)
        guard let snapshot = latestSnapshot else {
            throw ComputerControlError.noCachedState(appName: computer.appName)
        }
        guard let element = snapshot.element(id: id) else {
            throw ComputerControlError.invalidElement(
                elementID: id,
                appName: computer.appName,
                turnIdentifier: snapshot.turnIdentifier
            )
        }
        return element
    }

    private func requireEnabledElement(
        _ input: JSONValue,
        key: String,
        tool: AgentTool
    ) throws -> UIElement {
        let element = try requireExistingElement(input, key: key, tool: tool)
        try ensureEnabled(element, tool: tool)
        return element
    }

    private func ensureEnabled(_ element: UIElement, tool: AgentTool) throws {
        guard element.isEnabled else {
            throw AgentError.invalidToolInput(
                tool: tool.rawValue,
                detail: """
                \(element.id) is disabled. Choose an enabled element from the \
                current app state, or call done if the required control is unavailable
                """
            )
        }
    }

    private func optionalExistingElement(
        _ input: JSONValue,
        key: String,
        tool: AgentTool
    ) throws -> UIElement? {
        guard let id = try optionalElementID(input, primaryKey: key, tool: tool) else {
            return nil
        }
        guard let snapshot = latestSnapshot else {
            throw ComputerControlError.noCachedState(appName: computer.appName)
        }
        guard let element = snapshot.element(id: id) else {
            throw ComputerControlError.invalidElement(
                elementID: id,
                appName: computer.appName,
                turnIdentifier: snapshot.turnIdentifier
            )
        }
        return element
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

    private func requireScrollDirection(
        _ input: JSONValue,
        tool: AgentTool
    ) throws -> ScrollDirection {
        let raw = try requireString(input, "direction", tool: tool)
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let direction = ScrollDirection(rawValue: normalized) else {
            throw AgentError.invalidToolInput(
                tool: tool.rawValue,
                detail: "direction must be one of up, down, left, or right"
            )
        }
        return direction
    }

    private func scrollAmount(_ input: JSONValue, tool: AgentTool) throws -> Int {
        guard let raw = input["amount"] else { return Self.defaultScrollAmount }
        guard let amount = integerValue(raw) else {
            throw AgentError.invalidToolInput(
                tool: tool.rawValue,
                detail: "amount must be an integer from 1 to \(Self.maxScrollAmount)"
            )
        }
        guard (1...Self.maxScrollAmount).contains(amount) else {
            throw AgentError.invalidToolInput(
                tool: tool.rawValue,
                detail: "amount must be between 1 and \(Self.maxScrollAmount)"
            )
        }
        return amount
    }

    private func integerValue(_ raw: JSONValue) -> Int? {
        switch raw {
        case .int(let value):
            return value
        case .double(let value):
            return Int(exactly: value)
        default:
            return nil
        }
    }

    private func keyModifiers(
        _ input: JSONValue,
        tool: AgentTool
    ) throws -> [KeyPress.Modifier] {
        guard let raw = input["modifiers"] else { return [] }
        guard let values = raw.arrayValue else {
            throw AgentError.invalidToolInput(
                tool: tool.rawValue,
                detail: "modifiers must be an array"
            )
        }

        var modifiers: [KeyPress.Modifier] = []
        for value in values {
            guard let rawName = value.stringValue else {
                throw AgentError.invalidToolInput(
                    tool: tool.rawValue,
                    detail: "modifiers must contain only strings"
                )
            }
            let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let modifier = KeyPress.Modifier(rawValue: normalized) else {
                throw AgentError.invalidToolInput(
                    tool: tool.rawValue,
                    detail: """
                    unsupported modifier \(rawName). Use command, shift, option, \
                    control, or function
                    """
                )
            }
            if !modifiers.contains(modifier) {
                modifiers.append(modifier)
            }
        }
        return modifiers
    }

    private func requireElementID(
        _ input: JSONValue,
        key: String = "element_index",
        tool: AgentTool
    ) throws -> String {
        if let id = try optionalElementID(input, primaryKey: key, tool: tool) {
            return id
        }
        throw AgentError.invalidToolInput(tool: tool.rawValue, detail: "missing \(key)")
    }

    private func optionalElementID(
        _ input: JSONValue,
        primaryKey: String,
        tool: AgentTool
    ) throws -> String? {
        try ElementReference.optionalID(from: input, primaryKey: primaryKey, tool: tool)
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
            let id = (try? optionalElementID(input, primaryKey: "element_index", tool: tool)) ?? "?"
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
        case .wait:
            return "Wait"
        case .askUser:
            return "Ask a question"
        case .proposeMemory:
            return "Propose a memory"
        case .proposeWorkflow:
            return "Propose a workflow"
        case .done:
            return "Finish"
        }
    }
}
