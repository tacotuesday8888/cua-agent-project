import AutopilotCore
import Foundation

/// Decides which approval tier a proposed action falls into.
///
/// Reading is always `safe`; an action that changes app state is `write`; an
/// action that sends, deletes, pays, or overwrites is `destructive`.
public struct RiskClassifier: Sendable {
    public init() {}

    /// Substrings that, in a clicked element's label, value, or accessibility
    /// identifier, mark the action as destructive — consequential and hard to
    /// reverse.
    private static let destructiveKeywords: [String] = [
        "delete", "remove", "trash", "discard", "erase",
        "send", "submit", "post", "publish", "share",
        "overwrite",
        "buy", "purchase", "pay", "checkout", "place order", "order now",
        "subscribe", "confirm", "permanently",
        "sign out", "log out", "unsubscribe", "cancel subscription"
    ]

    /// Keys that, pressed with Command, do something consequential and hard to
    /// undo: ⌘⌫ and its variants delete content; ⌘W closes a window or tab,
    /// discarding unsaved work; ⌘Q quits the app.
    ///
    /// Stored in compacted form (see `compacted`) and matched the same way, so
    /// every spelling the actuator accepts is gated too — `KeyCodes` resolves
    /// `del`, `forward delete`, and `back-space` to the same destructive keys,
    /// and a title-only gate would have let those bypass the destructive tier.
    /// Keep this in sync with the destructive entries in `KeyCodes`.
    private static let destructiveCommandKeys: Set<String> = [
        "delete", "backspace", "del", "forwarddelete", "w", "q"
    ]

    /// Assess the approval tier of a tool call against the current UI snapshot.
    public func assess(
        tool: AgentTool,
        input: JSONValue,
        snapshot: UITreeSnapshot?
    ) -> RiskLevel {
        switch tool {
        case .listApps, .getAppState, .scroll, .wait:
            // Reading, scrolling, and waiting change nothing the user cannot undo.
            return .safe
        case .askUser, .done, .proposeMemory, .proposeWorkflow:
            // Orchestration tools never touch the controlled app.
            return .safe
        case .typeText, .drag:
            return .write
        case .click:
            return targetsDestructiveElement(input, snapshot) ? .destructive : .write
        case .performSecondaryAction:
            // A secondary action is destructive if its target carries a
            // destructive word or the action itself names one — a context-menu
            // "Delete" run on a plainly-labeled row must still be gated.
            let destructive = targetsDestructiveElement(input, snapshot)
                || actionIsDestructive(input)
            return destructive ? .destructive : .write
        case .setValue:
            return overwritesExistingValue(input, snapshot) ? .destructive : .write
        case .pressKey:
            return isDestructiveKeyPress(input) ? .destructive : .write
        }
    }

    /// Whether the clicked element's label, value, or accessibility identifier
    /// carries a destructive word.
    ///
    /// The identifier is included so an icon-only button with no visible label
    /// — but an identifier like `sendButton` — is still recognized. Matching
    /// stays substring-based: it errs toward asking, which is the safe
    /// direction for an approval gate.
    private func targetsDestructiveElement(
        _ input: JSONValue,
        _ snapshot: UITreeSnapshot?
    ) -> Bool {
        guard
            let elementID = elementID(from: input),
            let element = snapshot?.element(id: elementID)
        else {
            return false
        }
        let haystack = [element.label, element.value, element.identifier]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let compactHaystack = Self.compacted(haystack)
        return Self.destructiveKeywords.contains { keyword in
            haystack.contains(keyword) || compactHaystack.contains(Self.compacted(keyword))
        }
    }

    /// Whether a `perform_secondary_action` call invokes a consequential
    /// action, recognized by a destructive word in the action name itself — for
    /// example a context-menu "Delete", "Move to Trash", or a custom `AXDelete`
    /// action. This is checked alongside the element's own labels, so a
    /// destructive action on an otherwise harmless-looking element is still
    /// gated. Matching errs toward asking, the safe direction for the gate.
    private func actionIsDestructive(_ input: JSONValue) -> Bool {
        let action = (input["action"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !action.isEmpty else { return false }
        let compactAction = Self.compacted(action)
        return Self.destructiveKeywords.contains { keyword in
            action.contains(keyword) || compactAction.contains(Self.compacted(keyword))
        }
    }

    /// Whether `set_value` would replace a field that already has content.
    private func overwritesExistingValue(
        _ input: JSONValue,
        _ snapshot: UITreeSnapshot?
    ) -> Bool {
        guard
            let elementID = elementID(from: input),
            let value = snapshot?.element(id: elementID)?.value
        else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a key press is consequential and hard to undo, e.g. ⌘⌫ to
    /// delete, ⌘W to close, or ⌘Q to quit.
    private func isDestructiveKeyPress(_ input: JSONValue) -> Bool {
        // Compact the key the way labels and actions are matched, so the gate
        // recognizes the same spelling variants the actuator resolves (e.g.
        // "del", "forward delete") rather than only their canonical names.
        let key = Self.compacted(input["key"]?.stringValue ?? "")
        let modifiers = Set(
            (input["modifiers"]?.arrayValue ?? [])
                .compactMap(\.stringValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        return modifiers.contains("command") && Self.destructiveCommandKeys.contains(key)
    }

    private func elementID(from input: JSONValue) -> String? {
        ElementReference.lenientID(from: input)
    }

    private static func compacted(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber }.lowercased()
    }
}
