import AutopilotCore
import AutopilotLLM
import AutopilotMemory
import Foundation
import Testing
@testable import AutopilotAgent

struct RiskClassifierTests {
    private func buttonSnapshot(label: String? = nil, value: String? = nil, identifier: String? = nil) -> UITreeSnapshot {
        let button = UIElement(
            id: "e2",
            role: "AXButton",
            identifier: identifier,
            label: label,
            value: value
        )
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

    @Test func destructiveRiskNormalizesElementReferences() {
        let classifier = RiskClassifier()
        let snapshot = buttonSnapshot(label: "Delete Playlist")
        #expect(classifier.assess(
            tool: .click,
            input: ["element_index": " 2 "],
            snapshot: snapshot
        ) == .destructive)
        #expect(classifier.assess(
            tool: .click,
            input: ["element_id": "2"],
            snapshot: snapshot
        ) == .destructive)
        #expect(classifier.assess(
            tool: .click,
            input: ["element_id": " e2 "],
            snapshot: snapshot
        ) == .destructive)
    }

    @Test(arguments: [
        "Send",
        "Post",
        "Publish",
        "Share",
        "Confirm",
        "Overwrite",
        "Sign out",
        "Cancel subscription"
    ])
    func consequentialButtonLabelsAreDestructive(label: String) {
        let risk = RiskClassifier().assess(
            tool: .click,
            input: ["element_index": 2],
            snapshot: buttonSnapshot(label: label)
        )
        #expect(risk == .destructive)
    }

    @Test(arguments: [
        "sendButton",
        "postButton",
        "publishButton",
        "shareAction",
        "confirmOrderButton",
        "signOutButton",
        "cancelSubscriptionButton"
    ])
    func consequentialIdentifiersAreDestructive(identifier: String) {
        let risk = RiskClassifier().assess(
            tool: .click,
            input: ["element_index": 2],
            snapshot: buttonSnapshot(identifier: identifier)
        )
        #expect(risk == .destructive)
    }

    @Test func consequentialValueIsDestructive() {
        let risk = RiskClassifier().assess(
            tool: .performSecondaryAction,
            input: ["element_index": 2, "action": "AXPress"],
            snapshot: buttonSnapshot(value: "Place order")
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

    @Test func commandCloseAndQuitKeyPressesAreDestructive() {
        // ⌘W closes a window or tab, losing unsaved work; ⌘Q quits the app.
        let classifier = RiskClassifier()
        #expect(classifier.assess(
            tool: .pressKey,
            input: ["key": "w", "modifiers": ["command"]],
            snapshot: nil
        ) == .destructive)
        #expect(classifier.assess(
            tool: .pressKey,
            input: ["key": "q", "modifiers": ["command"]],
            snapshot: nil
        ) == .destructive)
    }

    @Test func closeKeyWithoutCommandIsWrite() {
        // Without Command, "w" is just an ordinary typed character.
        let risk = RiskClassifier().assess(
            tool: .pressKey,
            input: ["key": "w"],
            snapshot: nil
        )
        #expect(risk == .write)
    }

    @Test func plainKeyPressIsWrite() {
        let risk = RiskClassifier().assess(
            tool: .pressKey,
            input: ["key": "return"],
            snapshot: nil
        )
        #expect(risk == .write)
    }

    private func iconButtonSnapshot(identifier: String) -> UITreeSnapshot {
        let button = UIElement(id: "e2", role: "AXButton", identifier: identifier)
        let root = UIElement(id: "e1", role: "AXWindow", children: [button])
        return UITreeSnapshot(appName: "App", root: root)
    }

    @Test func destructiveIdentifierIsDestructive() {
        // An icon-only button with no label, recognized by its AX identifier.
        let risk = RiskClassifier().assess(
            tool: .click,
            input: ["element_index": 2],
            snapshot: iconButtonSnapshot(identifier: "deleteAccountButton")
        )
        #expect(risk == .destructive)
    }

    @Test func neutralIdentifierStaysWrite() {
        let risk = RiskClassifier().assess(
            tool: .click,
            input: ["element_index": 2],
            snapshot: iconButtonSnapshot(identifier: "playButton")
        )
        #expect(risk == .write)
    }

    @Test func secondaryActionOnDestructiveIdentifierIsDestructive() {
        let risk = RiskClassifier().assess(
            tool: .performSecondaryAction,
            input: ["element_index": 2, "action": "AXPress"],
            snapshot: iconButtonSnapshot(identifier: "sendMessageButton")
        )
        #expect(risk == .destructive)
    }

    @Test(arguments: [
        "delete",
        "AXDelete",
        "Move to Trash",
        "removeRow",
        "Discard Changes"
    ])
    func destructiveSecondaryActionNamesAreDestructive(action: String) {
        // The action name carries the consequence even when the element it acts
        // on has a perfectly ordinary label — a context-menu "Delete" on a row.
        let risk = RiskClassifier().assess(
            tool: .performSecondaryAction,
            input: ["element_index": 2, "action": .string(action)],
            snapshot: buttonSnapshot(label: "Track 3")
        )
        #expect(risk == .destructive)
    }

    @Test func benignSecondaryActionNameStaysWrite() {
        let risk = RiskClassifier().assess(
            tool: .performSecondaryAction,
            input: ["element_index": 2, "action": "AXShowMenu"],
            snapshot: buttonSnapshot(label: "Track 3")
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
        let field = UIElement(
            id: "e2",
            role: "AXTextField",
            label: "Search",
            value: "",
            isValueSettable: true
        )
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

    private func toolResponse(
        id: String,
        tool: String,
        input: JSONValue,
        usage: LLMResponse.Usage
    ) -> LLMResponse {
        LLMResponse(
            content: [.toolUse(ToolUse(id: id, name: tool, input: input))],
            stopReason: .toolUse,
            usage: usage
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

    @Test func multipleToolCallsOnlyRunTheFirstTool() async {
        let llm = ScriptedLLMProvider([
            LLMResponse(
                content: [
                    .toolUse(ToolUse(
                        id: "t1",
                        name: "set_value",
                        input: ["element_index": 2, "value": "jazz"]
                    )),
                    .toolUse(ToolUse(
                        id: "t2",
                        name: "click",
                        input: ["element_index": 3]
                    ))
                ],
                stopReason: .toolUse,
                usage: .init(inputTokens: 1, outputTokens: 1)
            ),
            toolResponse(id: "t3", tool: "done", input: ["summary": "Done."])
        ])
        let computer = musicComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "set search and click play")
        #expect(outcome.status == .completed)

        let actions = await computer.performedActions
        #expect(actions == ["setValue:e2=jazz"])

        let requests = await llm.requests
        let recoveryText = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recoveryText.contains("Skipped click"))
        #expect(recoveryText.contains("call exactly one tool per step"))
    }

    @Test func emptyDoneSummaryUsesDefault() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "done", input: ["summary": "   \n  "])
        ])
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 5, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "finish quietly")
        #expect(outcome.status == .completed)
        #expect(outcome.summary == "Task complete.")
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

    @Test func textOnlyProviderOmitScreenshotRequests() async {
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "get_app_state",
                input: ["include_screenshot": true]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let computer = musicComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(
                model: "test",
                maxSteps: 5,
                highlightDwell: .zero,
                supportsImageInput: false
            ),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "inspect the screen")
        #expect(outcome.status == .completed)

        let actions = await computer.performedActions
        #expect(!actions.contains("screenshot"))

        let requests = await llm.requests
        let secondRequestText = requests.dropFirst().first?.messages
            .flatMap(\.content)
            .compactMap { block -> String? in
                guard case .toolResult(let result) = block else { return nil }
                return result.content.compactMap { content in
                    guard case .text(let text) = content else { return nil }
                    return text
                }
                .joined(separator: "\n")
            }
            .joined(separator: "\n") ?? ""
        #expect(secondRequestText.contains("Screenshot omitted"))
    }

    @Test func screenshotFailurePreservesTreeAndSurfacesWarning() async {
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "get_app_state",
                input: ["include_screenshot": true]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let computer = ScreenshotFailingComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(
                model: "test",
                maxSteps: 5,
                highlightDwell: .zero,
                supportsImageInput: true
            ),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "inspect the screen")
        #expect(outcome.status == .completed)
        #expect(await computer.screenshotAttempts == 1)

        let requests = await llm.requests
        let secondRequestText = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(secondRequestText.contains("App: Preview"))
        #expect(secondRequestText.contains("\"Save\""))
        #expect(secondRequestText.contains("Screenshot unavailable"))
        #expect(secondRequestText.contains("target window not matched"))
        #expect(secondRequestText.contains("accessibility tree above is still current"))
    }

    @Test func missingElementReturnsToolErrorBeforeApprovalOrAction() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 99]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let computer = musicComputer()
        let interaction = CountingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "click missing")

        #expect(interaction.approvalsRequested == 0)
        let actions = await computer.performedActions
        #expect(actions.isEmpty)

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
        #expect(text.contains("Fix the tool input and try again"))
    }

    @Test func failedActionResultCarriesFreshAppState() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 3]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let computer = FailingClickComputer()
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
        #expect(text.contains("synthetic click failure"))
        // A failed action re-reads the app so the model recovers at once,
        // rather than spending a turn calling get_app_state itself.
        #expect(text.contains("Current state of Music"))
        #expect(text.contains("\"Play\""))
    }

    @Test func failedActionEmitsActionFailedEvent() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 3]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let collector = EventCollector()
        let session = AgentSession(
            llm: llm,
            computer: FailingClickComputer(),
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
        #expect(failure?.1.contains("synthetic click failure") == true)
    }

    @Test func malformedWriteToolDoesNotAskForApprovalOrAct() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: [:]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let computer = musicComputer()
        let interaction = CountingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "click something")
        #expect(outcome.status == .completed)
        #expect(interaction.approvalsRequested == 0)
        #expect(await computer.performedActions.isEmpty)

        let requests = await llm.requests
        let recoveryText = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recoveryText.contains("Invalid input for click"))
        #expect(recoveryText.contains("missing element_index"))
    }

    @Test func malformedElementReferenceDoesNotAskForApprovalOrAct() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_id": "e-button"]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let computer = musicComputer()
        let interaction = CountingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "click something")
        #expect(interaction.approvalsRequested == 0)
        #expect(await computer.performedActions.isEmpty)

        let requests = await llm.requests
        let recoveryText = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recoveryText.contains("Invalid input for click"))
        #expect(recoveryText.contains("element_id must be an integer or element id like e12"))
    }

    @Test func fractionalScrollAmountDoesNotAct() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "scroll", input: ["direction": "down", "amount": 1.5]),
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

        _ = await session.run(task: "scroll")
        #expect(await computer.performedActions.isEmpty)

        let requests = await llm.requests
        let recoveryText = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recoveryText.contains("Invalid input for scroll"))
        #expect(recoveryText.contains("amount must be an integer from 1 to 20"))
    }

    @Test func invalidKeyModifierIsReturnedAsToolErrorBeforeApproval() async {
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "press_key",
                input: ["key": "q", "modifiers": ["cmd"]]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let computer = musicComputer()
        let interaction = CountingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "quit the app")
        #expect(interaction.approvalsRequested == 0)
        #expect(await computer.performedActions.isEmpty)

        let requests = await llm.requests
        let recoveryText = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recoveryText.contains("unsupported modifier cmd"))
        #expect(recoveryText.contains("Use command, shift, option, control, or function"))
    }

    @Test func unavailableSecondaryActionDoesNotAskForApprovalOrAct() async {
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "perform_secondary_action",
                input: ["element_index": 3, "action": "AXBogus"]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let computer = musicComputer()
        let interaction = CountingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "show a secondary action")
        #expect(interaction.approvalsRequested == 0)
        #expect(await computer.performedActions.isEmpty)

        let requests = await llm.requests
        let recoveryText = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recoveryText.contains("AXBogus is not available on e3"))
        #expect(recoveryText.contains("use one of the actions shown"))
    }

    @Test func setValueOnNonSettableElementDoesNotAskForApprovalOrAct() async {
        let field = UIElement(id: "e2", role: "AXTextField", label: "Search", value: "")
        let root = UIElement(id: "e1", role: "AXWindow", label: "Music", children: [field])
        let computer = MockComputer(appName: "Music", root: root, windowTitle: "Library")
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "set_value", input: [
                "element_index": 2,
                "value": "jazz"
            ]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let interaction = CountingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "set a value")
        #expect(interaction.approvalsRequested == 0)
        #expect(await computer.performedActions.isEmpty)

        let requests = await llm.requests
        let recoveryText = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recoveryText.contains("e2 is not marked settable"))
        #expect(recoveryText.contains("Use type_text"))
    }

    @Test func disabledClickDoesNotAskForApprovalOrAct() async {
        let deleteButton = UIElement(
            id: "e2",
            role: "AXButton",
            label: "Delete Playlist",
            isEnabled: false
        )
        let root = UIElement(id: "e1", role: "AXWindow", label: "Music", children: [deleteButton])
        let computer = MockComputer(appName: "Music", root: root, windowTitle: "Library")
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 2]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let interaction = CountingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "delete the playlist")
        #expect(interaction.approvalsRequested == 0)
        #expect(await computer.performedActions.isEmpty)

        let requests = await llm.requests
        let recoveryText = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recoveryText.contains("e2 is disabled"))
        #expect(recoveryText.contains("Choose an enabled element"))
    }

    @Test func disabledTypeTargetDoesNotAskForApprovalOrAct() async {
        let field = UIElement(
            id: "e2",
            role: "AXTextField",
            label: "Search",
            value: "",
            isEnabled: false
        )
        let root = UIElement(id: "e1", role: "AXWindow", label: "Music", children: [field])
        let computer = MockComputer(appName: "Music", root: root, windowTitle: "Library")
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "type_text", input: [
                "element_index": 2,
                "text": "jazz"
            ]),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Stopped."])
        ])
        let interaction = CountingInteraction()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: interaction,
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "type into the search field")
        #expect(interaction.approvalsRequested == 0)
        #expect(await computer.performedActions.isEmpty)

        let requests = await llm.requests
        let recoveryText = requests.dropFirst().first.map { allText(in: $0) } ?? ""
        #expect(recoveryText.contains("e2 is disabled"))
    }

    @Test func scrollInputNormalizesDirectionAndUsesBoundedAmount() async {
        let llm = ScriptedLLMProvider([
            toolResponse(
                id: "t1",
                tool: "scroll",
                input: ["direction": "Down", "amount": 2]
            ),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."])
        ])
        let computer = musicComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "scroll")
        #expect(await computer.performedActions == ["scroll:down:2"])
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

    @Test func truncatedReplyFailsRatherThanReportingFalseSuccess() async {
        // A reply cut off at the token limit, with no tool calls, must end the
        // run as failed — not as a clean completion.
        let llm = ScriptedLLMProvider([
            LLMResponse(
                content: [.text("A partial answer that the model never fin")],
                stopReason: .maxTokens,
                usage: .init(inputTokens: 1, outputTokens: 1)
            )
        ])
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "do something")
        #expect(outcome.status == .failed)
        #expect(outcome.summary.contains("cut off"))
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

    @Test func accumulatesPromptCacheTokensInInputTally() async {
        // With caching, the provider reports fresh input plus cache creation and
        // read figures; the run's reported input must include them all, or a
        // cached run looks far cheaper than it is.
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "get_app_state", input: [:],
                         usage: .init(inputTokens: 10, outputTokens: 2,
                                      cacheCreationInputTokens: 100,
                                      cacheReadInputTokens: 0)),
            toolResponse(id: "t2", tool: "done", input: ["summary": "Done."],
                         usage: .init(inputTokens: 5, outputTokens: 3,
                                      cacheCreationInputTokens: 0,
                                      cacheReadInputTokens: 100))
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

        _ = await session.run(task: "read then finish")

        let usage = collector.all().compactMap { event -> (Int, Int)? in
            if case .tokenUsage(let input, let output) = event { return (input, output) }
            return nil
        }
        // Step 1 total input: 10 + 100 = 110. Step 2 adds 5 + 100 = 105 → 215.
        #expect(usage.map(\.0) == [110, 215])
        #expect(usage.last?.1 == 5)
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

    @Test func repeatedActionStopsTheRun() async {
        let llm = ScriptedLLMProvider((1...3).map { index in
            toolResponse(id: "c\(index)", tool: "click", input: ["element_index": 3])
        })
        let computer = musicComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "click forever")
        #expect(outcome.status == .failed)
        #expect(outcome.summary.contains("repeated three times"))

        // The third, looping click is blocked — only the first two run.
        let actions = await computer.performedActions
        #expect(actions == ["click:e3", "click:e3"])
    }

    @Test func repeatedEquivalentElementReferencesStopTheRun() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "c1", tool: "click", input: ["element_index": 3]),
            toolResponse(id: "c2", tool: "click", input: ["element_index": " 3 "]),
            toolResponse(id: "c3", tool: "click", input: ["element_id": "e3"])
        ])
        let computer = musicComputer()
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "click forever")
        #expect(outcome.status == .failed)
        #expect(outcome.summary.contains("repeated three times"))
        #expect(await computer.performedActions == ["click:e3", "click:e3"])
    }

    @Test func repeatedActionWarnsBeforeStopping() async {
        let llm = ScriptedLLMProvider((1...3).map { index in
            toolResponse(id: "c\(index)", tool: "click", input: ["element_index": 3])
        })
        let session = AgentSession(
            llm: llm,
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        _ = await session.run(task: "click forever")

        // The first click is not flagged; the second draws the loop warning.
        let requests = await llm.requests
        #expect(!allText(in: requests[1]).contains("repeated an action identical"))
        #expect(allText(in: requests[2]).contains("repeated an action identical"))
    }

    @Test func repeatedScrollDoesNotTripLoopGuard() async {
        var responses = (1...4).map { index in
            toolResponse(id: "s\(index)", tool: "scroll", input: ["direction": "down"])
        }
        responses.append(toolResponse(id: "fin", tool: "done", input: ["summary": "Done."]))
        let computer = musicComputer()
        let session = AgentSession(
            llm: ScriptedLLMProvider(responses),
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "scroll the list")
        #expect(outcome.status == .completed)

        // Scrolling repeatedly is normal traversal, not a stuck loop.
        let actions = await computer.performedActions
        #expect(actions == Array(repeating: "scroll:down:3", count: 4))
    }

    @Test func cancellingDuringAnLLMCallReportsStopped() async {
        let session = AgentSession(
            llm: SlowLLMProvider(),
            computer: musicComputer(),
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", highlightDwell: .zero),
            memory: makeTestMemory()
        )

        let runTask = Task { await session.run(task: "slow task") }
        // Let the run reach the blocking LLM call, then hit the kill switch.
        try? await Task.sleep(for: .milliseconds(100))
        runTask.cancel()
        let outcome = await runTask.value

        // A cancelled provider call is a stop, not a failure.
        #expect(outcome.status == .stopped)
        #expect(outcome.summary == "Stopped by the user.")
    }

    @Test func unreadableAppEndsTheRunWithLostContact() async {
        let llm = ScriptedLLMProvider([
            toolResponse(id: "t1", tool: "click", input: ["element_index": 2]),
            toolResponse(id: "t2", tool: "scroll", input: ["direction": "down"])
        ])
        let session = AgentSession(
            llm: llm,
            computer: VanishingComputer(),
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(model: "test", maxSteps: 10, highlightDwell: .zero),
            memory: makeTestMemory()
        )

        let outcome = await session.run(task: "do something")
        #expect(outcome.status == .failed)
        #expect(outcome.summary.contains("Lost contact with Ghost"))
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

    @Test func smokeRunnerRunsEveryDriverStepAndReportsEachResult() async {
        let computer = fixtureComputer()
        let report = await ComputerUseSmokeRunner().run(
            computer: computer,
            plan: fixturePlan(clickElementIndex: 99)
        )

        // A failing click no longer aborts the run: every tool is still
        // exercised, so one validation run shows the full pass/fail matrix.
        #expect(!report.passed)
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
        let click = report.steps.first { $0.toolName == "click" }
        #expect(click?.status == .failed)
        #expect(click?.detail.contains("No element e99") == true)
        // Only the bad step failed; the other six driver tools ran and passed.
        #expect(report.steps.filter { $0.status == .failed }.map(\.toolName) == ["click"])

        let actions = await computer.performedActions
        #expect(actions == [
            "scroll:down:2",
            "setValue:e2=direct value",
            "typeText:e2:typed value",
            "key:return",
            "drag:e2->e3",
            "secondary:e3:AXShowMenu"
        ])
    }

    @Test func smokeRunnerFailedStepNamesTheTargetElement() async {
        let computer = fixtureComputer()
        var plan = fixturePlan()
        plan.secondaryAction = "AXBogus"  // not advertised on the target element
        let report = await ComputerUseSmokeRunner().run(computer: computer, plan: plan)

        #expect(!report.passed)
        let secondary = report.steps.first { $0.toolName == "perform_secondary_action" }
        #expect(secondary?.status == .failed)
        // The failure names the targeted element (id, role, label) for debugging.
        #expect(secondary?.detail.contains("e3") == true)
        #expect(secondary?.detail.contains("AXButton") == true)
        #expect(secondary?.detail.contains("Run") == true)
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

/// A `ComputerControl` whose current tree contains the target, but whose
/// action fails after preflight. This keeps stale-reference preflight tests
/// separate from real post-approval driver failure recovery.
actor FailingClickComputer: ComputerControl {
    nonisolated let appName = "Music"

    private let snapshot: UITreeSnapshot

    init() {
        let button = UIElement(id: "e3", role: "AXButton", label: "Play")
        let root = UIElement(id: "e1", role: "AXWindow", label: "Music", children: [button])
        snapshot = UITreeSnapshot(appName: "Music", windowTitle: "Library", root: root)
    }

    func captureTree() async throws -> UITreeSnapshot {
        snapshot
    }

    func click(elementID: String) async throws {
        throw AgentError.computer("synthetic click failure")
    }

    func setValue(elementID: String, value: String) async throws {
        throw AgentError.computer("unexpected set_value")
    }

    func scroll(elementID: String?, direction: ScrollDirection, amount: Int) async throws {
        throw AgentError.computer("unexpected scroll")
    }

    func pressKey(_ key: KeyPress) async throws {
        throw AgentError.computer("unexpected press_key")
    }

    func captureScreenshot() async throws -> Data {
        Data()
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
    func confirmWorkflow(_ proposal: WorkflowProposal) async -> Bool { false }
}

/// A `UserInteraction` that approves every action and saves every proposed
/// memory, for tests of the accept paths.
struct AcceptingMemoryInteraction: UserInteraction {
    func requestApproval(_ request: ApprovalRequest) async -> Bool { true }
    func askQuestion(_ question: String) async -> String { "" }
    func confirmMemory(_ proposal: MemoryProposal) async -> Bool { true }
    func confirmWorkflow(_ proposal: WorkflowProposal) async -> Bool { false }
}

/// A `UserInteraction` that approves every action and saves every proposed
/// workflow, for tests of the propose_workflow accept path.
struct AcceptingWorkflowInteraction: UserInteraction {
    func requestApproval(_ request: ApprovalRequest) async -> Bool { true }
    func askQuestion(_ question: String) async -> String { "" }
    func confirmMemory(_ proposal: MemoryProposal) async -> Bool { false }
    func confirmWorkflow(_ proposal: WorkflowProposal) async -> Bool { true }
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
    func confirmWorkflow(_ proposal: WorkflowProposal) async -> Bool { false }

    /// How many approval requests have been made so far.
    var approvalsRequested: Int {
        lock.withLock { count }
    }
}

/// An `LLMProvider` whose `send` blocks until cancelled, for exercising the
/// kill switch while a provider call is in flight.
actor SlowLLMProvider: LLMProvider {
    nonisolated let identifier = "slow"

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        try await Task.sleep(for: .seconds(30))
        return LLMResponse(
            content: [],
            stopReason: .endTurn,
            usage: .init(inputTokens: 0, outputTokens: 0)
        )
    }
}

/// A `ComputerControl` that reads once, then fails every read — simulating a
/// target app that closes or stops responding mid-run.
actor VanishingComputer: ComputerControl {
    nonisolated let appName = "Ghost"
    private var captures = 0

    func captureTree() async throws -> UITreeSnapshot {
        captures += 1
        guard captures == 1 else {
            throw AgentError.computer("\(appName)'s window can no longer be read")
        }
        return UITreeSnapshot(
            appName: appName,
            root: UIElement(id: "e1", role: "AXWindow", children: [
                UIElement(id: "e2", role: "AXButton", label: "Go")
            ])
        )
    }

    func click(elementID: String) async throws {}
    func setValue(elementID: String, value: String) async throws {}
    func scroll(elementID: String?, direction: ScrollDirection, amount: Int) async throws {}
    func pressKey(_ key: KeyPress) async throws {}
    func captureScreenshot() async throws -> Data { Data() }
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

actor ScreenshotFailingComputer: ComputerControl {
    nonisolated let appName = "Preview"
    private(set) var screenshotAttempts = 0

    func captureTree() async throws -> UITreeSnapshot {
        UITreeSnapshot(
            appName: appName,
            root: UIElement(id: "e1", role: "AXWindow", children: [
                UIElement(id: "e2", role: "AXButton", label: "Save")
            ])
        )
    }

    func click(elementID: String) async throws {}
    func setValue(elementID: String, value: String) async throws {}
    func scroll(elementID: String?, direction: ScrollDirection, amount: Int) async throws {}
    func pressKey(_ key: KeyPress) async throws {}

    func captureScreenshot() async throws -> Data {
        screenshotAttempts += 1
        throw AgentError.computer("target window not matched")
    }
}
