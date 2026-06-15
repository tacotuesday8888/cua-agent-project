import AutopilotAgent
import AutopilotCore
import AutopilotHistory
import AutopilotMemory
import AutopilotWorkflows
import Foundation
import Testing
@testable import AutopilotUI

@Suite(.serialized)
@MainActor
struct AgentViewModelTests {
    @Test func selectedProviderExposesCapabilityMetadata() {
        let model = AgentViewModel()
        model.selectedProvider = .openai
        #expect(model.selectedProviderDescriptor.identifier == "openai")
        #expect(model.selectedProviderAccessMode == .bringYourOwnKey)
        #expect(model.selectedModelDescriptor.identifier == "gpt-5.4-mini")
        #expect(model.selectedProviderDescriptor.supportsImageInput)
        #expect(model.selectedModelDescriptor.supportsImageInput)

        model.selectedProvider = .anthropic
        #expect(model.selectedProviderDescriptor.identifier == "anthropic")
        #expect(model.selectedProviderAccessMode == .bringYourOwnKey)
        #expect(model.selectedModelDescriptor.identifier == "claude-sonnet-4-6")
        #expect(model.selectedProviderDescriptor.supportsImageInput)
    }

    @Test func providerSwitchLoadsThatProvidersDefaultModel() {
        let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        let savedCompatibleModel = UserDefaults.standard.string(forKey: Self.compatibleModelDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.compatibleModelDefaultsKey)
        defer {
            Self.restoreProviderDefault(saved)
            Self.restoreDefault(savedCompatibleModel, forKey: Self.compatibleModelDefaultsKey)
        }

        let model = AgentViewModel()
        model.selectedProvider = .hosted
        #expect(model.selectedProviderAccessMode == .appManaged)
        #expect(model.selectedProvider.displayName == "Mac Autopilot Basic")
        #expect(model.selectedModelName == "gpt-5.4-mini")
        #expect(model.availableModelDescriptors.map(\.identifier).contains(model.selectedModelName))

        model.selectedProvider = .openAICompatible
        #expect(model.selectedProviderAccessMode == .bringYourOwnKey)
        #expect(model.selectedProvider.displayName == "OpenAI-compatible endpoint")
        #expect(model.selectedProviderUsesAPIKey)
        #expect(!model.selectedProviderRequiresAPIKey)
        #expect(model.selectedModelDescriptor.identifier == "custom-model")
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

    // MARK: - Hosted provider

    /// The persisted-provider key. Hosted tests restore it so the only
    /// key-free provider never leaks into the suite's "missing key" tests.
    private static let providerDefaultsKey = "AutopilotLLMProvider"
    private static let compatibleModelDefaultsKey = "AutopilotLLMModel.openai-compatible"
    private static let compatiblePresetDefaultsKey = "AutopilotOpenAICompatiblePreset"
    private static let compatibleEndpointDefaultsKey = "AutopilotOpenAICompatibleEndpoint"
    private static let compatibleImageSupportDefaultsKey = "AutopilotOpenAICompatibleSupportsImageInput"

    @Test func defaultProviderIsAppManagedAI() {
        let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.providerDefaultsKey)
        defer { Self.restoreProviderDefault(saved) }

        let model = AgentViewModel()
        #expect(model.selectedProvider == .hosted)
        #expect(model.selectedProviderAccessMode == .appManaged)
        #expect(model.selectedProvider.displayName == "Mac Autopilot Basic")
    }

    @Test func hostedProviderExposesCapabilityMetadata() {
        let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        defer { Self.restoreProviderDefault(saved) }

        let model = AgentViewModel()
        model.selectedProvider = .hosted
        #expect(model.selectedProviderDescriptor.identifier == "hosted")
        #expect(model.selectedProvider.displayName == "Mac Autopilot Basic")
        #expect(model.selectedProviderAccessMode == .appManaged)
        #expect(model.selectedModelName == "gpt-5.4-mini")
        #expect(model.selectedProviderDescriptor.supportsImageInput)
        #expect(model.selectedModelDescriptor.supportsImageInput)
        #expect(model.selectedProviderDescriptor.supportsToolCalls)
        // Hosted authenticates with the signed-in account, so the UI hides the
        // key field and no key is required to start a run.
        #expect(model.selectedProviderRequiresAPIKey == false)
    }

