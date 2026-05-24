/// A reusable workflow the agent suggests saving, pending the user's approval.
///
/// This lives in `AutopilotAgent`, not `AutopilotWorkflows`, so the engine can
/// build a proposal without depending on the workflow store. The UI layer (which
/// owns persistence) maps an approved proposal onto a stored `Workflow`. That
/// keeps the agent loop storage-agnostic for workflows, matching how only the UI
/// consumes `AutopilotWorkflows`.
public struct WorkflowProposal: Sendable, Hashable {
    /// A short, human-facing name for the workflow.
    public let name: String
    /// The reusable goal, with optional `{{slot}}` variables the user fills in.
    public let goalTemplate: String
    /// Optional hints learned this run, injected as a prior on re-runs. Never a
    /// recorded click-script and never sensitive values — guidance only.
    public let recipe: String

    public init(name: String, goalTemplate: String, recipe: String = "") {
        self.name = name
        self.goalTemplate = goalTemplate
        self.recipe = recipe
    }
}
