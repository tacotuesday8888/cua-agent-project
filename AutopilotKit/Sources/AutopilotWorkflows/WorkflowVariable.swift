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
    /// Legacy in-memory compatibility only. Defaults are not encoded or decoded:
    /// typed workflow values are used for one run and never persisted.
    public let defaultValue: String?

    public var id: String { name }

    public init(name: String, description: String = "", defaultValue: String? = nil) {
        self.name = name
        self.description = description
        self.defaultValue = nil
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        defaultValue = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
    }
}
