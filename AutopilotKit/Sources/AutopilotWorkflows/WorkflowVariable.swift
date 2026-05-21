import Foundation

/// One fill-in-the-blank value a workflow needs when it runs.
///
/// A variable's `name` is the token used in a workflow's `goalTemplate` as
/// `{{name}}`. The placeholder syntax is `{{name}}` everywhere — model,
/// renderer, tests, docs, and UI.
public struct WorkflowVariable: Sendable, Hashable, Codable, Identifiable {
    /// The token name, without braces. Stable key, and the variable's id.
    public let name: String
    /// A short human prompt for the value, shown as the input field's hint.
    public let description: String
    /// An optional value to prefill when the workflow is run.
    public let defaultValue: String?

    public var id: String { name }

    public init(name: String, description: String = "", defaultValue: String? = nil) {
        self.name = name
        self.description = description
        self.defaultValue = defaultValue
    }
}