    @Test func hostedProviderIsSelectableInThePicker() {
        #expect(AgentViewModel.Provider.allCases.contains(.hosted))
    }

    @Test func openAICompatibleProviderIsSelectableInThePicker() {
        #expect(AgentViewModel.Provider.allCases.contains(.openAICompatible))
    }

    @Test func existingAccountProvidersAreSelectableInThePicker() {
        #expect(AgentViewModel.Provider.allCases.contains(.chatGPTAccount))
        #expect(AgentViewModel.Provider.allCases.contains(.anthropicSubscription))
    }

    @Test func openAICompatiblePresetsExposeMainstreamRoutersAndLocalEndpoints() {
        let presets = Dictionary(uniqueKeysWithValues: AgentViewModel.openAICompatiblePresets.map {
            ($0.id, $0)
        })

        #expect(presets["openrouter"]?.endpoint == "https://openrouter.ai/api/v1/chat/completions")
        #expect(presets["gemini"]?.endpoint == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        #expect(presets["groq"]?.endpoint == "https://api.groq.com/openai/v1/chat/completions")
        #expect(presets["together"]?.endpoint == "https://api.together.xyz/v1/chat/completions")
        #expect(presets["fireworks"]?.endpoint == "https://api.fireworks.ai/inference/v1/chat/completions")
        #expect(presets["deepseek"]?.endpoint == "https://api.deepseek.com/chat/completions")
        #expect(presets["qwen"]?.endpoint == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        #expect(presets["glm"]?.endpoint == "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        #expect(presets["litellm"]?.endpoint == "http://localhost:4000/v1/chat/completions")
        #expect(presets["ollama"]?.endpoint == "http://localhost:11434/v1/chat/completions")

        #expect(presets["openrouter"]?.requiresAPIKey == true)
        #expect(presets["gemini"]?.requiresAPIKey == true)
        #expect(presets["ollama"]?.requiresAPIKey == false)
        #expect(presets["custom"]?.requiresAPIKey == false)
    }

    @Test func existingAccountAccessModeIsVisibleAndAvailable() {
        let model = AgentViewModel()
        let status = model.existingAccountAccessStatus

        #expect(status.accessMode == .existingSubscription)
        #expect(status.title == "Existing AI Account Access")
        #expect(status.isAvailable)
        #expect(status.summary.contains("ChatGPT"))
        #expect(status.summary.contains("Claude Pro/Max"))
        #expect(status.detail.contains("ChatGPT"))
        #expect(status.detail.contains("OAuth"))
        #expect(status.detail.contains("structured output"))
    }

    @Test func savedAccountProviderRestoresFromUserDefaults() {
        let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        UserDefaults.standard.set(
            AgentViewModel.Provider.anthropicSubscription.rawValue,
            forKey: Self.providerDefaultsKey
        )
        defer { Self.restoreProviderDefault(saved) }

        let model = AgentViewModel()
        #expect(model.selectedProvider == .anthropicSubscription)
        #expect(model.selectedProviderAccessMode == .existingSubscription)
    }

    @Test func chatGPTAccountProviderExposesSubscriptionOAuthMetadata() {
        let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        defer { Self.restoreProviderDefault(saved) }

        let model = AgentViewModel()
        model.selectedProvider = .chatGPTAccount

        #expect(model.selectedProviderAccessMode == .existingSubscription)
        #expect(model.selectedProvider.displayName == "ChatGPT subscription")
        #expect(!model.selectedProviderUsesAPIKey)
        #expect(!model.selectedProviderRequiresAPIKey)
        #expect(model.selectedModelDescriptor.identifier == "automatic")
        #expect(!model.selectedModelDescriptor.supportsImageInput)
        #expect(model.selectedSubscriptionAccountRequirement?.providerID == .chatGPTCodex)
    }

