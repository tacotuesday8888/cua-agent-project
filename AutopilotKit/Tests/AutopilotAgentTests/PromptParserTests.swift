import AutopilotMemory
import Testing
@testable import AutopilotAgent

struct PromptParserTests {
    private let parser = PromptParser()

    @Test func parsesLeadingRememberColon() {
        let memories = parser.explicitMemories(in: "remember: I prefer dark mode")
        #expect(memories.count == 1)
        #expect(memories.first?.text == "I prefer dark mode")
        #expect(memories.first?.source == .explicit)
        #expect(memories.first?.scope == .global)
    }

    @Test func parsesRememberThatCaseInsensitively() {
        let memories = parser.explicitMemories(in: "Remember that Maya gets a casual tone")
        #expect(memories.first?.text == "Maya gets a casual tone")
    }

    @Test func ignoresNonLeadingRemember() {
        #expect(parser.explicitMemories(in: "please remember to call mom").isEmpty)
    }

    @Test func ignoresRememberInsideATaskVerb() {
        #expect(parser.explicitMemories(in: "remember to reply to the email").isEmpty)
    }

    @Test func returnsEmptyForPlainTask() {
        #expect(parser.explicitMemories(in: "play some jazz").isEmpty)
    }

    @Test func ignoresEmptyFact() {
        #expect(parser.explicitMemories(in: "remember:").isEmpty)
    }
}
