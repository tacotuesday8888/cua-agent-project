import Foundation

/// How a workflow entered the store.
public enum WorkflowSource: String, Sendable, Hashable, Codable {
    /// The user built the workflow by hand.
    case manual
    /// Legacy or imported provenance from an earlier save-from-run flow.
    /// Current product flows use manual creation or explicit agent proposals.
    case savedFromRun
    /// The agent proposed it mid-task and the user approved.
    case proposed
}

/// A saved, reusable task the agent can run again.
///
/// A workflow is a *goal*, not a recorded click-script: it stores a
/// natural-language `goalTemplate` (with `{{slot}}` tokens), the variables that
/// fill those slots, and the single app it operates. Re-running it feeds the
/// resolved goal back through the normal agent loop, which re-reads the live
/// screen and reasons again — so the workflow adapts to UI changes instead of
/// breaking like a macro.
///
/// Workflows are stored locally and must stay secret-free: the template,
/// variable names, and recipe describe *steps*, never typed values or
/// passwords. Variable values entered at run time are used transiently and are
/// never persisted here.
public struct Workflow: Sendable, Hashable, Codable, Identifiable {
    /// The most characters a recipe keeps; longer recipes are truncated so the
    /// prompt prior stays bounded.
    public static let maxRecipeLength = 1200

    /// Stable identifier, assigned on creation.
    public let id: UUID
    /// The user-facing name; also the case-insensitive de-duplication key.
    public let name: String
    /// The single app this workflow operates. Multi-app workflows are future
    /// vision and require a different run contract.
    public let appName: String
    /// The goal in natural language, with `{{slot}}` tokens for its variables.
    public let goalTemplate: String
    /// A learned, secret-free summary used as guidance on re-runs.
    public let recipe: String
    /// The variables the goal template needs.
    public let variables: [WorkflowVariable]
    /// How the workflow was created.
    public let source: WorkflowSource
    /// The run this workflow was saved from, when applicable.
    public let sourceRunID: UUID?
    /// When the workflow was created.
    public let createdAt: Date
    /// When the workflow was last edited or run.
    public var updatedAt: Date
    /// How many times the workflow has been run.
    public var runCount: Int
    /// How many of those runs finished successfully.
    public var successCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        appName: String,
        goalTemplate: String,
        recipe: String = "",
        variables: [WorkflowVariable] = [],
        source: WorkflowSource,
        sourceRunID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        runCount: Int = 0,
        successCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.appName = appName
        self.goalTemplate = goalTemplate
        self.recipe = String(recipe.prefix(Self.maxRecipeLength))
        self.variables = variables
        self.source = source
        self.sourceRunID = sourceRunID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.runCount = runCount
        self.successCount = successCount
    }

    /// The fraction of runs that succeeded, in 0...1, or 0 when never run.
    public var successRate: Double {
        guard runCount > 0 else { return 0 }
        return Double(successCount) / Double(runCount)
    }

    /// The names of the variables this workflow declares.
    public var variableNames: [String] { variables.map(\.name) }
}
