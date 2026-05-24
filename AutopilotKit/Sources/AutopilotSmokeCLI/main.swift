import AutopilotAgent
import AutopilotCore
import AutopilotLLM
import AutopilotMac
import AutopilotMemory
import Darwin
import Foundation
import Security

@main
struct AutopilotSmokeCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.contains("--help"), !arguments.contains("-h") else {
            printUsage()
            return
        }

        let target = value(after: "--app", in: arguments) ?? "AutopilotFixtureApp"
        let includeScreenshot = arguments.contains("--include-screenshot")
        let runAgentLoop = arguments.contains("--agent-loop")
        let dumpTree = arguments.contains("--dump-tree")
        let liveProvider = liveProvider(from: arguments)
        let resolution = await MainActor.run {
            AppLocator().resolveRunningApp(matching: target)
        }
        let app: AppLocator.RunningApp
        switch resolution {
        case .matched(let resolved):
            app = resolved
        case .notFound:
            fputs("No running app matched '\(target)'.\n\n", stderr)
            printUsage()
            exit(2)
        case .ambiguous(let apps):
            let names = apps.map(\.name).sorted().joined(separator: ", ")
            fputs("'\(target)' matched more than one running app: \(names).\n\n", stderr)
            printUsage()
            exit(2)
        }

        let computer = MacComputer(
            pid: app.processID,
            appName: app.name,
            bundleIdentifier: app.bundleIdentifier
        )

        let diagnostics = await computer.diagnose()
        printDiagnostics(diagnostics)
        guard diagnostics.isReady else {
            exit(2)
        }

        if dumpTree {
            await dumpAccessibilityTree(computer: computer, includeScreenshot: includeScreenshot)
            exit(0)
        }

        if let liveProvider {
            let passed = await runLiveLLMSmoke(
                computer: computer,
                provider: liveProvider,
                arguments: arguments
            )
            exit(passed ? 0 : 1)
        }

        if runAgentLoop {
            let passed = await runAgentLoopSmoke(
                computer: computer,
                includeScreenshot: includeScreenshot
            )
            exit(passed ? 0 : 1)
        }

        let report = await ComputerUseSmokeRunner().run(
            computer: computer,
            includeScreenshot: includeScreenshot,
            perceptionIdentifiers: .autopilotFixture,
            planForState: { state in
                try ComputerUseSmokePlan.autopilotFixturePlan(
                    for: state.snapshot
                )
            }
        )

        print("")
        print(report.summary)
        for step in report.steps {
            print("- \(step.status.rawValue): \(step.toolName) - \(step.detail)")
        }

        exit(report.passed ? 0 : 1)
    }

    private static func runLiveLLMSmoke(
        computer: MacComputer,
        provider: LiveProvider,
        arguments: [String]
    ) async -> Bool {
        let apiKeyEnvironment = value(after: "--api-key-env", in: arguments)
            ?? provider.defaultAPIKeyEnvironment
        let apiKey = loadAPIKey(
            environment: apiKeyEnvironment,
            keychainAccount: provider.keychainAccount
        )
        guard !apiKey.isEmpty else {
            fflush(stdout)
            fputs(
                """
                Missing API key. Set \(apiKeyEnvironment), pass --api-key-env NAME, or save a key in MacAutopilot first.

                """,
                stderr
            )
            return false
        }

        let model = value(after: "--model", in: arguments) ?? provider.defaultModel
        let task = value(after: "--task", in: arguments) ?? Self.defaultLiveLLMTask
        let maxSteps = value(after: "--max-steps", in: arguments).flatMap(Int.init) ?? 15
        let expectedText = value(after: "--expect-text", in: arguments) ?? "live smoke value"

        print("")
        print("Running live \(provider.displayName) AgentSession smoke loop...")
        print("- model: \(model)")
        print("- api key source: \(apiKeySourceDescription(environment: apiKeyEnvironment, provider: provider))")
        print("- task: \(task)")
        if arguments.contains("--include-screenshot"), !provider.descriptor.supportsImageInput {
            print("- screenshots: disabled because \(provider.displayName) is configured as text-only")
        }

        let recorder = AgentSmokeEventRecorder()
        let session = AgentSession(
            llm: provider.makeProvider(apiKey: apiKey),
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(
                model: model,
                maxSteps: maxSteps,
                highlightDwell: .zero,
                supportsImageInput: provider.descriptor.supportsImageInput
            ),
            memory: smokeMemoryStore(),
            eventHandler: { event in
                recorder.append(event)
                if let line = formatAgentEvent(event) {
                    print(line)
                }
            }
        )

        let outcome = await session.run(task: task)
        let expectationPassed = await stateContains(
            expectedText,
            computer: computer
        )
        let passed = outcome.status == .completed && expectationPassed

        print("")
        print("Live LLM outcome: \(outcome.status) - \(outcome.summary)")
        print(
            expectationPassed
                ? "Expectation passed: final app state contains \"\(expectedText)\"."
                : "Expectation failed: final app state does not contain \"\(expectedText)\"."
        )

        if !passed {
            let performedTools = recorder.performedTools().map(\.rawValue)
            print("Performed tools: \(performedTools.joined(separator: ", "))")
        }

        return passed
    }

    private static let defaultLiveLLMTask = """
    Use the fixture app. Set the Smoke input field to "live smoke value", \
    click Run, then finish with a short summary.
    """

    /// Print the accessibility tree of the target app — the same compact text
    /// the agent reasons over — as a debugging aid for real-world validation.
    private static func dumpAccessibilityTree(
        computer: MacComputer,
        includeScreenshot: Bool
    ) async {
        print("")
        do {
            let state = try await computer.getAppState(includeScreenshot: includeScreenshot)
            print(UITreeRenderer.compactText(state.snapshot))
            if includeScreenshot, let warning = state.screenshotWarning {
                print("")
                print("Screenshot warning: \(warning)")
            }
            if includeScreenshot, let screenshot = state.screenshot {
                print("")
                print("Screenshot: \(screenshot.count) PNG byte(s).")
            }
        } catch {
            fflush(stdout)
            fputs("Could not read \(computer.appName): \(String(describing: error))\n", stderr)
        }
    }

    private static func runAgentLoopSmoke(
        computer: MacComputer,
        includeScreenshot: Bool
    ) async -> Bool {
        let plan: ComputerUseSmokePlan
        do {
            let state = try await computer.getAppState(includeScreenshot: false)
            plan = try ComputerUseSmokePlan.autopilotFixturePlan(
                for: state.snapshot
            )
        } catch {
            fflush(stdout)
            fputs("Could not resolve fixture smoke plan: \(error.localizedDescription)\n", stderr)
            return false
        }

        print("")
        print("Running scripted AgentSession smoke loop...")

        let recorder = AgentSmokeEventRecorder()
        let llm = ScriptedLLMProvider(agentLoopResponses(
            plan: plan,
            includeScreenshot: includeScreenshot
        ))
        let session = AgentSession(
            llm: llm,
            computer: computer,
            interaction: AutomaticApproval(),
            configuration: AgentConfiguration(
                model: "scripted-smoke",
                maxSteps: 12,
                highlightDwell: .zero
            ),
            memory: smokeMemoryStore(),
            eventHandler: { event in
                recorder.append(event)
                if let line = formatAgentEvent(event) {
                    print(line)
                }
            }
        )

        let outcome = await session.run(
            task: "Exercise the computer-use driver surface against the fixture app."
        )

        let expectedTools: [AgentTool] = [
            .listApps,
            .getAppState,
            .click,
            .scroll,
            .setValue,
            .typeText,
            .pressKey,
            .drag,
            .performSecondaryAction
        ]
        let performedTools = recorder.performedTools()
        let passed = outcome.status == .completed && performedTools == expectedTools

        print("")
        print("Agent loop outcome: \(outcome.status) - \(outcome.summary)")
        if !passed {
            print("Expected performed tools: \(expectedTools.map(\.rawValue).joined(separator: ", "))")
            print("Actual performed tools: \(performedTools.map(\.rawValue).joined(separator: ", "))")
        }

        return passed
    }

    private static func agentLoopResponses(
        plan: ComputerUseSmokePlan,
        includeScreenshot: Bool
    ) -> [LLMResponse] {
        var scrollInput: [String: JSONValue] = [
            "direction": .string(plan.scrollDirection.rawValue),
            "amount": .int(plan.scrollAmount)
        ]
        if let scrollElementIndex = plan.scrollElementIndex {
            scrollInput["element_index"] = .int(scrollElementIndex)
        }

        return [
            toolResponse(id: "smoke-1", tool: .listApps, input: [:]),
            toolResponse(
                id: "smoke-2",
                tool: .getAppState,
                input: ["include_screenshot": .bool(includeScreenshot)]
            ),
            toolResponse(
                id: "smoke-3",
                tool: .click,
                input: ["element_index": .int(plan.clickElementIndex)]
            ),
            toolResponse(
                id: "smoke-4",
                tool: .scroll,
                input: .object(scrollInput)
            ),
            toolResponse(
                id: "smoke-5",
                tool: .setValue,
                input: [
                    "element_index": .int(plan.textElementIndex),
                    "value": .string(plan.setValue)
                ]
            ),
            toolResponse(
                id: "smoke-6",
                tool: .typeText,
                input: [
                    "element_index": .int(plan.textElementIndex),
                    "text": .string(plan.typeText)
                ]
            ),
            toolResponse(
                id: "smoke-7",
                tool: .pressKey,
                input: [
                    "key": .string(plan.keyPress.key),
                    "modifiers": .array(plan.keyPress.modifiers.map { .string($0.rawValue) })
                ]
            ),
            toolResponse(
                id: "smoke-8",
                tool: .drag,
                input: [
                    "from_element_index": .int(plan.dragFromElementIndex),
                    "to_element_index": .int(plan.dragToElementIndex)
                ]
            ),
            toolResponse(
                id: "smoke-9",
                tool: .performSecondaryAction,
                input: [
                    "element_index": .int(plan.secondaryElementIndex),
                    "action": .string(plan.secondaryAction)
                ]
            ),
            toolResponse(
                id: "smoke-10",
                tool: .done,
                input: ["summary": "Agent smoke loop completed."]
            )
        ]
    }

    private static func toolResponse(
        id: String,
        tool: AgentTool,
        input: JSONValue
    ) -> LLMResponse {
        LLMResponse(
            content: [.toolUse(ToolUse(
                id: id,
                name: tool.rawValue,
                input: input
            ))],
            stopReason: .toolUse,
            usage: .init(inputTokens: 1, outputTokens: 1)
        )
    }

    private static func stateContains(
        _ expectedText: String,
        computer: MacComputer
    ) async -> Bool {
        guard !expectedText.isEmpty else { return true }
        do {
            let state = try await computer.getAppState(includeScreenshot: false)
            return state.snapshot.root.flattened.contains { element in
                element.label?.contains(expectedText) == true
                    || element.value?.contains(expectedText) == true
            }
        } catch {
            return false
        }
    }

    /// A throwaway memory store in a temp directory, so smoke runs never touch
    /// the real Application Support memory file.
    private static func smokeMemoryStore() -> MemoryStore {
        MemoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-smoke-\(UUID().uuidString)", isDirectory: true))
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }

    private static func liveProvider(from arguments: [String]) -> LiveProvider? {
        guard arguments.contains("--live-provider") else { return nil }
        guard
            let raw = value(after: "--live-provider", in: arguments),
            let provider = LiveProvider(rawValue: raw)
        else {
            fflush(stdout)
            fputs("Invalid --live-provider. Use zai or anthropic.\n\n", stderr)
            printUsage()
            exit(2)
        }
        return provider
    }

    private static func loadAPIKey(
        environment: String,
        keychainAccount: String
    ) -> String {
        if let value = ProcessInfo.processInfo.environment[environment],
           !value.isEmpty {
            return value
        }
        return (try? SmokeAPIKeyStore.load(account: keychainAccount)) ?? ""
    }

    private static func apiKeySourceDescription(
        environment: String,
        provider: LiveProvider
    ) -> String {
        if ProcessInfo.processInfo.environment[environment]?.isEmpty == false {
            return "environment \(environment)"
        }
        return "Keychain account \(provider.keychainAccount)"
    }

    private static func printDiagnostics(_ diagnostics: ComputerDiagnostics) {
        print(diagnostics.summary)
        for check in diagnostics.checks {
            var line = "- \(check.status.rawValue): \(check.title) - \(check.detail)"
            if let recovery = check.recovery, !recovery.isEmpty {
                line += " \(recovery)"
            }
            print(line)
        }
    }

    private static func printUsage() {
        print("""
        Usage:
          swift run --package-path AutopilotKit AutopilotFixtureApp
          swift run --package-path AutopilotKit AutopilotSmokeCLI [--app AutopilotFixtureApp] [--include-screenshot] [--agent-loop]
          swift run --package-path AutopilotKit AutopilotSmokeCLI --app Safari --dump-tree
          swift run --package-path AutopilotKit AutopilotSmokeCLI --live-provider zai [--api-key-env ZAI_API_KEY] [--model glm-4.7-flash] [--task "…"] [--expect-text "live smoke value"] [--max-steps 15]

        --dump-tree prints the accessibility tree the agent would see for any
        running app, after the readiness checks pass.

        The fixture app must be running and the smoke runner process must have
        Accessibility permission in System Settings > Privacy & Security.
        Live provider mode reads the API key from the selected environment
        variable first, then falls back to MacAutopilot's Keychain entry.
        """)
    }

}

