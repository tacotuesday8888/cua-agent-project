/// Tracks which apps the user has trusted for write actions.
///
/// Reading is always free. The first write to an app is gated; once the user
/// approves it, the app is trusted for the rest of the session. Destructive
/// actions are never satisfied by trust — `AgentSession` always gates those,
/// regardless of what this store says.
public struct TrustStore: Sendable {
    /// Apps the user trusts permanently, from settings (stored lower-cased).
    private let permanentlyTrusted: Set<String>
    /// Apps trusted for the current session only (stored lower-cased).
    private var sessionTrusted: Set<String> = []

    public init(permanentlyTrusted: Set<String> = []) {
        self.permanentlyTrusted = Set(permanentlyTrusted.map { $0.lowercased() })
    }

    /// Whether write actions on `app` may run without asking.
    public func isTrusted(app: String) -> Bool {
        let key = app.lowercased()
        return permanentlyTrusted.contains(key) || sessionTrusted.contains(key)
    }

    /// Trust `app` for the remainder of the session.
    public mutating func recordSessionTrust(app: String) {
        sessionTrusted.insert(app.lowercased())
    }
}
