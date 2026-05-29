import AutopilotCore
import Foundation

/// Compares pre/post action snapshots and classifies whether a write action
/// visibly affected the app.
public struct ActionEffectVerifier: Sendable {
    public init() {}

    public func verify(
        tool: AgentTool,
        input: JSONValue,
        target: ActionTarget,
        before: UITreeSnapshot?,
        after: UITreeSnapshot?
    ) -> ActionVerificationResult {
        guard let before, let after else {
            return ActionVerificationResult(
                status: .inconclusive,
                summary: "Could not verify the action effect because a before or after snapshot was missing.",
                signals: [.missingSnapshot]
            )
        }

        var signals: [ActionVerificationResult.Signal] = []
        func add(_ signal: ActionVerificationResult.Signal) {
            if !signals.contains(signal) { signals.append(signal) }
        }

        if windowChanged(before: before, after: after) {
            add(.windowChanged)
        }

        if containsModal(after), !containsModal(before) {
            add(.modalPresent)
        }

        let beforeTarget = matchedElement(for: target, in: before)
        let afterTarget = matchedElement(for: target, in: after)
        if beforeTarget != nil, afterTarget == nil {
            add(.targetMissing)
        }
        if let beforeTarget, let afterTarget {
            if beforeTarget.value != afterTarget.value {
                add(.targetValueChanged)
            }
            if beforeTarget.isFocused != afterTarget.isFocused {
                add(.targetFocusChanged)
            }
        }

        if let expectedText = expectedText(for: tool, input: input),
           textIsVisible(expectedText, target: afterTarget, snapshot: after) {
            add(.expectedTextObserved)
        }

        if snapshotFingerprint(before) != snapshotFingerprint(after) {
            add(.treeChanged)
        }

        if signals.contains(.windowChanged)
            || signals.contains(.modalPresent)
            || signals.contains(.targetValueChanged)
            || signals.contains(.targetFocusChanged)
            || signals.contains(.expectedTextObserved)
            || signals.contains(.treeChanged) {
            return ActionVerificationResult(
                status: .changed,
                summary: changedSummary(signals: signals),
                signals: signals
            )
        }

        add(.noVisibleChange)
        return ActionVerificationResult(
            status: .unchanged,
            summary: "No visible accessibility-tree change was detected after the action.",
            signals: signals
        )
    }

    private func windowChanged(before: UITreeSnapshot, after: UITreeSnapshot) -> Bool {
        before.windowIdentifier != after.windowIdentifier
            || before.windowTitle != after.windowTitle
    }

    private func containsModal(_ snapshot: UITreeSnapshot) -> Bool {
        snapshot.root.flattened.contains { element in
            let role = element.role.lowercased()
            let subrole = element.subrole?.lowercased() ?? ""
            return role.contains("sheet")
                || role.contains("dialog")
                || role.contains("popover")
                || subrole.contains("sheet")
                || subrole.contains("dialog")
                || subrole.contains("popover")
        }
    }

    private func matchedElement(for target: ActionTarget, in snapshot: UITreeSnapshot) -> UIElement? {
        let elements = snapshot.root.flattened
        if let identifier = target.identifier, !identifier.isEmpty,
           let match = elements.first(where: { $0.identifier == identifier }) {
            return match
        }
        if let elementID = target.elementID,
           let match = snapshot.element(id: elementID),
           weaklyMatches(match, target: target) {
            return match
        }
        return elements.first { weaklyMatches($0, target: target) }
    }

    private func weaklyMatches(_ element: UIElement, target: ActionTarget) -> Bool {
        if let role = target.role, !role.isEmpty, element.role != role {
            return false
        }
        if let label = target.label, !label.isEmpty, element.label != label {
            return false
        }
        if let targetFrame = target.frame, !frameIsNear(element.frame, targetFrame) {
            return false
        }
        return target.role != nil || target.label != nil || target.frame != nil
    }

    private func frameIsNear(_ lhs: ElementFrame, _ rhs: ElementFrame) -> Bool {
        let distance = abs(lhs.x - rhs.x)
            + abs(lhs.y - rhs.y)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
        return distance <= 12
    }

    private func expectedText(for tool: AgentTool, input: JSONValue) -> String? {
        switch tool {
        case .setValue:
            input["value"]?.stringValue
        case .typeText:
            input["text"]?.stringValue
        case .listApps, .getAppState, .click, .scroll, .pressKey, .drag,
             .performSecondaryAction, .wait, .askUser, .proposeMemory,
             .proposeWorkflow, .done:
            nil
        }
    }

    private func textIsVisible(
        _ text: String,
        target: UIElement?,
        snapshot: UITreeSnapshot
    ) -> Bool {
        guard !text.isEmpty else { return true }
        if element(target, contains: text) { return true }
        return snapshot.root.flattened.contains { element in
            (element.isFocused || element.isValueSettable) && self.element(element, contains: text)
        }
    }

    private func element(_ element: UIElement?, contains text: String) -> Bool {
        guard let element else { return false }
        return element.label?.contains(text) == true
            || element.value?.contains(text) == true
    }

    private func snapshotFingerprint(_ snapshot: UITreeSnapshot) -> String {
        snapshot.root.flattened.map { element in
            [
                element.role,
                element.subrole ?? "",
                element.identifier ?? "",
                element.label ?? "",
                element.value ?? "",
                element.isEnabled ? "enabled" : "disabled",
                element.isFocused ? "focused" : "blurred",
                element.isValueSettable ? "settable" : "readonly",
                element.actions.joined(separator: ",")
            ].joined(separator: "|")
        }
        .joined(separator: "\n")
    }

    private func changedSummary(signals: [ActionVerificationResult.Signal]) -> String {
        if signals.contains(.expectedTextObserved) {
            return "The expected text is visible after the action."
        }
        if signals.contains(.windowChanged) {
            return "The action changed the active target window."
        }
        if signals.contains(.modalPresent) {
            return "A modal, sheet, or popover appeared after the action."
        }
        return "The accessibility tree changed after the action."
    }
}

/// Conservative post-action verification result recorded in trajectories and
/// optionally surfaced back to the model as recovery guidance.
public struct ActionVerificationResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case changed
        case unchanged
        case inconclusive
    }

    public enum Signal: String, Codable, Sendable {
        case targetValueChanged = "target_value_changed"
        case targetFocusChanged = "target_focus_changed"
        case treeChanged = "tree_changed"
        case windowChanged = "window_changed"
        case modalPresent = "modal_present"
        case expectedTextObserved = "expected_text_observed"
        case targetMissing = "target_missing"
        case noVisibleChange = "no_visible_change"
        case missingSnapshot = "missing_snapshot"
    }

    public var status: Status
    public var summary: String
    public var signals: [Signal]

    public init(status: Status, summary: String, signals: [Signal] = []) {
        self.status = status
        self.summary = summary
        self.signals = signals
    }

    public var shouldWarnModel: Bool {
        status == .unchanged || signals.contains(.targetMissing)
    }
}
