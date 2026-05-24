import AutopilotAgent
import AutopilotCore
import AutopilotHistory
import AutopilotMemory
import AutopilotWorkflows
import Foundation
import Testing
@testable import AutopilotUI

@MainActor
struct AgentViewModelTests {
    @Test func selectedProviderExposesCapabilityMetadata() {
        let model = AgentViewModel()
        model.selectedProvider = .zai
        #expect(model.selectedProviderDescriptor.identifier == "zai")
        #expect(!model.selectedProviderDescriptor.supportsImageInput)
        #expect(model.selectedProviderLimitations?.contains("Screenshots are disabled") == true)

        model.selectedProvider = .anthropic
        #expect(model.selectedProviderDescriptor.identifier == "anthropic")
        #expect(model.selectedProviderDescriptor.supportsImageInput)
        #expect(model.selectedProviderLimitations == nil)
    }

    @Test func willPerformHighlightsTargetUntilActionEnds() {
        let model = AgentViewModel()
        let target = ActionTarget(
            appName: "Notes",
            elementID: "e2",
            role: "AXButton",
            label: "Save",
            description: "Click Save",
            frame: ElementFrame(x: 10, y: 20, width: 30, height: 40)
        )

        model.ingestForTesting(.willPerform(tool: .click, target: target, tier: .write))
        #expect(model.highlightedTarget == target)

        model.ingestForTesting(.performed(tool: .click, summary: "Click Save"))
        #expect(model.highlightedTarget == nil)
    }

    @Test func storageFailureAppearsInFeed() {
        let model = AgentViewModel()
        model.ingestForTesting(.storageFailed("Could not save memory: denied"))
        #expect(model.feed.last?.text == "Storage warning — Could not save memory: denied")
        #expect(model.feed.last?.isError == true)
    }

    @Test func askQuestionWaitsForResolvedAnswer() async {
        let model = AgentViewModel()
        let answerTask = Task { @MainActor in
            await model.askQuestion("Which playlist should I use?")
        }

        await Task.yield()
        #expect(model.pendingQuestion?.text == "Which playlist should I use?")

        model.questionAnswerText = "Jazz"
        model.resolveQuestion(model.questionAnswerText)

        let answer = await answerTask.value
        #expect(answer == "Jazz")
        #expect(model.pendingQuestion == nil)
        #expect(model.questionAnswerText.isEmpty)
    }

    @Test func stopResumesPendingQuestionWithEmptyAnswer() async {
        let model = AgentViewModel()
        let answerTask = Task { @MainActor in
            await model.askQuestion("Which account?")
        }

        await Task.yield()
        #expect(model.pendingQuestion?.text == "Which account?")

        model.stop()

        let answer = await answerTask.value
        #expect(answer.isEmpty)
        #expect(model.pendingQuestion == nil)
    }

    // MARK: - Approval bridge

    private func approvalRequest(tier: RiskLevel, summary: String) -> ApprovalRequest {
        ApprovalRequest(
            appName: "Notes",
            tier: tier,
            target: ActionTarget(appName: "Notes", description: summary),
            summary: summary
        )
    }

    @Test func requestApprovalSurfacesAndResolvesApproved() async {
        let model = AgentViewModel()
        let approvalTask = Task { @MainActor in
            await model.requestApproval(approvalRequest(tier: .write, summary: "Click Save"))
        }

        await Task.yield()
        #expect(model.pendingApproval?.summary == "Click Save")
        #expect(model.pendingApproval?.isDestructive == false)

        model.resolveApproval(true)

        let approved = await approvalTask.value
        #expect(approved == true)
        #expect(model.pendingApproval == nil)
    }

    @Test func requestApprovalResolvesDeclined() async {
        let model = AgentViewModel()
        let approvalTask = Task { @MainActor in
            await model.requestApproval(approvalRequest(tier: .destructive, summary: "Delete file"))
        }

        await Task.yield()
        #expect(model.pendingApproval?.isDestructive == true)

        model.resolveApproval(false)

        let approved = await approvalTask.value
        #expect(approved == false)
        #expect(model.pendingApproval == nil)
    }

    @Test func stopResumesPendingApprovalAsDeclined() async {
        let model = AgentViewModel()
        let approvalTask = Task { @MainActor in
            await model.requestApproval(approvalRequest(tier: .destructive, summary: "Delete file"))
        }

        await Task.yield()
        #expect(model.pendingApproval != nil)

        model.stop()

        // A stop must never leave a gated action approved; it resumes as declined.
        let approved = await approvalTask.value
        #expect(approved == false)
        #expect(model.pendingApproval == nil)
    }

    // MARK: - Memory-proposal bridge

