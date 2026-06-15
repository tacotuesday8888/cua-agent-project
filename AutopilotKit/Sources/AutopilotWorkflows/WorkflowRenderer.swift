import Foundation

/// Pure helpers for turning a stored workflow into something runnable or
/// displayable. Kept side-effect-free so it is trivially testable.
public enum WorkflowRenderer {
    /// Return the values supplied for a specific run. Stored defaults are
    /// intentionally ignored because typed workflow values are never persisted.
    public static func resolvedBindings(
        variables: [WorkflowVariable],
        bindings: [String: String]
    ) -> [String: String] {
        var resolved: [String: String] = Dictionary(uniqueKeysWithValues: variables.map {
            ($0.name, "")
        })
        for (key, value) in bindings {
            resolved[key] = value
        }
        resolved = resolved.filter { !$0.value.isEmpty }
        return resolved
    }

    /// Slot names from `template` that still have no non-empty value after
    /// run bindings are applied.
    public static func missingSlotNames(
        in template: String,
        variables: [WorkflowVariable],
        bindings: [String: String]
    ) -> [String] {
        let resolved = resolvedBindings(variables: variables, bindings: bindings)
        return slotNames(in: template).filter { name in
            (resolved[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Substitute `{{slot}}` tokens in `template` with the matching value from
    /// `bindings`. Unbound tokens are left literal — so a missing value stays
    /// visible to the user and the agent rather than being silently blanked.
    ///
    /// The placeholder syntax is `{{slotName}}` everywhere: model, renderer,
    /// tests, docs, and UI.
    public static func resolveGoal(template: String, bindings: [String: String]) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            result += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
                // No closing braces: keep the remainder verbatim and stop.
                result += rest[open.lowerBound...]
                return result
            }
            let name = rest[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if let value = bindings[name] {
                result += value
            } else {
                // Unbound: leave the whole `{{name}}` token visible.
                result += rest[open.lowerBound..<close.upperBound]
            }
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }

    /// The ordered, unique `{{slot}}` names used in `template`. Used to derive a
    /// workflow's variables from its goal so the UI can show one field per slot.
    public static func slotNames(in template: String) -> [String] {
        var names: [String] = []
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
                break
            }
            let name = rest[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
            rest = rest[close.upperBound...]
        }
        return names
    }

    /// A short, one-line human summary of a workflow for lists and the feed.
    public static func summary(for workflow: Workflow) -> String {
        let appPart = workflow.appName.isEmpty ? "" : " · \(workflow.appName)"
        guard !workflow.variables.isEmpty else {
            return "\(workflow.name)\(appPart)"
        }
        let slots = workflow.variableNames.map { "{{\($0)}}" }.joined(separator: ", ")
        return "\(workflow.name)\(appPart) · \(slots)"
    }
}