private enum LiveProvider: String {
    case zai
    case anthropic

    var descriptor: LLMProviderDescriptor {
        switch self {
        case .zai: .zai
        case .anthropic: .anthropic
        }
    }

    var displayName: String {
        descriptor.displayName
    }

    var defaultModel: String {
        descriptor.defaultModel
    }

    var defaultAPIKeyEnvironment: String {
        descriptor.apiKeyEnvironment
    }

    var keychainAccount: String {
        descriptor.keychainAccount
    }

    func makeProvider(apiKey: String) -> any LLMProvider {
        switch self {
        case .zai:
            ZAIProvider(apiKey: apiKey)
        case .anthropic:
            AnthropicProvider(apiKey: apiKey)
        }
    }
}

private enum SmokeAPIKeyStore {
    private static let service = "com.langqi.MacAutopilot.llm-api-keys"

    static func load(account: String) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class AgentSmokeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func performedTools() -> [AgentTool] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { event in
            if case .performed(let tool, _) = event {
                return tool
            }
            return nil
        }
    }
}

private func formatAgentEvent(_ event: AgentEvent) -> String? {
    switch event {
    case .started(let task):
        return "- started: \(task)"
    case .prepared(let summary):
        return "- prepared: \(summary)"
    case .diagnostics(let diagnostics):
        return "- diagnostics: \(diagnostics.summary)"
    case .thinking:
        return "- thinking"
    case .observedTree(let elementCount):
        return "- observed_tree: \(elementCount) element(s)"
    case .tokenUsage(let inputTokens, let outputTokens):
        return "- token_usage: \(inputTokens) in / \(outputTokens) out"
    case .message(let message):
        return "- message: \(message)"
    case .memoryRecalled(let items):
        return "- memory_recalled: \(items.count) item(s)"
    case .willPerform(let tool, let target, let tier):
        return "- will_perform: \(tool.rawValue) - \(target.description) (\(tier.rawValue))"
    case .awaitingConfirmation(let request):
        return "- awaiting_confirmation: \(request.summary) (\(request.tier.rawValue))"
    case .confirmationDenied(let summary):
        return "- confirmation_denied: \(summary)"
    case .performed(let tool, let summary):
        return "- performed: \(tool.rawValue) - \(summary)"
    case .actionFailed(let tool, let reason):
        return "- action_failed: \(tool.rawValue) - \(reason)"
    case .askedUser(let question, _):
        return "- asked_user: \(question) -> answered"
    case .memoryProposed(let proposal):
        return "- memory_proposed: \(proposal.text)"
    case .memoryStored(let item):
        return "- memory_stored: \(item.text)"
    case .storageFailed(let message):
        return "- storage_failed: \(message)"
    case .finished(let summary):
        return "- finished: \(summary)"
    case .failed(let reason):
        return "- failed: \(reason)"
    case .stopped:
        return "- stopped"
    }
}
