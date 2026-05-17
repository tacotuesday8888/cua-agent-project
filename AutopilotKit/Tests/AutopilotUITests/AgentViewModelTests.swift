import Testing
@testable import AutopilotUI

@MainActor
struct AgentViewModelTests {
    @Test func askQuestionWaitsForResolvedAnswer() async {
        let model = AgentViewModel()
        let answerTask = Task { @MainActor in
            await model.askQuestion("Which playlist should I use?")
        }

        await Task.yield()
        #expect(model.pendingQuestion?.text == "Which playlist should I use?")

        model.questionAnswerText = "Jazz"
        model.resolveQuestion(model.questionAnswerText)

        let answer = await answerTask.value
        #expect(answer == "Jazz")
        #expect(model.pendingQuestion == nil)
        #expect(model.questionAnswerText.isEmpty)
    }

    @Test func stopResumesPendingQuestionWithEmptyAnswer() async {
        let model = AgentViewModel()
        let answerTask = Task { @MainActor in
            await model.askQuestion("Which account?")
        }

        await Task.yield()
        #expect(model.pendingQuestion?.text == "Which account?")

        model.stop()

        let answer = await answerTask.value
        #expect(answer.isEmpty)
        #expect(model.pendingQuestion == nil)
    }
}
