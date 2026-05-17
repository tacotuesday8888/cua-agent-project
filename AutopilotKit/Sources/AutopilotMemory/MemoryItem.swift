import Foundation

/// Where a remembered fact applies.
///
/// Memory is scoped so the agent only recalls what is relevant: global facts
/// surface on every task, app facts only when operating that app, and contact
/// facts only when that person is involved.
public enum MemoryScope: Sendable, Hashable, Codable {
    /// Relevant to every task.
    case global
    /// Relevant only when operating the named app.
    case app(String)
    /// Relevant only when the named person is involved.
    case contact(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    /// Decodes the flat `{"kind": …, "value": …}` shape.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "app":
            self = .app(try container.decode(String.self, forKey: .value))
        case "contact":
            self = .contact(try container.decode(String.self, forKey: .value))
        default:
            self = .global
        }
    }

    /// Encodes a flat `{"kind": …, "value": …}` shape — readable and stable in
    /// the on-disk JSON, since `memory.json` is meant to be user-inspectable.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode("global", forKey: .kind)
        case .app(let name):
            try container.encode("app", forKey: .kind)
            try container.encode(name, forKey: .value)
        case .contact(let name):
            try container.encode("contact", forKey: .kind)
            try container.encode(name, forKey: .value)
        }
    }

    /// A short human label for the scope, e.g. "Global" or "App · Music".
    public var displayName: String {
        switch self {
        case .global: "Global"
        case .app(let name): "App · \(name)"
        case .contact(let name): "Contact · \(name)"
        }
    }
}

/// How a memory entered the store.
public enum MemorySource: String, Sendable, Hashable, Codable {
    /// The user explicitly asked to remember it ("remember: …").
    case explicit
    /// The agent proposed it mid-task and the user approved.
    case proposed
}

/// A single durable fact the agent knows about the user.
///
/// Memory is stored locally. `AgentSession` may include relevant memory in the
/// provider prompt for a task, so memory text should not contain secrets.
public struct MemoryItem: Sendable, Hashable, Codable, Identifiable {
    /// Stable identifier, assigned on creation.
    public let id: UUID
    /// The fact, as a short statement.
    public let text: String
    /// Where the fact applies.
    public let scope: MemoryScope
    /// How the fact was captured.
    public let source: MemorySource
    /// When the fact was stored.
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        scope: MemoryScope = .global,
        source: MemorySource,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.scope = scope
        self.source = source
        self.createdAt = createdAt
    }
}
