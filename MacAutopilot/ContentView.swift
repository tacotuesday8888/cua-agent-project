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
                TextField("What should I do?", text: $model.promptText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submit() }
                runButton
            }

            if let approval = model.pendingApproval {
                approvalRow(approval)
            }

            phaseLine

            if !model.feed.isEmpty {
                feedView
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(width: 480)
        .frame(minHeight: 380, alignment: .top)
        .onAppear { model.refreshApps() }
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
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(approval.summary)
                .font(.callout)
            Spacer()
            Button("Skip") { model.resolveApproval(false) }
            Button("Approve") { model.resolveApproval(true) }
                .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
        }
        .frame(maxHeight: 220)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    ContentView()
}
