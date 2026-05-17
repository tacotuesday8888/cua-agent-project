import Foundation

/// Renders a `UITreeSnapshot` into compact text for an LLM prompt.
///
/// Accessibility-tree-primary perception means the agent reasons over this
/// text, not screenshots — so the rendering keeps signal (ids, roles, labels,
/// values, state) and drops decorative noise.
public enum UITreeRenderer {
    /// Roles that are always worth showing even without a label or value.
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuItem", "AXMenuButton", "AXLink", "AXSlider",
        "AXComboBox", "AXTabGroup", "AXRow", "AXCell", "AXSearchField",
        "AXDisclosureTriangle", "AXIncrementor"
    ]

    /// Render a snapshot into indented text, e.g.:
    /// `[4] AXTextField "Search" value:"jazz" (focused)`
    public static func compactText(_ snapshot: UITreeSnapshot, maxElements: Int = 400) -> String {
        var lines: [String] = ["App: \(snapshot.appName)"]
        if let window = snapshot.windowTitle, !window.isEmpty {
            lines.append("Window: \(window)")
        }
        if let windowID = snapshot.windowIdentifier {
            lines.append("Window ID: \(windowID)")
        }
        if let turnID = snapshot.turnIdentifier {
            lines.append("Turn: \(turnID)")
        }

        var rendered = 0
        var truncated = false

        func walk(_ element: UIElement, depth: Int) {
            guard rendered < maxElements else {
                truncated = true
                return
            }
            if let line = elementLine(element, depth: depth) {
                lines.append(line)
                rendered += 1
            }
            for child in element.children {
                walk(child, depth: depth + 1)
            }
        }
        walk(snapshot.root, depth: 0)

        if truncated {
            lines.append("… (tree truncated at \(maxElements) elements)")
        }
        return lines.joined(separator: "\n")
    }

    private static func elementLine(_ element: UIElement, depth: Int) -> String? {
        let hasLabel = !(element.label ?? "").isEmpty
        let hasValue = !(element.value ?? "").isEmpty
        let isInteresting = hasLabel || hasValue || interactiveRoles.contains(element.role)
        guard isInteresting else { return nil }

        var parts = ["[\(displayID(for: element))]", element.role]
        if let subrole = element.subrole, !subrole.isEmpty {
            parts.append("subrole:\(subrole)")
        }
        if let label = element.label, !label.isEmpty {
            parts.append("\"\(label)\"")
        }
        if let value = element.value, !value.isEmpty {
            parts.append("value:\"\(truncate(value, to: 80))\"")
        }
        if let identifier = element.identifier, !identifier.isEmpty {
            parts.append("identifier:\(identifier)")
        }
        var flags: [String] = []
        if !element.isEnabled { flags.append("disabled") }
        if element.isFocused { flags.append("focused") }
        if element.isValueSettable { flags.append("settable") }
        if !flags.isEmpty {
            parts.append("(\(flags.joined(separator: ", ")))")
        }
        let interestingActions = element.actions.filter { $0 != "AXPress" }
        if !interestingActions.isEmpty {
            parts.append("actions:\(interestingActions.joined(separator: ","))")
        }

        let indent = String(repeating: "  ", count: depth)
        return indent + parts.joined(separator: " ")
    }

    private static func truncate(_ string: String, to length: Int) -> String {
        string.count <= length ? string : String(string.prefix(length)) + "…"
    }

    private static func displayID(for element: UIElement) -> String {
        guard element.id.hasPrefix("e") else { return element.id }
        let index = element.id.dropFirst()
        return index.isEmpty ? element.id : String(index)
    }
}
