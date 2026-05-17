/// A memory the agent suggests saving, pending the user's approval.
///
/// Unlike a stored `MemoryItem`, a proposal has no identity or timestamp until
/// the user accepts it.
public struct MemoryProposal: Sendable, Hashable {
    /// The fact the agent proposes remembering.
    public let text: String
    /// Where the agent thinks the fact applies.
    public let scope: MemoryScope

    public init(text: String, scope: MemoryScope = .global) {
        self.text = text
        self.scope = scope
    }
}