    @Test func confirmMemorySurfacesAndResolvesSaved() async {
        let model = AgentViewModel()
        let memoryTask = Task { @MainActor in
            await model.confirmMemory(MemoryProposal(text: "Prefers dark mode", scope: .global))
        }

        await Task.yield()
        #expect(model.pendingMemory?.text == "Prefers dark mode")

        model.resolveMemory(true)

        let saved = await memoryTask.value
        #expect(saved == true)
        #expect(model.pendingMemory == nil)
    }

    @Test func confirmMemoryResolvesDeclined() async {
        let model = AgentViewModel()
        let memoryTask = Task { @MainActor in
            await model.confirmMemory(MemoryProposal(text: "Prefers dark mode", scope: .global))
        }

        await Task.yield()
        #expect(model.pendingMemory != nil)

        model.resolveMemory(false)

        let saved = await memoryTask.value
        #expect(saved == false)
        #expect(model.pendingMemory == nil)
    }

    @Test func stopResumesPendingMemoryAsDeclined() async {
        let model = AgentViewModel()
        let memoryTask = Task { @MainActor in
            await model.confirmMemory(MemoryProposal(text: "Prefers dark mode", scope: .global))
        }

        await Task.yield()
        #expect(model.pendingMemory != nil)

        model.stop()

        // A stop must never silently save a proposed memory; it resumes declined.
        let saved = await memoryTask.value
        #expect(saved == false)
        #expect(model.pendingMemory == nil)
    }
}

@MainActor
struct AgentViewModelWorkflowTests {
    private func makeModel() -> (AgentViewModel, WorkflowStore) {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let store = WorkflowStore(directory: directory)
        let model = AgentViewModel(
            memory: MemoryStore(directory: directory),
            history: RunHistoryStore(directory: directory),
            workflows: store
        )
        return (model, store)
    }

    /// Wait for a fire-and-forget store write to land, without a fixed sleep.
    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @Test func createWorkflowDerivesVariablesFromSlots() async {
        let (model, store) = makeModel()
        model.createWorkflow(
            name: "Weekly report",
            appName: "Mail",
            goalTemplate: "Email {{recipient}} the {{report}}"
        )
        await waitUntil { !(await store.all().isEmpty) }

        let stored = await store.all().first
        #expect(stored?.name == "Weekly report")
        #expect(stored?.appName == "Mail")
        #expect(stored?.goalTemplate == "Email {{recipient}} the {{report}}")
        #expect(stored?.variableNames == ["recipient", "report"])
        #expect(stored?.source == .manual)
    }

    @Test func createWorkflowNeedsNameGoalAndApp() async {
        let (model, store) = makeModel()
        model.createWorkflow(name: " ", appName: "Mail", goalTemplate: "do it")
        model.createWorkflow(name: "X", appName: "", goalTemplate: "do it")
        model.createWorkflow(name: "Y", appName: "Mail", goalTemplate: "  ")
        // Give any (incorrectly) spawned writes a chance to land before asserting.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(await store.all().isEmpty)
    }

    @Test func saveRunAsWorkflowUsesTaskAsGoal() async {
        let (model, store) = makeModel()
        let run = RunRecord(
            task: "  Archive read mail in {{folder}}  ",
            appName: " Mail ",
            model: "test-model",
            status: .completed,
            summary: "Done.",
            startedAt: Date(),
            finishedAt: Date()
        )
        model.saveRunAsWorkflow(run, name: "Archive")
        await waitUntil { !(await store.all().isEmpty) }

        let stored = await store.all().first
        #expect(stored?.goalTemplate == "Archive read mail in {{folder}}")
        #expect(stored?.appName == "Mail")
        #expect(stored?.variableNames == ["folder"])
        #expect(stored?.source == .savedFromRun)
        #expect(stored?.sourceRunID == run.id)
    }

    @Test func saveRunAsWorkflowNeedsNameTaskAndApp() async {
        let (model, store) = makeModel()
        let completeRun = RunRecord(
            task: "do it",
            appName: "Mail",
            model: "test-model",
            status: .completed,
            summary: "Done.",
            startedAt: Date(),
            finishedAt: Date()
        )
        let missingTask = RunRecord(
            task: " ",
            appName: "Mail",
            model: "test-model",
            status: .completed,
            summary: "Done.",
            startedAt: Date(),
            finishedAt: Date()
        )
        let missingApp = RunRecord(
            task: "do it",
            appName: "",
            model: "test-model",
            status: .completed,
            summary: "Done.",
            startedAt: Date(),
            finishedAt: Date()
        )

        model.saveRunAsWorkflow(completeRun, name: " ")
        model.saveRunAsWorkflow(missingTask, name: "Missing task")
        model.saveRunAsWorkflow(missingApp, name: "Missing app")
        // Give any (incorrectly) spawned writes a chance to land before asserting.
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(await store.all().isEmpty)
    }

