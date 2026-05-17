import AutopilotUI
import SwiftUI

/// A minimal test harness for the agent: pick a running app, type a task, and
/// watch the live feed. The notch UI replaces this once the engine is proven.
struct ContentView: View {
    @State private var model = AgentViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac Autopilot")
                .font(.title3.weight(.semibold))
            Text("Test harness — pick an app, give the agent a task, watch it run.")
                .font(.caption)
                .foregroundStyle(.secondary)

            permissionsView

            HStack {
                Picker("Model", selection: $model.selectedProvider) {
                    ForEach(AgentViewModel.Provider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .frame(maxWidth: 220)

                SecureField(model.apiKeyPlaceholder, text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Picker("Target app", selection: $model.selectedAppName) {
                    ForEach(model.runningAppNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Button("Refresh") { model.refreshApps() }
            }

            HStack {
                TextField("What should I do?  (or \"remember: …\")", text: $model.promptText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submit() }
                runButton
            }

            if let approval = model.pendingApproval {
                approvalRow(approval)
            }

            if let memory = model.pendingMemory {
                memoryRow(memory)
            }

            if let question = model.pendingQuestion {
                questionRow(question)
            }

            phaseLine

            if let usage = model.tokenUsageText {
                Text("Tokens — \(usage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.feed.isEmpty {
                feedView
            }

            trustView

            memoryView

            Spacer(minLength: 0)
        }
        .padding()
        .frame(width: 480)
        .frame(minHeight: 440, alignment: .top)
        .onAppear {
            model.refreshApps()
            model.refreshPermissions()
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
        if model.phase == .running {
            Button("Stop", role: .destructive) { model.stop() }
        } else {
            Button("Run") { model.submit() }
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
        case .finished(let summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var feedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
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
        .frame(maxHeight: 220)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var memoryView: some View {
        DisclosureGroup("Memory (\(model.storedMemories.count))") {
            VStack(alignment: .leading, spacing: 6) {
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
