import AppKit
import AutopilotHistory
import AutopilotCore
import AutopilotWorkflows
import SwiftUI

/// Placeholder notch-resident assistant surface.
///
/// This is intentionally simple: the shape, motion, and visual language are
/// expected to be replaced by the final designer-owned UI, while the data flow
/// and interaction contracts stay in place.
public struct NotchAssistantView: View {
    public static let expandedWidth: CGFloat = 460
    public static let expandedHeight: CGFloat = 488

    @Bindable private var model: AgentViewModel
    private let onExpansionChange: @MainActor (Bool) -> Void
    private let onHighlightChange: @MainActor (ActionTarget?) -> Void

    public init(
        model: AgentViewModel,
        onExpansionChange: @escaping @MainActor (Bool) -> Void = { _ in },
        onHighlightChange: @escaping @MainActor (ActionTarget?) -> Void = { _ in }
    ) {
        self.model = model
        self.onExpansionChange = onExpansionChange
        self.onHighlightChange = onHighlightChange
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if model.isExpanded {
                expandedPanel
            }
        }
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: model.isExpanded ? 18 : 14, style: .continuous)
                .fill(.black.opacity(0.94))
                .shadow(color: .black.opacity(model.isExpanded ? 0.35 : 0.18), radius: 18, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: model.isExpanded ? 18 : 14, style: .continuous)
                .stroke(.white.opacity(model.isExpanded ? 0.12 : 0.06), lineWidth: 1)
        )
        .animation(.snappy(duration: 0.22), value: model.isExpanded)
        .onAppear {
            model.refreshApps()
            model.refreshPermissions()
            onExpansionChange(model.isExpanded)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .onChange(of: model.isExpanded) { _, expanded in
            onExpansionChange(expanded)
        }
        .onChange(of: model.highlightedTarget) { _, target in
            onHighlightChange(target)
        }
        .onChange(of: model.pendingApproval?.id) { _, id in
            if id != nil { expand() }
        }
        .onChange(of: model.pendingMemory?.id) { _, id in
            if id != nil { expand() }
        }
        .onChange(of: model.pendingWorkflow?.id) { _, id in
            if id != nil { expand() }
        }
        .onChange(of: model.pendingQuestion?.id) { _, id in
            if id != nil { expand() }
        }
        .accessibilityIdentifier("notch-assistant")
    }

    private var header: some View {
        Button {
            setExpanded(!model.isExpanded)
        } label: {
            HStack(spacing: 8) {
                statusGlyph
                Text(headerTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if model.phase == .running {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isExpanded ? "Collapse Autopilot" : "Open Autopilot")
    }

    private var expandedPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                permissionBanner
                controls
                promptRow
                pendingInteraction
                phaseLine
                feed
                recentRunsSection
                WorkflowsPanel(model: model)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    /// Shown when Accessibility is missing — without it no task can run.
    @ViewBuilder
    private var permissionBanner: some View {
        if !model.accessibilityTrusted {
            Button {
                model.requestAccessibility()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("Grant Accessibility access to run tasks")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(8)
                .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Model", selection: $model.selectedProvider) {
                ForEach(AgentViewModel.Provider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
            .frame(width: 170)

            Picker("Target", selection: $model.selectedAppName) {
                ForEach(model.runningAppNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Button {
                model.refreshApps()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh apps")
        }
        .controlSize(.small)
    }

    private var promptRow: some View {
        VStack(spacing: 8) {
            if model.selectedProviderRequiresAPIKey, model.apiKey.isEmpty {
                SecureField(model.apiKeyPlaceholder, text: $model.apiKey)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                TextField("What should I do?", text: $model.promptText)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { submit() }

                if model.phase == .running {
                    Button {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Stop")
                } else {
                    Button {
                        submit()
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Run")
                }
            }
        }
    }

    @ViewBuilder
    private var pendingInteraction: some View {
        if let approval = model.pendingApproval {
            approvalRow(approval)
        } else if let question = model.pendingQuestion {
            questionRow(question)
        } else if let memory = model.pendingMemory {
            memoryRow(memory)
        } else if let workflow = model.pendingWorkflow {
            workflowRow(workflow)
        }
    }

    private func approvalRow(_ approval: AgentViewModel.PendingApproval) -> some View {
        let accent: Color = approval.isDestructive ? .red : .orange
        return VStack(alignment: .leading, spacing: 8) {
            Label(approval.summary, systemImage: approval.isDestructive
                ? "exclamationmark.octagon.fill"
                : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            HStack {
                Spacer()
                Button("Skip") { model.resolveApproval(false) }
                Button("Approve") { model.resolveApproval(true) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
    }

    private func questionRow(_ question: AgentViewModel.PendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(question.text, systemImage: "questionmark.bubble.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
            HStack(spacing: 8) {
                TextField("Answer", text: $model.questionAnswerText)
                    .textFieldStyle(.plain)
                    .padding(7)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { model.resolveQuestion(model.questionAnswerText) }
                Button("Skip") { model.resolveQuestion("") }
                Button("Send") { model.resolveQuestion(model.questionAnswerText) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.questionAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
    }

    private func memoryRow(_ memory: AgentViewModel.PendingMemory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(memory.text, systemImage: "brain")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.purple)
            HStack {
                Text(memory.scopeLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.purple)
                Spacer()
                Button("Skip") { model.resolveMemory(false) }
                Button("Remember") { model.resolveMemory(true) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.purple.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
    }

    private func workflowRow(_ workflow: AgentViewModel.PendingWorkflow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(workflow.name, systemImage: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.teal)
            Text(workflow.goalTemplate)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
            HStack {
                Spacer()
                Button("Skip") { model.resolveWorkflow(false) }
                Button("Save workflow") { model.resolveWorkflow(true) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.teal.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
    }

    private var phaseLine: some View {
        HStack(spacing: 6) {
            phaseLabel
            Spacer(minLength: 4)
            if let usage = model.tokenUsageText {
                Text(usage)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .running:
            Label("Running", systemImage: "bolt.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
        case .finished(let summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(2)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var feed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.feed.suffix(8)) { item in
                    Text(item.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(item.isError ? .red : .white.opacity(0.78))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 138)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The last few finished runs. Tapping one reloads its task and target so
    /// the user can re-run or tweak a previous request.
    @ViewBuilder
    private var recentRunsSection: some View {
        if !model.recentRuns.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("RECENT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Button("Clear") { model.clearHistory() }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .help("Clear run history")
                }
                ForEach(model.recentRuns.prefix(3)) { run in
                    runRow(run)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runRow(_ run: RunRecord) -> some View {
        Button {
            model.promptText = run.task
            model.selectedAppName = run.appName
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.runGlyph(run.status))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Self.runColor(run.status))
                Text(run.task)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(run.appName) · \(run.actionCount) · \(run.compactTokens) tok")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Reuse this task")
    }

    private static func runGlyph(_ status: RunStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private static func runColor(_ status: RunStatus) -> Color {
        switch status {
        case .completed: .green
        case .stopped: .yellow
        case .failed: .red
        }
    }

    private var statusGlyph: some View {
        Image(systemName: glyphName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(glyphColor)
    }

    private var glyphName: String {
        switch model.phase {
        case .idle: "sparkles"
        case .running: "bolt.fill"
        case .finished: "checkmark"
        case .failed: "xmark"
        }
    }

    private var glyphColor: Color {
        switch model.phase {
        case .idle, .running: .white
        case .finished: .green
        case .failed: .red
        }
    }

    private var headerTitle: String {
        switch model.phase {
        case .idle: "Autopilot"
        case .running: "Working"
        case .finished: "Done"
        case .failed: "Needs attention"
        }
    }

    private func submit() {
        model.submit()
        if model.phase == .running {
            setExpanded(false)
        }
    }

    private func expand() {
        setExpanded(true)
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(.snappy(duration: 0.22)) {
            model.isExpanded = expanded
        }
    }
}

/// The saved-workflows list plus minimal create / save-from-run forms.
///
/// Like the rest of this view, the visual language is a placeholder; the data
/// flow — list, run with variables, save, delete — is what matters.
private struct WorkflowsPanel: View {
    let model: AgentViewModel
    @State private var mode: Mode = .none
    @State private var draftName = ""
    @State private var draftGoal = ""

    private enum Mode { case none, create, saveRun }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch mode {
            case .none:
                EmptyView()
            case .create:
                createForm
            case .saveRun:
                saveRunForm
            }
            ForEach(model.savedWorkflows.prefix(4)) { workflow in
                WorkflowRow(model: model, workflow: workflow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("WORKFLOWS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
            headerButton(mode == .create ? "Cancel" : "New") { toggle(.create) }
            if model.recentRuns.first != nil {
                headerButton(mode == .saveRun ? "Cancel" : "Save run") { toggle(.saveRun) }
            }
            if !model.savedWorkflows.isEmpty {
                headerButton("Clear") { model.clearWorkflows() }
            }
        }
    }

    private func headerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
    }

    private var createForm: some View {
        VStack(spacing: 6) {
            field("Workflow name", text: $draftName)
            field("Goal — use {{slot}} for fill-ins", text: $draftGoal)
            HStack {
                Text(model.selectedAppName.isEmpty
                    ? "Pick a target app above"
                    : "App · \(model.selectedAppName)")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button("Create") {
                    model.createWorkflow(
                        name: draftName,
                        appName: model.selectedAppName,
                        goalTemplate: draftGoal
                    )
                    toggle(.none)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canCreate)
            }
        }
        .padding(8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var saveRunForm: some View {
        if let run = model.recentRuns.first {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save \"\(run.task)\" (\(run.appName)) as a workflow")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                HStack {
                    field("Workflow name", text: $draftName)
                    Button("Save") {
                        model.saveRunAsWorkflow(run, name: draftName)
                        toggle(.none)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(8)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(7)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var canCreate: Bool {
        !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draftGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.selectedAppName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func toggle(_ target: Mode) {
        mode = (mode == target) ? .none : target
        draftName = ""
        draftGoal = ""
    }
}

/// One saved workflow row: variable fields, Run, and Delete.
private struct WorkflowRow: View {
    let model: AgentViewModel
    let workflow: AgentViewModel.StoredWorkflow
    @State private var bindings: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.teal)
                Text(workflow.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if workflow.runCount > 0 {
                    Text("\(workflow.successCount)/\(workflow.runCount)")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .help("Successful runs")
                }
                Text(workflow.appName)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                Button {
                    model.deleteWorkflow(id: workflow.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
                .help("Delete workflow")
            }
            ForEach(workflow.variables) { variable in
                field(placeholder(for: variable), text: binding(for: variable.name))
            }
            HStack {
                Spacer()
                Button("Run") {
                    model.runWorkflow(id: workflow.id, bindings: bindings)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.phase == .running)
            }
        }
        .padding(8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .onAppear(perform: seedDefaults)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 10))
            .padding(6)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func placeholder(for variable: WorkflowVariable) -> String {
        variable.description.isEmpty ? variable.name : variable.description
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { bindings[name] ?? "" },
            set: { bindings[name] = $0 }
        )
    }

    private func seedDefaults() {
        for variable in workflow.variables where bindings[variable.name] == nil {
            bindings[variable.name] = variable.defaultValue ?? ""
        }
    }
}

#Preview("Expanded") {
    let model = AgentViewModel()
    model.isExpanded = true
    return NotchAssistantView(model: model)
}