    @Test func claudeAccountProviderExposesSubscriptionOAuthMetadata() {
        let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        defer { Self.restoreProviderDefault(saved) }

        let model = AgentViewModel()
        model.selectedProvider = .anthropicSubscription

        #expect(model.selectedProviderAccessMode == .existingSubscription)
        #expect(model.selectedProvider.displayName == "Claude subscription")
        #expect(!model.selectedProviderUsesAPIKey)
        #expect(!model.selectedProviderRequiresAPIKey)
        #expect(model.selectedModelDescriptor.identifier == "automatic")
        #expect(!model.selectedModelDescriptor.supportsImageInput)
        #expect(model.selectedSubscriptionAccountRequirement?.providerID == .anthropic)
    }

    @Test func subscriptionAccountProviderBlocksRunWhenSignedOut() {
        let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        defer { Self.restoreProviderDefault(saved) }

        let model = AgentViewModel()
        model.selectedProvider = .chatGPTAccount
        model.subscriptionAccountSignedInProvider = { _ in false }
        model.selectedAppName = "NoSuchApp9X8Y7Z"
        model.promptText = "Do something"

        model.submit()

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected signed-out account failure")
            return
        }
        #expect(reason.contains("Sign in"))
        #expect(reason.contains("ChatGPT subscription"))
        #expect(!reason.contains("NoSuchApp9X8Y7Z"))
    }

    @Test func subscriptionAccountProviderBlocksRunUntilStatusIsKnown() {
        let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        defer { Self.restoreProviderDefault(saved) }

        let model = AgentViewModel()
        model.selectedProvider = .chatGPTAccount
        model.subscriptionAccountSignedInProvider = { _ in nil }
        model.selectedAppName = "NoSuchApp9X8Y7Z"
        model.promptText = "Do something"

        model.submit()

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected unknown account status failure")
            return
        }
        #expect(reason.contains("Check"))
        #expect(reason.contains("sign-in status"))
        #expect(!reason.contains("NoSuchApp9X8Y7Z"))
    }

    @Test func subscriptionAccountProviderAllowsRunAfterKnownSignIn() {
        let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        defer { Self.restoreProviderDefault(saved) }

        let model = AgentViewModel()
        model.selectedProvider = .chatGPTAccount
        model.subscriptionAccountSignedInProvider = { _ in true }
        model.selectedAppName = "NoSuchApp9X8Y7Z"
        model.promptText = "Do something"

        model.submit()

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected app lookup failure after account readiness passed")
            return
        }
        #expect(reason.contains("NoSuchApp9X8Y7Z"))
        #expect(!reason.contains("Sign in"))
    }

    @Test func hostedEndpointPointsAtTheDeployedProxy() {
        #expect(
            AgentViewModel.hostedEndpoint.absoluteString
                == "https://us-central1-macautopilot.cloudfunctions.net/llmProxy"
        )
    }

    @Test func submitWithHostedProviderRequiresSignedInBasicAccountBeforeTargetLookup() {
        let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        defer { Self.restoreProviderDefault(saved) }

        let model = AgentViewModel()
        model.selectedProvider = .hosted
        model.apiKey = ""
        model.selectedAppName = "NoSuchApp9X8Y7Z"
        model.promptText = "Do something"
        model.submit()

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected a hosted sign-in setup failure")
            return
        }
        #expect(!reason.contains("API key"))
        #expect(reason.contains("Sign in"))
        #expect(reason.contains("Mac Autopilot Basic"))
        #expect(!reason.contains("NoSuchApp9X8Y7Z"))
    }

    @Test func submitWithHostedProviderAllowsTargetLookupAfterSignedInBasicAccount() {
        let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        defer { Self.restoreProviderDefault(saved) }

        let model = AgentViewModel()
        model.selectedProvider = .hosted
        model.hostedAccountStatusProvider = {
            AgentViewModel.HostedAccountStatus(email: "user@example.com")
        }
        model.apiKey = ""
        model.selectedAppName = "NoSuchApp9X8Y7Z"
        model.promptText = "Do something"
        model.submit()

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected app lookup failure after hosted sign-in readiness passed")
            return
        }
        #expect(!reason.contains("API key"))
        #expect(!reason.contains("Sign in"))
        #expect(reason.contains("NoSuchApp9X8Y7Z"))
    }

    @Test func openAICompatibleProviderExposesCustomModelAndCapabilityState() {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        let savedModel = UserDefaults.standard.string(forKey: Self.compatibleModelDefaultsKey)
        let savedPreset = UserDefaults.standard.string(forKey: Self.compatiblePresetDefaultsKey)
        let savedEndpoint = UserDefaults.standard.string(forKey: Self.compatibleEndpointDefaultsKey)
        let savedImages = UserDefaults.standard.object(forKey: Self.compatibleImageSupportDefaultsKey)
        defer {
            Self.restoreProviderDefault(savedProvider)
            Self.restoreDefault(savedModel, forKey: Self.compatibleModelDefaultsKey)
            Self.restoreDefault(savedPreset, forKey: Self.compatiblePresetDefaultsKey)
            Self.restoreDefault(savedEndpoint, forKey: Self.compatibleEndpointDefaultsKey)
            Self.restoreObject(savedImages, forKey: Self.compatibleImageSupportDefaultsKey)
        }

        let model = AgentViewModel()
        model.selectedProvider = .openAICompatible
        model.openAICompatibleEndpoint = "http://localhost:11434/v1/chat/completions"
        model.selectedModelID = "llama3.2-vision"
        model.openAICompatibleSupportsImageInput = true

        #expect(model.selectedProviderDescriptor.identifier == "openai-compatible")
        #expect(model.selectedProviderAccessMode == .bringYourOwnKey)
        #expect(model.selectedProviderUsesAPIKey)
        #expect(!model.selectedProviderRequiresAPIKey)
        #expect(model.openAICompatibleEndpointURL?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(model.selectedModelDescriptor.identifier == "llama3.2-vision")
        #expect(model.selectedModelDescriptor.displayName == "llama3.2-vision")
        #expect(model.selectedModelDescriptor.supportsToolCalls)
        #expect(model.selectedModelDescriptor.supportsImageInput)
        #expect(!model.selectedModelDescriptor.supportsPromptCaching)
    }

    @Test func applyingOpenAICompatiblePresetUpdatesEndpointAndKeyRequirement() {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        let savedPreset = UserDefaults.standard.string(forKey: Self.compatiblePresetDefaultsKey)
        let savedEndpoint = UserDefaults.standard.string(forKey: Self.compatibleEndpointDefaultsKey)
        defer {
            Self.restoreProviderDefault(savedProvider)
            Self.restoreDefault(savedPreset, forKey: Self.compatiblePresetDefaultsKey)
            Self.restoreDefault(savedEndpoint, forKey: Self.compatibleEndpointDefaultsKey)
        }

        let model = AgentViewModel()
        model.selectedProvider = .openAICompatible
        model.applyOpenAICompatiblePreset(id: "ollama")
        #expect(model.openAICompatiblePresetID == "ollama")
        #expect(model.openAICompatibleEndpoint == "http://localhost:11434/v1/chat/completions")
        #expect(!model.selectedProviderRequiresAPIKey)

        model.applyOpenAICompatiblePreset(id: "openrouter")
        #expect(model.openAICompatiblePresetID == "openrouter")
        #expect(model.openAICompatibleEndpoint == "https://openrouter.ai/api/v1/chat/completions")
        #expect(model.selectedProviderRequiresAPIKey)
    }

    @Test func openAICompatibleProviderValidatesEndpointAndModelBeforeRun() {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        let savedModel = UserDefaults.standard.string(forKey: Self.compatibleModelDefaultsKey)
        let savedPreset = UserDefaults.standard.string(forKey: Self.compatiblePresetDefaultsKey)
        let savedEndpoint = UserDefaults.standard.string(forKey: Self.compatibleEndpointDefaultsKey)
        defer {
            Self.restoreProviderDefault(savedProvider)
            Self.restoreDefault(savedModel, forKey: Self.compatibleModelDefaultsKey)
            Self.restoreDefault(savedPreset, forKey: Self.compatiblePresetDefaultsKey)
            Self.restoreDefault(savedEndpoint, forKey: Self.compatibleEndpointDefaultsKey)
        }

        let model = AgentViewModel()
        model.selectedProvider = .openAICompatible
        model.apiKey = ""
        model.selectedModelID = "qwen/qwen3-coder"
        model.openAICompatibleEndpoint = ""
        model.promptText = "Do something"
        model.submit()

        guard case .failed(let missingEndpoint) = model.phase else {
            Issue.record("expected missing endpoint failure")
            return
        }
        #expect(missingEndpoint.contains("chat completions URL"))
        #expect(!missingEndpoint.contains("API key"))

        model.openAICompatibleEndpoint = "http://localhost:11434/v1/chat/completions"
        model.selectedModelID = "   "
        model.submit()

        guard case .failed(let missingModel) = model.phase else {
            Issue.record("expected missing model failure")
            return
        }
        #expect(missingModel.contains("model ID"))
    }

    @Test func openAICompatibleCloudPresetRequiresAPIKeyBeforeRun() {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        let savedPreset = UserDefaults.standard.string(forKey: Self.compatiblePresetDefaultsKey)
        let savedEndpoint = UserDefaults.standard.string(forKey: Self.compatibleEndpointDefaultsKey)
        defer {
            Self.restoreProviderDefault(savedProvider)
            Self.restoreDefault(savedPreset, forKey: Self.compatiblePresetDefaultsKey)
            Self.restoreDefault(savedEndpoint, forKey: Self.compatibleEndpointDefaultsKey)
        }

        let model = AgentViewModel()
        model.selectedProvider = .openAICompatible
        model.applyOpenAICompatiblePreset(id: "groq")
        model.selectedModelID = "llama-3.3-70b-versatile"
        model.apiKey = ""
        model.promptText = "Do something"
        model.submit()

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected API key failure")
            return
        }
        #expect(reason.contains("Groq"))
        #expect(reason.contains("API key"))
    }

    private static func restoreProviderDefault(_ saved: String?) {
        if let saved {
            UserDefaults.standard.set(saved, forKey: providerDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: providerDefaultsKey)
        }
    }

    private static func restoreDefault(_ saved: String?, forKey key: String) {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func restoreObject(_ saved: Any?, forKey key: String) {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

@MainActor
struct AgentViewModelWorkflowTests {
    private static let providerDefaultsKey = "AutopilotLLMProvider"

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

    private static func restoreProviderDefault(_ saved: String?) {
        if let saved {
            UserDefaults.standard.set(saved, forKey: providerDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: providerDefaultsKey)
        }
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

    @Test func saveRunAsWorkflowDoesNotPersistRedactedHistoryAsGoal() async {
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
        // Give any incorrectly spawned write a chance to land.
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(await store.all().isEmpty)
        #expect(model.feed.contains { $0.text.contains("Run history is redacted") && $0.isError })
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
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        let (model, _) = makeModel()
        model.selectedProvider = .openai
        Self.restoreProviderDefault(savedProvider)
        model.apiKey = ""
        model.runWorkflow(id: UUID(), bindings: [:])
        guard case .failed(let reason) = model.phase else {
            Issue.record("expected failure without an API key")
            return
        }
        #expect(reason.contains("API key"))
    }

    @Test func runWorkflowWithHostedProviderRequiresSignedInBasicAccountBeforeLookup() async {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)

        let (model, _) = makeModel()
        model.selectedProvider = .hosted
        model.apiKey = ""
        model.runWorkflow(id: UUID(), bindings: [:])
        // The key guard runs synchronously above; restore the global default
        // before the first await so a parallel test never observes the persisted
        // "hosted" value (which would make it skip its own key guard).
        Self.restoreProviderDefault(savedProvider)

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected hosted sign-in failure before workflow lookup")
            return
        }
        #expect(!reason.contains("API key"))
        #expect(reason.contains("Sign in"))
        #expect(reason.contains("Mac Autopilot Basic"))
        #expect(!reason.contains("could not be found"))
    }

    @Test func runWorkflowWithMissingBindingsFailsBeforeAppLookup() async {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        let (model, store) = makeModel()
        model.selectedProvider = .openai
        Self.restoreProviderDefault(savedProvider)
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
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        let (model, store) = makeModel()
        model.selectedProvider = .openai
        Self.restoreProviderDefault(savedProvider)
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

    @Test func stopDuringWorkflowPreflightPreventsLaterFailureOverride() async {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        let (model, store) = makeModel()
        model.selectedProvider = .openai
        Self.restoreProviderDefault(savedProvider)
        model.apiKey = "test-key"
        let workflow = Workflow(
            name: "Cancelable",
            appName: "NoSuchApp9X8Y7Z",
            goalTemplate: "Do it",
            source: .manual
        )
        await store.add(workflow)

        model.runWorkflow(id: workflow.id, bindings: [:])
        #expect(model.phase == .running)

        model.stop()
        await waitUntil {
            guard case .failed(let reason) = model.phase else { return false }
            return reason == "Stopped."
        }

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected stop to end workflow preflight")
            return
        }
        #expect(reason == "Stopped.")
        try? await Task.sleep(nanoseconds: 20_000_000)
        guard case .failed(let finalReason) = model.phase else {
            Issue.record("expected stopped state to remain stable")
            return
        }
        #expect(finalReason == "Stopped.")
    }

    @Test func runWorkflowIgnoresPersistedDefaultBindings() async {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        let (model, store) = makeModel()
        model.selectedProvider = .openai
        Self.restoreProviderDefault(savedProvider)
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
            Issue.record("expected missing field failure because defaults are not persisted")
            return
        }
        #expect(reason.contains("{{recipient}}"))
    }

    @Test func runWorkflowWithAppNotRunningFails() async {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        let (model, store) = makeModel()
        model.selectedProvider = .openai
        Self.restoreProviderDefault(savedProvider)
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

    // MARK: - propose_workflow bridge

    @Test func confirmWorkflowSurfacesAndSavesOnApproval() async {
        let (model, store) = makeModel()
        model.selectedAppName = "Mail"
        let task = Task { @MainActor in
            await model.confirmWorkflow(WorkflowProposal(
                name: "Weekly report",
                goalTemplate: "Email {{recipient}} the report",
                recipe: "Open Compose first."
            ))
        }

        await Task.yield()
        #expect(model.pendingWorkflow?.name == "Weekly report")
        #expect(model.pendingWorkflow?.goalTemplate == "Email {{recipient}} the report")
        #expect(model.pendingWorkflowNameText == "Weekly report")
        #expect(model.pendingWorkflowGoalText == "Email {{recipient}} the report")
        #expect(model.pendingWorkflowRecipeText == "Open Compose first.")

        model.resolveWorkflow(true)
        let saved = await task.value
        #expect(saved == true)
        #expect(model.pendingWorkflow == nil)
        #expect(model.pendingWorkflowNameText.isEmpty)
        #expect(model.pendingWorkflowGoalText.isEmpty)
        #expect(model.pendingWorkflowRecipeText.isEmpty)

        await waitUntil { !(await store.all().isEmpty) }
        let stored = await store.all().first
        #expect(stored?.name == "Weekly report")
        #expect(stored?.appName == "Mail")
        #expect(stored?.goalTemplate == "Email {{recipient}} the report")
        #expect(stored?.recipe == "Open Compose first.")
        #expect(stored?.variableNames == ["recipient"])
        #expect(stored?.source == .proposed)
    }

    @Test func editedPendingWorkflowProposalIsSavedFromDraftText() async {
        let (model, store) = makeModel()
        model.selectedAppName = "Mail"
        let task = Task { @MainActor in
            await model.confirmWorkflow(WorkflowProposal(
                name: "Weekly report",
                goalTemplate: "Email {{old}}",
                recipe: "Open Compose first."
            ))
        }

        await Task.yield()
        model.pendingWorkflowNameText = "  Morning update  "
        model.pendingWorkflowGoalText = "  Email {{recipient}} about {{topic}}  "
        model.pendingWorkflowRecipeText = "   "

        model.resolveWorkflow(true)
        let saved = await task.value
        #expect(saved == true)

        let stored = await store.all().first
        #expect(stored?.name == "Morning update")
        #expect(stored?.goalTemplate == "Email {{recipient}} about {{topic}}")
        #expect(stored?.recipe == "")
        #expect(stored?.variableNames == ["recipient", "topic"])
        #expect(stored?.variables.allSatisfy { $0.defaultValue == nil } == true)
        #expect(model.savedWorkflows.first?.name == "Morning update")
    }

    @Test func blankPendingWorkflowProposalStaysVisibleAndDoesNotResume() async {
        let (model, store) = makeModel()
        model.selectedAppName = "Mail"
        var result: Bool?
        let task = Task { @MainActor in
            result = await model.confirmWorkflow(WorkflowProposal(
                name: "Suggested",
                goalTemplate: "Do {{thing}}"
            ))
        }

        await Task.yield()
        model.pendingWorkflowNameText = " "

        model.resolveWorkflow(true)
        await Task.yield()

        #expect(result == nil)
        #expect(model.pendingWorkflow != nil)
        #expect(model.pendingWorkflowNameText == " ")
        #expect(model.feed.contains { $0.text.contains("required") && $0.isError })
        #expect(await store.all().isEmpty)

        model.resolveWorkflow(false)
        await task.value
        #expect(result == false)
        #expect(model.pendingWorkflow == nil)
    }

    @Test func duplicatePendingWorkflowProposalStaysVisibleAndDoesNotResume() async {
        let (model, store) = makeModel()
        model.selectedAppName = "Mail"
        await store.add(Workflow(
            name: "Daily",
            appName: "Mail",
            goalTemplate: "Do {{thing}}",
            source: .manual
        ))
        var result: Bool?
        let task = Task { @MainActor in
            result = await model.confirmWorkflow(WorkflowProposal(
                name: "Suggested",
                goalTemplate: "Do {{other}}"
            ))
        }

        await Task.yield()
        model.pendingWorkflowNameText = "daily"

        model.resolveWorkflow(true)
        await waitUntil {
            result != nil || model.feed.contains { $0.text.contains("already exists") }
        }

        #expect(result == nil)
        #expect(model.pendingWorkflow != nil)
        #expect(model.pendingWorkflowNameText == "daily")
        #expect(model.feed.contains { $0.text.contains("already exists") && $0.isError })
        #expect(await store.all().count == 1)

        model.resolveWorkflow(false)
        await task.value
        #expect(result == false)
        #expect(model.pendingWorkflow == nil)
    }

    @Test func confirmWorkflowDeclinedDoesNotSave() async {
        let (model, store) = makeModel()
        model.selectedAppName = "Mail"
        let task = Task { @MainActor in
            await model.confirmWorkflow(WorkflowProposal(name: "X", goalTemplate: "do {{y}}"))
        }

        await Task.yield()
        #expect(model.pendingWorkflow != nil)

        model.resolveWorkflow(false)
        let saved = await task.value
        #expect(saved == false)
        #expect(model.pendingWorkflow == nil)
        #expect(model.pendingWorkflowNameText.isEmpty)
        #expect(model.pendingWorkflowGoalText.isEmpty)
        #expect(model.pendingWorkflowRecipeText.isEmpty)

        // Give any (incorrectly) spawned write a chance to land before asserting.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(await store.all().isEmpty)
    }

    @Test func stopResumesPendingWorkflowAsDeclined() async {
        let (model, store) = makeModel()
        model.selectedAppName = "Mail"
        let task = Task { @MainActor in
            await model.confirmWorkflow(WorkflowProposal(name: "X", goalTemplate: "do {{y}}"))
        }

        await Task.yield()
        #expect(model.pendingWorkflow != nil)

        model.stop()
        let saved = await task.value
        #expect(saved == false)
        #expect(model.pendingWorkflow == nil)
        #expect(model.pendingWorkflowNameText.isEmpty)
        #expect(model.pendingWorkflowGoalText.isEmpty)
        #expect(model.pendingWorkflowRecipeText.isEmpty)

        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(await store.all().isEmpty)
    }

    @Test func updateWorkflowReDerivesVariablesAndPreservesMetadata() async {
        let (model, store) = makeModel()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let updatedAt = Date(timeIntervalSince1970: 2_000)
        let sourceRunID = UUID()
        let workflow = Workflow(
            name: "Original",
            appName: "Mail",
            goalTemplate: "Email {{old}}",
            recipe: "Keep the message short.",
            variables: [WorkflowVariable(name: "old", description: "Old value", defaultValue: "typed value")],
            source: .savedFromRun,
            sourceRunID: sourceRunID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            runCount: 4,
            successCount: 3
        )
        await store.add(workflow)

        model.updateWorkflow(
            id: workflow.id,
            name: "  Edited  ",
            appName: "  Notes  ",
            goalTemplate: "  Send {{recipient}} the {{report}}  "
        )
        await waitUntil {
            await store.get(id: workflow.id)?.name == "Edited"
        }

        let stored = await store.get(id: workflow.id)
        #expect(stored?.id == workflow.id)
        #expect(stored?.name == "Edited")
        #expect(stored?.appName == "Notes")
        #expect(stored?.goalTemplate == "Send {{recipient}} the {{report}}")
        #expect(stored?.recipe == "Keep the message short.")
        #expect(stored?.source == .savedFromRun)
        #expect(stored?.sourceRunID == sourceRunID)
        #expect(stored?.createdAt == createdAt)
        #expect(stored?.updatedAt != updatedAt)
        #expect(stored?.runCount == 4)
        #expect(stored?.successCount == 3)
        #expect(stored?.variableNames == ["recipient", "report"])
        #expect(stored?.variables.allSatisfy { $0.defaultValue == nil } == true)
        #expect(model.savedWorkflows.first?.name == "Edited")
    }

    @Test func duplicateWorkflowUpdateWarnsAndKeepsStoredWorkflow() async {
        let (model, store) = makeModel()
        let existing = Workflow(
            name: "Daily",
            appName: "Mail",
            goalTemplate: "Do daily work",
            source: .manual
        )
        let edited = Workflow(
            name: "Weekly",
            appName: "Mail",
            goalTemplate: "Do weekly work",
            source: .manual
        )
        await store.add(existing)
        await store.add(edited)

        model.updateWorkflow(
            id: edited.id,
            name: "daily",
            appName: "Mail",
            goalTemplate: "Do renamed work"
        )
        await waitUntil {
            model.feed.contains { $0.text.contains("already exists") }
        }

        let stored = await store.get(id: edited.id)
        #expect(model.feed.contains { $0.text.contains("already exists") && $0.isError })
        #expect(stored?.name == "Weekly")
        #expect(stored?.goalTemplate == "Do weekly work")
    }
}
