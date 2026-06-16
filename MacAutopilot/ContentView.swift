import AppKit
import AutopilotHistory
import AutopilotUI
import AutopilotWorkflows
import SwiftUI

/// The primary Mac Autopilot control center: setup, one-app runs, approvals,
/// saved workflows, local memory, trust, and recent run history.
struct ContentView: View {
    @Bindable private var model: AgentViewModel
    @Bindable private var auth: AuthModel
    @Bindable private var subscriptionAuth: SubscriptionAccountAuthModel
    @State private var newWorkflowName = ""
    @State private var newWorkflowGoal = ""
    @State private var editingWorkflowID: UUID?
    @State private var editWorkflowName = ""
    @State private var editWorkflowAppName = ""
    @State private var editWorkflowGoal = ""
    @State private var workflowBindings: [UUID: [String: String]] = [:]

    init(
        model: AgentViewModel = AgentViewModel(),
        auth: AuthModel = AuthModel(),
        subscriptionAuth: SubscriptionAccountAuthModel = SubscriptionAccountAuthModel()
    ) {
        self.model = model
        self.auth = auth
        self.subscriptionAuth = subscriptionAuth
    }

    /// Sign-in controls shown in place of the API-key field for hosted AI.
    @ViewBuilder
    private var hostedAccountControls: some View {
        if let email = auth.email {
            HStack(spacing: 8) {
                Text("Signed in as \(email)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Sign out") { auth.signOut() }
            }
        } else {
            Button("Sign in with Google") {
                Task {
                    guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
                    await auth.signIn(presenting: window)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                setupColumn
                    .frame(width: 280)
                runColumn
                    .frame(minWidth: 360, maxWidth: .infinity)
                libraryColumn
                    .frame(width: 310)
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 620, alignment: .top)
        .onAppear {
            model.refreshApps()
            model.refreshPermissions()
            model.hostedTokenProvider = hostedFirebaseToken
            model.hostedAccountStatusProvider = {
                AgentViewModel.HostedAccountStatus(
                    email: auth.email,
                    statusMessage: auth.statusMessage
                )
            }
            wireSubscriptionAccountStatus()
            auth.refresh()
            refreshSubscriptionAccountIfNeeded()
        }
        .onChange(of: model.selectedProvider) { _, _ in
            refreshSubscriptionAccountIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
            auth.refresh()
            refreshSubscriptionAccountIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Autopilot Control Center")
                    .font(.title3.weight(.semibold))
                Text("One target app, one live AI workflow, local approvals and storage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            runStateBadge
        }
    }

    private var setupColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                permissionsView
                aiAccessView
                localPrivacyView
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var runColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            runPanel
            pendingInteractionView
            phaseLine
            if let usage = model.tokenUsageText {
                Text("Tokens — \(usage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            feedView
            Spacer(minLength: 0)
        }
    }

    private var libraryColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                workflowsView
                historyView
                memoryView
                trustView
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var runPanel: some View {
        GroupBox("Run") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Target app", selection: $model.selectedAppName) {
                        ForEach(model.runningAppNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    Button("Refresh") { model.refreshApps() }
                        .controlSize(.small)
                }

                TextField("Goal for one app, or use @App / remember: …", text: $model.promptText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submit() }

                HStack {
                    Text("Saved workflows are adaptive goals, not recorded clicks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    runButton
                }
            }
        }
    }

    @ViewBuilder
    private var pendingInteractionView: some View {
        if let approval = model.pendingApproval {
            approvalRow(approval)
        }

        if let memory = model.pendingMemory {
            memoryRow(memory)
        }

        if let workflow = model.pendingWorkflow {
            workflowProposalRow(workflow)
        }

        if let question = model.pendingQuestion {
            questionRow(question)
        }
    }

    private var runStateBadge: some View {
        HStack(spacing: 6) {
            statusDot
            Text(runStateText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private var statusDot: some View {
        Circle()
            .fill(runStateColor)
            .frame(width: 7, height: 7)
    }

    private var runStateText: String {
        switch model.phase {
        case .idle: "Ready"
        case .running: "Running"
        case .stopping: "Stopping"
        case .finished: "Finished"
        case .failed: "Needs attention"
        }
    }

    private var runStateColor: Color {
        switch model.phase {
        case .idle: .secondary
        case .running: .blue
        case .stopping: .orange
        case .finished: .green
        case .failed: .red
        }
    }

    private var aiAccessView: some View {
        GroupBox("AI Access") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Mode", selection: $model.selectedProvider) {
                        ForEach(AgentViewModel.Provider.allCases) { provider in
                            Text("\(provider.displayName) · \(provider.accessMode.displayName)")
                                .tag(provider)
                        }
                    }
                    .frame(maxWidth: 260)

                    providerCredentialControls
                }

                Text(accessModeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.selectedProvider == .openAICompatible {
                    openAICompatibleControls
                } else {
                    HStack {
                        if model.availableModelDescriptors.count > 1 {
                            Picker("Model", selection: $model.selectedModelID) {
                                ForEach(model.availableModelDescriptors) { option in
                                    Text(option.displayName).tag(option.identifier)
                                }
                            }
                            .frame(maxWidth: 260)
                        } else {
                            LabeledContent("Model") {
                                Text(model.selectedModelDescriptor.displayName)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        capabilityBadges
                    }
                }

                providerStatusText

                existingAccountAccessStatus
            }
        }
    }

    @ViewBuilder
    private var providerCredentialControls: some View {
        if model.selectedProviderUsesAPIKey {
            SecureField(model.apiKeyPlaceholder, text: $model.apiKey)
                .textFieldStyle(.roundedBorder)
        } else if model.selectedSubscriptionAccountRequirement != nil {
            subscriptionAccountControls
        } else {
            hostedAccountControls
        }
    }

    @ViewBuilder
    private var subscriptionAccountControls: some View {
        if let requirement = model.selectedSubscriptionAccountRequirement {
            let state = subscriptionAuth.state(for: requirement.providerID)
            if state.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(requirement.providerName)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if state.isSignedIn {
                HStack(spacing: 8) {
                    Text("Signed in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Sign out") {
                        Task { await subscriptionAuth.signOut(provider: requirement.providerID) }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button("Sign in") {
                        Task { await subscriptionAuth.signIn(provider: requirement.providerID) }
                    }
                    Button("Check") {
                        Task { await subscriptionAuth.refresh(provider: requirement.providerID) }
                    }
                }
            }
        }
    }

    private var openAICompatibleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "Provider",
                selection: Binding(
                    get: { model.openAICompatiblePresetID },
                    set: { model.applyOpenAICompatiblePreset(id: $0) }
                )
            ) {
                ForEach(AgentViewModel.openAICompatiblePresets) { preset in
                    Text(preset.displayName).tag(preset.id)
                }
            }
            .frame(maxWidth: 280)

            LabeledContent("Endpoint") {
                TextField(
                    "http://localhost:11434/v1/chat/completions",
                    text: $model.openAICompatibleEndpoint
                )
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                LabeledContent("Model ID") {
                    TextField("model-name", text: $model.selectedModelID)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("Images", isOn: $model.openAICompatibleSupportsImageInput)
                    .toggleStyle(.checkbox)

                capabilityBadges
            }
        }
    }

    private var accessModeSummary: String {
        switch model.selectedProviderAccessMode {
        case .appManaged:
            "Default hosted AI · Google sign-in · no API key"
        case .bringYourOwnKey:
            "Advanced · uses your provider account"
        case .existingSubscription:
            "Account connection · supported providers only"
        }
    }

    private var capabilityBadges: some View {
        HStack(spacing: 6) {
            capabilityBadge("Tools", enabled: model.selectedModelDescriptor.supportsToolCalls)
            capabilityBadge("Images", enabled: model.selectedModelDescriptor.supportsImageInput)
            if model.selectedModelDescriptor.supportsPromptCaching {
                capabilityBadge("Prompt cache", enabled: true)
            }
        }
        .font(.caption)
    }

    private func capabilityBadge(_ title: String, enabled: Bool) -> some View {
        Text(title)
            .foregroundStyle(enabled ? .primary : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (enabled ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)),
                in: Capsule()
            )
    }

    @ViewBuilder
    private var providerStatusText: some View {
        if let requirement = model.selectedSubscriptionAccountRequirement {
            Text(requirement.setupSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = subscriptionAuth.state(for: requirement.providerID).statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.localizedCaseInsensitiveContains("failed") ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !model.selectedProviderUsesAPIKey, let status = auth.statusMessage {
            Text(status)
                .font(.caption)
                .foregroundStyle(.red)
        } else if model.selectedProviderUsesAPIKey {
            Text("API keys are stored in Keychain on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshSubscriptionAccountIfNeeded() {
        guard let requirement = model.selectedSubscriptionAccountRequirement else { return }
        Task { await subscriptionAuth.refresh(provider: requirement.providerID) }
    }

    private func wireSubscriptionAccountStatus() {
        let subscriptionAuth = subscriptionAuth
        model.subscriptionAccountSignedInProvider = { provider in
            guard let state = subscriptionAuth.knownState(for: provider), !state.isBusy else {
                return nil
            }
            return state.isSignedIn
        }
    }

    private var existingAccountAccessStatus: some View {
        let status = model.existingAccountAccessStatus
        return VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                Text(status.accessMode.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(status.isAvailable ? "Available" : "Unavailable")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(status.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(status.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var permissionsView: some View {
        if !model.accessibilityTrusted || !model.screenRecordingTrusted {
            VStack(alignment: .leading, spacing: 6) {
                if !model.accessibilityTrusted {
                    permissionRow(
                        message: "Accessibility access is required to read and control apps.",
                        grant: { model.requestAccessibility() },
                        openSettings: { model.openAccessibilitySettings() }
                    )
                }
                if !model.screenRecordingTrusted {
                    permissionRow(
                        message: "Screen Recording is optional — it backs screenshot fallback.",
                        grant: { model.requestScreenRecording() },
                        openSettings: { model.openScreenRecordingSettings() }
                    )
                }
                Button("Re-check permissions") { model.refreshPermissions() }
                    .controlSize(.small)
            }
            .padding(8)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func permissionRow(
        message: String,
        grant: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer(minLength: 4)
            Button("Grant", action: grant)
                .controlSize(.small)
            Button("Settings", action: openSettings)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var runButton: some View {
        switch model.phase {
        case .running:
            Button("Stop", role: .destructive) { model.stop() }
        case .stopping:
            Button("Stopping…") {}
                .disabled(true)
        case .idle, .finished, .failed:
            Button("Run") { model.submit() }
                .disabled(model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func approvalRow(_ approval: AgentViewModel.PendingApproval) -> some View {
        let accent: Color = approval.isDestructive ? .red : .orange
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: approval.isDestructive
                    ? "exclamationmark.octagon.fill"
                    : "exclamationmark.triangle.fill")
                    .foregroundStyle(accent)
                Text(approval.summary)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(approval.tier.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(accent)
            }
            Text(approval.isDestructive
                ? "Destructive — this always needs your approval."
                : "First write to \(approval.appName) this session.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Skip") { model.resolveApproval(false) }
                Button("Approve") { model.resolveApproval(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func memoryRow(_ memory: AgentViewModel.PendingMemory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "brain")
                    .foregroundStyle(.purple)
                Text("Remember this?")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(memory.scopeLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.purple)
            }
            Text(memory.text)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Skip") { model.resolveMemory(false) }
                Button("Remember") { model.resolveMemory(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func workflowProposalRow(_ workflow: AgentViewModel.PendingWorkflow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.teal)
                Text("Save adaptive workflow?")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("LOCAL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.teal)
            }
            TextField("Workflow name", text: $model.pendingWorkflowNameText)
                .textFieldStyle(.roundedBorder)
            TextField("Goal template with {{slot}} variables", text: $model.pendingWorkflowGoalText)
                .textFieldStyle(.roundedBorder)
            if !workflow.recipe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TextField("Recipe hints (optional, saved locally)", text: $model.pendingWorkflowRecipeText)
                    .textFieldStyle(.roundedBorder)
                Text("Keep recipe hints secret-free; typed slot values are not saved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Skip") { model.resolveWorkflow(false) }
                Button("Save") { model.resolveWorkflow(true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSavePendingWorkflow)
            }
        }
        .padding(8)
        .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func questionRow(_ question: AgentViewModel.PendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(question.text, systemImage: "questionmark.bubble.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.blue)
            HStack {
                TextField("Answer", text: $model.questionAnswerText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.resolveQuestion(model.questionAnswerText) }
                Button("Skip") { model.resolveQuestion("") }
                Button("Send") { model.resolveQuestion(model.questionAnswerText) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.questionAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var phaseLine: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running…").foregroundStyle(.secondary)
            }
        case .stopping:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Stopping…").foregroundStyle(.secondary)
            }
        case .finished(let summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var feedView: some View {
        GroupBox("Live Run") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.feed.isEmpty {
                        Text("Run events, approvals, and verification notes appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.feed) { item in
                        Text(item.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(item.isError ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .textSelection(.enabled)
            }
            .frame(minHeight: 180, maxHeight: .infinity)
        }
    }

    private var localPrivacyView: some View {
        GroupBox("Local Data & Privacy") {
            VStack(alignment: .leading, spacing: 6) {
                Label("Keys and account tokens stay in Keychain.", systemImage: "key.fill")
                Label("History stores redacted metadata, not prompts or responses.", systemImage: "clock.arrow.circlepath")
                Label("Workflow slot values are used for one run and not saved.", systemImage: "lock.doc")
                Label("Hosted Basic stores usage metadata only on the backend.", systemImage: "cloud")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var historyView: some View {
        DisclosureGroup("Recent runs (\(model.recentRuns.count))") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Redacted local history")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.clearHistory() }
                        .controlSize(.small)
                        .disabled(model.recentRuns.isEmpty)
                }
                if model.recentRuns.isEmpty {
                    Text("Finished runs appear here without raw prompts, screens, or model responses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.recentRuns.prefix(8)) { run in
                    runHistoryRow(run)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }

    private func runHistoryRow(_ run: RunRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: historyIcon(for: run.status))
                .foregroundStyle(historyColor(for: run.status))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.task)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(run.summary) · \(run.model) · \(run.actionCount) actions · \(run.compactTokens) tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func historyIcon(for status: RunStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func historyColor(for status: RunStatus) -> Color {
        switch status {
        case .completed: .green
        case .stopped: .orange
        case .failed: .red
        }
    }

    private var memoryView: some View {
        DisclosureGroup("Memory (\(model.storedMemories.count))") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Local memory")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear All") { model.clearMemories() }
                        .controlSize(.small)
                        .disabled(model.storedMemories.isEmpty)
                }
                if model.storedMemories.isEmpty {
                    Text("Nothing remembered yet. Say \"remember: …\" or approve a suggestion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.storedMemories) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.text)
                                .font(.caption)
                            Text("\(item.scopeLabel) · \(item.source)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") { model.deleteMemory(id: item.id) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }

    private var workflowsView: some View {
        DisclosureGroup("Workflows (\(model.savedWorkflows.count))") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Workflow name", text: $newWorkflowName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Goal — use {{slot}} for fill-ins", text: $newWorkflowGoal)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text(model.selectedAppName.isEmpty
                            ? "Pick a target app"
                            : "App · \(model.selectedAppName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Create") {
                            model.createWorkflow(
                                name: newWorkflowName,
                                appName: model.selectedAppName,
                                goalTemplate: newWorkflowGoal
                            )
                            newWorkflowName = ""
                            newWorkflowGoal = ""
                        }
                        .controlSize(.small)
                        .disabled(!canCreateWorkflow)
                    }
                }
                if model.savedWorkflows.isEmpty {
                    Text("No workflows yet. Create one above, or approve an agent proposal after a run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.savedWorkflows) { workflow in
                    VStack(alignment: .leading, spacing: 4) {
                        if editingWorkflowID == workflow.id {
                            workflowEditForm(workflow)
                        } else {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(workflow.name)
                                        .font(.caption.weight(.medium))
                                    Text(workflowDetail(workflow))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Run") {
                                    let bindings = workflowBindings[workflow.id] ?? [:]
                                    model.runWorkflow(id: workflow.id, bindings: bindings)
                                    workflowBindings[workflow.id] = [:]
                                }
                                .controlSize(.small)
                                .disabled(model.isRunInProgress)
                                Button("Edit") {
                                    beginEditing(workflow)
                                }
                                .controlSize(.small)
                                Button("Delete") {
                                    workflowBindings[workflow.id] = nil
                                    model.deleteWorkflow(id: workflow.id)
                                }
                                .controlSize(.small)
                            }
                            ForEach(workflow.variables) { variable in
                                TextField(
                                    placeholder(for: variable),
                                    text: workflowBinding(workflowID: workflow.id, variable: variable)
                                )
                                .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .onAppear {
                        seedWorkflowDefaults(workflow)
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }

    private func workflowEditForm(_ workflow: AgentViewModel.StoredWorkflow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("Workflow name", text: $editWorkflowName)
                .textFieldStyle(.roundedBorder)
            TextField("Target app", text: $editWorkflowAppName)
                .textFieldStyle(.roundedBorder)
            TextField("Goal template with {{slot}} variables", text: $editWorkflowGoal)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { clearWorkflowEdit() }
                Button("Save") {
                    workflowBindings[workflow.id] = nil
                    model.updateWorkflow(
                        id: workflow.id,
                        name: editWorkflowName,
                        appName: editWorkflowAppName,
                        goalTemplate: editWorkflowGoal
                    )
                    clearWorkflowEdit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveWorkflowEdit)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func workflowBinding(
        workflowID: UUID,
        variable: WorkflowVariable
    ) -> Binding<String> {
        Binding(
            get: {
                workflowBindings[workflowID]?[variable.name]
                    ?? variable.defaultValue
                    ?? ""
            },
            set: { value in
                var bindings = workflowBindings[workflowID] ?? [:]
                bindings[variable.name] = value
                workflowBindings[workflowID] = bindings
            }
        )
    }

    private func seedWorkflowDefaults(_ workflow: AgentViewModel.StoredWorkflow) {
        var bindings = workflowBindings[workflow.id] ?? [:]
        for variable in workflow.variables where bindings[variable.name] == nil {
            bindings[variable.name] = variable.defaultValue ?? ""
        }
        workflowBindings[workflow.id] = bindings
    }

    private func placeholder(for variable: WorkflowVariable) -> String {
        variable.description.isEmpty ? variable.name : variable.description
    }

    private func workflowDetail(_ workflow: AgentViewModel.StoredWorkflow) -> String {
        workflow.runCount > 0
            ? "\(workflow.appName) · \(workflow.successCount)/\(workflow.runCount) ok"
            : workflow.appName
    }

    private func beginEditing(_ workflow: AgentViewModel.StoredWorkflow) {
        editingWorkflowID = workflow.id
        editWorkflowName = workflow.name
        editWorkflowAppName = workflow.appName
        editWorkflowGoal = workflow.goalTemplate
    }

    private func clearWorkflowEdit() {
        editingWorkflowID = nil
        editWorkflowName = ""
        editWorkflowAppName = ""
        editWorkflowGoal = ""
    }

    private var canCreateWorkflow: Bool {
        !newWorkflowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newWorkflowGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.selectedAppName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSaveWorkflowEdit: Bool {
        !editWorkflowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !editWorkflowAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !editWorkflowGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSavePendingWorkflow: Bool {
        !model.pendingWorkflowNameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.pendingWorkflowGoalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var trustView: some View {
        DisclosureGroup("Trusted apps (\(model.permanentlyTrustedApps.count))") {
            VStack(alignment: .leading, spacing: 4) {
                if model.permanentlyTrustedApps.isEmpty {
                    Text("No apps trusted permanently. Writes ask once per session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.permanentlyTrustedApps, id: \.self) { app in
                    HStack {
                        Text(app).font(.caption)
                        Spacer()
                        Button("Revoke") { model.revokePermanentTrust(app: app) }
                            .controlSize(.small)
                    }
                }
                if !model.selectedAppName.isEmpty,
                   !model.isPermanentlyTrusted(model.selectedAppName) {
                    Button("Trust \(model.selectedAppName) permanently") {
                        model.grantPermanentTrust(app: model.selectedAppName)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }
}

#Preview {
    ContentView()
}
