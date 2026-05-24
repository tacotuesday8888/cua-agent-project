import AutopilotUI
import Foundation
import Testing
@testable import MacAutopilot

@MainActor
struct MacAutopilotTests {
    @Test func contentViewConstructs() {
        _ = ContentView()
    }

    @Test func viewModelStartsInLocalBYOKMode() {
        // The selected provider is persisted in UserDefaults; clear it so this
        // tests the true default, then restore any real saved value afterward.
        let providerKey = "AutopilotLLMProvider"
        let savedProvider = UserDefaults.standard.string(forKey: providerKey)
        UserDefaults.standard.removeObject(forKey: providerKey)
        defer {
            if let savedProvider {
                UserDefaults.standard.set(savedProvider, forKey: providerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: providerKey)
            }
        }

        let model = AgentViewModel()
        #expect(model.phase == .idle)
        #expect(model.promptText.isEmpty)
        // GPT-5.4 Mini is the default primary provider — a local BYOK, vision-capable model.
        #expect(model.selectedProvider == .openai)
        #expect(model.selectedProviderDescriptor.keychainAccount == "AutopilotOpenAIAPIKey")
        #expect(model.selectedProviderDescriptor.supportsImageInput)
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
