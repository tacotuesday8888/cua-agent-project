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

    /// The `@app` reference in a task, if any: the token following the first
    /// "@". Lets the user name the target app inline — "@Safari summarize the
    /// page" — instead of using the picker. An "@" inside a word (an email
    /// address, say) is left alone.
    public func appMention(in task: String) -> String? {
        for word in task.split(whereSeparator: \.isWhitespace) where word.hasPrefix("@") {
            let name = word.dropFirst().trimmingCharacters(in: .punctuationCharacters)
            if !name.isEmpty { return name }
        }
        return nil
    }
}
