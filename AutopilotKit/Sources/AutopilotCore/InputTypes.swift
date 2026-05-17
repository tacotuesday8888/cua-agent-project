/// A direction for a scroll action.
public enum ScrollDirection: String, Sendable, Codable, CaseIterable {
    case up
    case down
    case left
    case right
}

/// A keyboard key press, optionally combined with modifier keys.
public struct KeyPress: Sendable, Codable, Hashable {
    /// A modifier key held during a key press.
    public enum Modifier: String, Sendable, Codable, CaseIterable {
        case command
        case shift
        case option
        case control
        case function
    }

    /// The key name, e.g. "return", "escape", "tab", "a", "downArrow".
    public let key: String
    /// Modifier keys held during the press.
    public let modifiers: [Modifier]

    public init(key: String, modifiers: [Modifier] = []) {
        self.key = key
        self.modifiers = modifiers
    }
}
