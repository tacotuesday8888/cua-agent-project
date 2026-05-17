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
        "buy", "purchase", "pay", "checkout", "place order", "order now",
        "subscribe", "confirm", "permanently",
        "sign out", "log out", "unsubscribe", "cancel subscription"
    ]

    /// Keys that, pressed with Command, do something consequential and hard to
    /// undo: ⌘⌫ and its variants delete content; ⌘W closes a window or tab,
    /// discarding unsaved work; ⌘Q quits the app.
    private static let destructiveCommandKeys: Set<String> = [
        "delete", "backspace", "forwarddelete", "w", "q"
    ]

    /// Assess the approval tier of a tool call against the current UI snapshot.
    public func assess(
        tool: AgentTool,
        input: JSONValue,
        snapshot: UITreeSnapshot?
    ) -> RiskLevel {
        switch tool {
        case .listApps, .getAppState, .scroll:
            // Reading and scrolling change nothing the user cannot undo.
            return .safe
        case .askUser, .done, .proposeMemory:
            // Orchestration tools never touch the controlled app.
            return .safe
        case .typeText, .drag:
            return .write
        case .click, .performSecondaryAction:
            return targetsDestructiveElement(input, snapshot) ? .destructive : .write
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
        return Self.destructiveKeywords.contains(where: haystack.contains)
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
        let key = (input["key"]?.stringValue ?? "").lowercased()
        let modifiers = Set(
            (input["modifiers"]?.arrayValue ?? [])
                .compactMap(\.stringValue)
                .map { $0.lowercased() }
        )
        return modifiers.contains("command") && Self.destructiveCommandKeys.contains(key)
    }

    private func elementID(from input: JSONValue) -> String? {
        if let elementID = input["element_id"]?.stringValue {
            return elementID
        }
        if let index = input["element_index"]?.intValue {
            return "e\(index)"
        }
        if let index = input["element_index"]?.stringValue {
            return index.hasPrefix("e") ? index : "e\(index)"
        }
        return nil
    }
}
