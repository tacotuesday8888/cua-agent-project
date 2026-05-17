import AutopilotMemory
import Foundation

/// Extracts explicit "remember:" instructions from a task prompt.
///
/// A prompt that begins with `remember:` or `remember that …` is a request to
/// store a fact about the user, not an app task. Anything else — including a
/// non-leading "remember" such as "remember to reply" — is left untouched.
public struct PromptParser: Sendable {
    public init() {}

    /// The memories the user explicitly asked to store. An empty array means
    /// an ordinary task; a non-empty array means the whole prompt was a
    /// "remember:" instruction and no app task should run.
    public func explicitMemories(in task: String) -> [MemoryItem] {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        for prefix in ["remember that ", "remember:"] where lowered.hasPrefix(prefix) {
            let fact = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fact.isEmpty else { return [] }
            return [MemoryItem(text: fact, scope: .global, source: .explicit)]
        }
        return []
    }
}
