/// Which approval tier an action falls into.
public enum RiskLevel: String, Sendable, Codable, Hashable {
    /// Reading or scrolling — reversible, runs without asking.
    case safe
    /// Changes app state — asked once per app, then trusted for the session.
    case write
    /// Sends, deletes, pays, or overwrites — always asked, never auto-trusted.
    case destructive
}
