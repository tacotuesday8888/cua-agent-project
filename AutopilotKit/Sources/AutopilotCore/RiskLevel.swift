/// How much caution an action requires before it runs.
public enum RiskLevel: String, Sendable, Codable, Hashable {
    /// Safe and reversible — runs without confirmation.
    case safe
    /// Consequential or hard to reverse — requires explicit user approval.
    case risky
}
