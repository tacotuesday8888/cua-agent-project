import AutopilotCore

/// A request for the user to approve a gated action.
///
/// It carries everything the UI needs to show what is at stake — the action's
/// risk tier and its target — before the user taps Approve or Skip.
public struct ApprovalRequest: Sendable {
    /// The app the action operates.
    public let appName: String
    /// Why the action needs approval.
    public let tier: RiskLevel
    /// What the action will interact with, and where on screen it lives.
    public let target: ActionTarget
    /// A one-line summary of the action.
    public let summary: String

    public init(appName: String, tier: RiskLevel, target: ActionTarget, summary: String) {
        self.appName = appName
        self.tier = tier
        self.target = target
        self.summary = summary
    }
}
