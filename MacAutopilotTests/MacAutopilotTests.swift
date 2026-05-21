import AutopilotUI
import Testing
@testable import MacAutopilot

@MainActor
struct MacAutopilotTests {
    @Test func contentViewConstructs() {
        _ = ContentView()
    }

    @Test func viewModelStartsInLocalBYOKMode() {
        let model = AgentViewModel()
        #expect(model.phase == .idle)
        #expect(model.promptText.isEmpty)
        #expect(model.selectedProvider == .zai)
        #expect(model.selectedProviderDescriptor.keychainAccount == "AutopilotZAIAPIKey")
        #expect(!model.selectedProviderDescriptor.supportsImageInput)
    }

    @Test func emptySubmitDoesNotStartRun() {
        let model = AgentViewModel()
        model.promptText = "   "
        model.submit()
        #expect(model.phase == .idle)
    }

    @Test func missingAPIKeyFailsBeforeStartingRun() {
        let model = AgentViewModel()
        model.apiKey = ""
        model.promptText = "Read the selected app"
        model.submit()

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected missing API key failure")
            return
        }
        #expect(reason.contains("API key"))
    }
}
