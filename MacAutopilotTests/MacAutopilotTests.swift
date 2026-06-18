import AutopilotUI
import Foundation
import Testing
@testable import MacAutopilot

@MainActor
@Suite(.serialized)
struct MacAutopilotTests {
    @Test func contentViewConstructs() {
        _ = ContentView()
    }

    @Test func contentViewAndNotchControllerAcceptSharedState() {
        let model = makeModel()
        let auth = AuthModel()
        let subscriptionAuth = SubscriptionAccountAuthModel()

        _ = ContentView(model: model, auth: auth, subscriptionAuth: subscriptionAuth)
        _ = NotchController(model: model, subscriptionAuth: subscriptionAuth)
    }

    @Test func viewModelStartsInAppManagedMode() {
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

        let model = makeModel()
        #expect(model.phase == .idle)
        #expect(model.promptText.isEmpty)
        #expect(model.selectedProvider == .hosted)
        #expect(model.selectedProviderAccessMode == .appManaged)
        #expect(model.selectedProviderDescriptor.displayName == "Mac Autopilot Basic")
        #expect(model.selectedModelDescriptor.identifier == "gemini-3.5-flash")
        #expect(model.selectedModelDescriptor.supportsImageInput)
    }

    @Test func emptySubmitDoesNotStartRun() {
        let model = makeModel()
        model.promptText = "   "
        model.submit()
        #expect(model.phase == .idle)
    }

    @Test func missingAPIKeyFailsBeforeStartingRun() {
        // The default mode is app-managed AI, so select a BYOK provider
        // explicitly before testing the key guard.
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

        let model = makeModel()
        model.selectedProvider = .openai
        model.apiKey = ""
        model.promptText = "Read the selected app"
        model.submit()

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected missing API key failure")
            return
        }
        #expect(reason.contains("API key"))
    }

    private func makeModel() -> AgentViewModel {
        AgentViewModel(
            apiKeyStorage: AgentViewModel.APIKeyStorage(
                load: { _ in "" },
                save: { _, _ in }
            )
        )
    }

}
