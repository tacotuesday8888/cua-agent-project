import AutopilotCore

/// Decides whether a proposed action is consequential enough to need explicit
/// user confirmation before it runs.
public struct RiskClassifier: Sendable {
    public init() {}

    /// Substrings that, in a clicked element's label or value, mark an action
    /// as consequential or hard to reverse.
    private static let riskyKeywords: [String] = [
        "delete", "remove", "trash", "discard", "erase",
        "send", "submit", "post", "publish", "share",
        "buy", "purchase", "pay", "checkout", "place order", "order now",
        "subscribe", "confirm", "permanently",
        "sign out", "log out", "unsubscribe", "cancel subscription"
    ]

    /// Assess the risk of a tool call given the current UI snapshot.
    public func assess(
        tool: AgentTool,
        input: JSONValue,
        snapshot: UITreeSnapshot?
    ) -> RiskLevel {
        switch tool {
        case .listApps, .getAppState, .askUser, .done, .scroll, .setValue,
             .typeText, .pressKey, .drag:
            // Reading, scrolling, typing, and key presses are reversible.
            return .safe
        case .click, .performSecondaryAction:
            guard
                let elementID = elementID(from: input),
                let element = snapshot?.element(id: elementID)
            else {
                return .safe
            }
            let haystack = [element.label, element.value]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            return Self.riskyKeywords.contains(where: haystack.contains) ? .risky : .safe
        }
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