    @Test func duplicateWorkflowNameWarnsInFeed() async {
        let (model, store) = makeModel()
        model.createWorkflow(name: "Daily", appName: "Mail", goalTemplate: "first")
        await waitUntil { !(await store.all().isEmpty) }

        model.createWorkflow(name: "daily", appName: "Mail", goalTemplate: "second")
        await waitUntil { model.feed.contains { $0.text.contains("already exists") } }

        #expect(model.feed.contains { $0.text.contains("already exists") && $0.isError })
        #expect(await store.all().count == 1)
    }

    @Test func deleteWorkflowRemovesIt() async {
        let (model, store) = makeModel()
        model.createWorkflow(name: "Temp", appName: "Mail", goalTemplate: "do it")
        await waitUntil { !(await store.all().isEmpty) }

        let id = await store.all().first!.id
        model.deleteWorkflow(id: id)
        await waitUntil { await store.all().isEmpty }
        #expect(await store.all().isEmpty)
    }

    @Test func loadWorkflowsReflectsStore() async {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let store = WorkflowStore(directory: directory)
        await store.add(Workflow(
            name: "Seeded",
            appName: "Notes",
            goalTemplate: "do {{x}}",
            variables: [WorkflowVariable(name: "x")],
            source: .manual
        ))
        let model = AgentViewModel(
            memory: MemoryStore(directory: directory),
            history: RunHistoryStore(directory: directory),
            workflows: store
        )
        await waitUntil { !model.savedWorkflows.isEmpty }

        #expect(model.savedWorkflows.first?.name == "Seeded")
        #expect(model.savedWorkflows.first?.variables.map(\.name) == ["x"])
    }

    @Test func runWorkflowWithoutAPIKeyFails() {
        let (model, _) = makeModel()
        model.apiKey = ""
        model.runWorkflow(id: UUID(), bindings: [:])
        guard case .failed(let reason) = model.phase else {
            Issue.record("expected failure without an API key")
            return
        }
        #expect(reason.contains("API key"))
    }

    @Test func runWorkflowWithMissingBindingsFailsBeforeAppLookup() async {
        let (model, store) = makeModel()
        model.apiKey = "test-key"
        let workflow = Workflow(
            name: "Needs field",
            appName: "NoSuchApp9X8Y7Z",
            goalTemplate: "Email {{recipient}}",
            variables: [WorkflowVariable(name: "recipient")],
            source: .manual
        )
        await store.add(workflow)

        model.runWorkflow(id: workflow.id, bindings: [:])
        await waitUntil {
            if case .failed = model.phase { return true }
            return false
        }

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected failure when a workflow field is missing")
            return
        }
        #expect(reason.contains("{{recipient}}"))
    }

    @Test func runWorkflowMarksPhaseRunningBeforeAsyncLookup() async {
        let (model, store) = makeModel()
        model.apiKey = "test-key"
        let workflow = Workflow(
            name: "Queued",
            appName: "NoSuchApp9X8Y7Z",
            goalTemplate: "Do it",
            source: .manual
        )
        await store.add(workflow)

        model.runWorkflow(id: workflow.id, bindings: [:])

        #expect(model.phase == .running)
    }

    @Test func runWorkflowAcceptsDefaultBindingsBeforeAppLookup() async {
        let (model, store) = makeModel()
        model.apiKey = "test-key"
        let workflow = Workflow(
            name: "Has default",
            appName: "NoSuchApp9X8Y7Z",
            goalTemplate: "Email {{recipient}}",
            variables: [WorkflowVariable(name: "recipient", defaultValue: "Maya")],
            source: .manual
        )
        await store.add(workflow)

        model.runWorkflow(id: workflow.id, bindings: [:])
        await waitUntil {
            if case .failed = model.phase { return true }
            return false
        }

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected app-running failure after defaults satisfy bindings")
            return
        }
        #expect(reason.contains("not running"))
    }

    @Test func runWorkflowWithAppNotRunningFails() async {
        let (model, store) = makeModel()
        model.apiKey = "test-key"
        let workflow = Workflow(
            name: "Ghost",
            appName: "NoSuchApp9X8Y7Z",
            goalTemplate: "do {{x}}",
            source: .manual
        )
        await store.add(workflow)
        model.runWorkflow(id: workflow.id, bindings: ["x": "y"])
        await waitUntil {
            if case .failed = model.phase { return true }
            return false
        }
        guard case .failed(let reason) = model.phase else {
            Issue.record("expected failure when the app is not running")
            return
        }
        #expect(reason.contains("not running"))
    }
}
