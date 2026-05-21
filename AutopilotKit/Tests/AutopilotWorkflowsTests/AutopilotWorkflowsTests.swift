import Foundation
import Testing
@testable import AutopilotWorkflows

struct WorkflowTests {
    @Test func roundTripsThroughCodable() throws {
        let workflow = makeWorkflow(
            recipe: "Open the compose window, fill the fields, send.",
            variables: [
                WorkflowVariable(name: "recipient", description: "Who to email", defaultValue: "team@x.co"),
                WorkflowVariable(name: "subject", description: "The subject line")
            ]
        )
        let decoded = try JSONDecoder().decode(
            Workflow.self,
            from: JSONEncoder().encode(workflow)
        )
        #expect(decoded == workflow)
    }

    @Test func recipeIsTruncatedToMaxLength() {
        let long = String(repeating: "a", count: Workflow.maxRecipeLength + 50)
        #expect(makeWorkflow(recipe: long).recipe.count == Workflow.maxRecipeLength)
    }

    @Test func shortRecipeIsKeptVerbatim() {
        #expect(makeWorkflow(recipe: "short recipe").recipe == "short recipe")
    }

    @Test func successRateIsZeroWhenNeverRun() {
        #expect(makeWorkflow(runCount: 0, successCount: 0).successRate == 0)
    }

    @Test func successRateIsFractionOfRuns() {
        #expect(makeWorkflow(runCount: 4, successCount: 1).successRate == 0.25)
    }

    @Test func variableNamesListsDeclaredNames() {
        let workflow = makeWorkflow(variables: [
            WorkflowVariable(name: "recipient"),
            WorkflowVariable(name: "subject")
        ])
        #expect(workflow.variableNames == ["recipient", "subject"])
    }
}

struct WorkflowRendererTests {
    @Test func substitutesBoundSlot() {
        let goal = WorkflowRenderer.resolveGoal(
            template: "Email {{recipient}} now",
            bindings: ["recipient": "Maya"]
        )
        #expect(goal == "Email Maya now")
    }

    @Test func leavesUnboundSlotLiteral() {
        let goal = WorkflowRenderer.resolveGoal(
            template: "Email {{recipient}} now",
            bindings: [:]
        )
        #expect(goal == "Email {{recipient}} now")
    }

    @Test func substitutesRepeatedSlot() {
        let goal = WorkflowRenderer.resolveGoal(
            template: "{{name}} and {{name}}",
            bindings: ["name": "Sam"]
        )
        #expect(goal == "Sam and Sam")
    }

    @Test func substitutesAdjacentSlots() {
        let goal = WorkflowRenderer.resolveGoal(
            template: "{{a}}{{b}}",
            bindings: ["a": "1", "b": "2"]
        )
        #expect(goal == "12")
    }

    @Test func mixesBoundAndUnboundSlots() {
        let goal = WorkflowRenderer.resolveGoal(
            template: "{{greeting}}, {{name}}!",
            bindings: ["greeting": "Hello"]
        )
        #expect(goal == "Hello, {{name}}!")
    }

    @Test func leavesPlainTextUnchanged() {
        #expect(
            WorkflowRenderer.resolveGoal(template: "no slots here", bindings: ["x": "y"])
                == "no slots here"
        )
    }

    @Test func keepsUnclosedTokenVerbatim() {
        #expect(
            WorkflowRenderer.resolveGoal(template: "open {{x and more", bindings: ["x": "v"])
                == "open {{x and more"
        )
    }

    @Test func trimsWhitespaceInSlotName() {
        #expect(
            WorkflowRenderer.resolveGoal(template: "hi {{ name }}", bindings: ["name": "Sam"])
                == "hi Sam"
        )
    }

    @Test func resolvedBindingsUseDefaultsWhenNoRunValueExists() {
        let bindings = WorkflowRenderer.resolvedBindings(
            variables: [WorkflowVariable(name: "recipient", defaultValue: "Maya")],
            bindings: [:]
        )
        #expect(bindings["recipient"] == "Maya")
    }

    @Test func resolvedBindingsPreferRunValuesOverDefaults() {
        let bindings = WorkflowRenderer.resolvedBindings(
            variables: [WorkflowVariable(name: "recipient", defaultValue: "Maya")],
            bindings: ["recipient": "Sam"]
        )
        #expect(bindings["recipient"] == "Sam")
    }

    @Test func missingSlotNamesReportsUnfilledTemplateSlots() {
        let missing = WorkflowRenderer.missingSlotNames(
            in: "Email {{recipient}} about {{topic}}",
            variables: [WorkflowVariable(name: "recipient")],
            bindings: ["recipient": "Maya"]
        )
        #expect(missing == ["topic"])
    }

    @Test func missingSlotNamesTreatsWhitespaceValuesAsMissing() {
        let missing = WorkflowRenderer.missingSlotNames(
            in: "Email {{recipient}}",
            variables: [WorkflowVariable(name: "recipient")],
            bindings: ["recipient": "  "]
        )
        #expect(missing == ["recipient"])
    }

    @Test func missingSlotNamesAcceptsDefaults() {
        let missing = WorkflowRenderer.missingSlotNames(
            in: "Email {{recipient}}",
            variables: [WorkflowVariable(name: "recipient", defaultValue: "Maya")],
            bindings: [:]
        )
        #expect(missing.isEmpty)
    }

    @Test func summaryListsVariableSlots() {
        let summary = WorkflowRenderer.summary(for: makeWorkflow(
            name: "Weekly report",
            appName: "Mail",
            variables: [WorkflowVariable(name: "recipient")]
        ))
        #expect(summary == "Weekly report · Mail · {{recipient}}")
    }
}

struct WorkflowStoreTests {
    private func tempDirectory() -> URL {
        URL.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test func addThenAllReturnsWorkflow() async {
        let store = WorkflowStore(directory: tempDirectory())
        await store.add(makeWorkflow(name: "Weekly report"))
        let all = await store.all()
        #expect(all.count == 1)
        #expect(all.first?.name == "Weekly report")
    }

    @Test func persistsAcrossInstances() async {
        let directory = tempDirectory()
        let first = WorkflowStore(directory: directory)
        await first.add(makeWorkflow(name: "First"))

        let second = WorkflowStore(directory: directory)
        let all = await second.all()
        #expect(all.count == 1)
        #expect(all.first?.name == "First")
    }

    @Test func allIsSortedByUpdatedNewestFirst() async {
        let store = WorkflowStore(directory: tempDirectory())
        let base = Date(timeIntervalSince1970: 1_000_000)
        await store.add(makeWorkflow(name: "oldest", updatedAt: base))
        await store.add(makeWorkflow(name: "newest", updatedAt: base.addingTimeInterval(200)))
        await store.add(makeWorkflow(name: "middle", updatedAt: base.addingTimeInterval(100)))

        #expect(await store.all().map(\.name) == ["newest", "middle", "oldest"])
    }

    @Test func getByIDReturnsWorkflow() async {
        let store = WorkflowStore(directory: tempDirectory())
        let workflow = makeWorkflow(name: "Find me")
        await store.add(workflow)
        #expect(await store.get(id: workflow.id)?.name == "Find me")
    }

    @Test func getByNameIsCaseInsensitive() async {
        let store = WorkflowStore(directory: tempDirectory())
        await store.add(makeWorkflow(name: "Weekly Report"))
        #expect(await store.get(name: "weekly report")?.name == "Weekly Report")
    }

    @Test func duplicateNameIsRejectedCaseInsensitively() async {
        let store = WorkflowStore(directory: tempDirectory())
        let first = await store.addReporting(makeWorkflow(name: "Daily"))
        let second = await store.addReporting(makeWorkflow(name: "daily"))
        #expect(first == .stored)
        #expect(second == .duplicate)
        #expect(await store.all().count == 1)
    }

    @Test func updateReplacesWorkflow() async {
        let store = WorkflowStore(directory: tempDirectory())
        var workflow = makeWorkflow(name: "Editable", goalTemplate: "do {{x}}")
        await store.add(workflow)
        workflow = Workflow(
            id: workflow.id,
            name: workflow.name,
            appName: workflow.appName,
            goalTemplate: "do {{x}} carefully",
            source: workflow.source
        )
        let result = await store.update(workflow)
        #expect(result == .updated)
        #expect(await store.get(id: workflow.id)?.goalTemplate == "do {{x}} carefully")
    }

    @Test func updateRejectsNameCollision() async {
        let store = WorkflowStore(directory: tempDirectory())
        let first = makeWorkflow(name: "Morning report")
        let second = makeWorkflow(name: "Evening report")
        await store.add(first)
        await store.add(second)

        let renamedSecond = Workflow(
            id: second.id,
            name: "morning report",
            appName: second.appName,
            goalTemplate: second.goalTemplate,
            source: second.source
        )

        #expect(await store.update(renamedSecond) == .duplicate)
        #expect(await store.all().map(\.name).sorted() == ["Evening report", "Morning report"])
    }

    @Test func updateMissingWorkflowReturnsDuplicate() async {
        let store = WorkflowStore(directory: tempDirectory())
        #expect(await store.update(makeWorkflow(name: "ghost")) == .duplicate)
    }

    @Test func recordRunBumpsRunAndSuccessCounts() async {
        let store = WorkflowStore(directory: tempDirectory())
        let workflow = makeWorkflow(name: "Counted")
        await store.add(workflow)
        await store.recordRun(id: workflow.id, succeeded: true)
        let stored = await store.get(id: workflow.id)
        #expect(stored?.runCount == 1)
        #expect(stored?.successCount == 1)
    }

    @Test func recordRunFailureBumpsOnlyRunCount() async {
        let store = WorkflowStore(directory: tempDirectory())
        let workflow = makeWorkflow(name: "Counted")
        await store.add(workflow)
        await store.recordRun(id: workflow.id, succeeded: false)
        let stored = await store.get(id: workflow.id)
        #expect(stored?.runCount == 1)
        #expect(stored?.successCount == 0)
    }

    @Test func recordRunMissingWorkflowReturnsDuplicate() async {
        let store = WorkflowStore(directory: tempDirectory())
        #expect(await store.recordRun(id: UUID(), succeeded: true) == .duplicate)
    }

    @Test func capDropsLeastRecentlyUpdatedPastLimit() async {
        let store = WorkflowStore(directory: tempDirectory(), limit: 3)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for offset in 0..<6 {
            await store.add(makeWorkflow(
                name: "wf \(offset)",
                updatedAt: base.addingTimeInterval(Double(offset) * 60)
            ))
        }
        #expect(await store.all().map(\.name) == ["wf 5", "wf 4", "wf 3"])
    }

    @Test func deleteRemovesWorkflow() async {
        let store = WorkflowStore(directory: tempDirectory())
        let workflow = makeWorkflow(name: "transient")
        await store.add(workflow)
        await store.delete(id: workflow.id)
        #expect(await store.all().isEmpty)
    }

    @Test func clearEmptiesStore() async {
        let store = WorkflowStore(directory: tempDirectory())
        await store.add(makeWorkflow(name: "one"))
        await store.add(makeWorkflow(name: "two"))
        await store.clear()
        #expect(await store.all().isEmpty)
    }

    @Test func addReportingSurfacesWriteFailures() async throws {
        let notADirectory = tempDirectory()
        try Data("file, not directory".utf8).write(to: notADirectory)
        defer { try? FileManager.default.removeItem(at: notADirectory) }

        let store = WorkflowStore(directory: notADirectory)
        let result = await store.addReporting(makeWorkflow(name: "cannot persist"))

        guard case .failed(let message) = result else {
            Issue.record("expected addReporting to fail")
            return
        }
        #expect(message.contains("Could not save workflow"))
        #expect(await store.all().isEmpty)
    }

    @Test func missingFileYieldsEmpty() async {
        let store = WorkflowStore(directory: tempDirectory())
        #expect(await store.all().isEmpty)
    }

    @Test func corruptFileYieldsEmpty() async throws {
        let directory = tempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not valid json".utf8)
            .write(to: directory.appending(path: "workflows.json"))

        let store = WorkflowStore(directory: directory)
        #expect(await store.all().isEmpty)
    }

    @Test func overwriteKeepsBackupOfPreviousFile() async throws {
        let directory = tempDirectory()
        let fileURL = directory.appending(path: "workflows.json")
        let backupURL = directory.appending(path: "workflows.json.backup")
        let store = WorkflowStore(directory: directory)
        let base = Date(timeIntervalSince1970: 1_000_000)

        #expect(await store.addReporting(makeWorkflow(name: "First", updatedAt: base)) == .stored)
        let originalData = try Data(contentsOf: fileURL)
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))

        #expect(await store.addReporting(makeWorkflow(
            name: "Second",
            updatedAt: base.addingTimeInterval(60)
        )) == .stored)

        #expect(try Data(contentsOf: backupURL) == originalData)
        let persisted = try JSONDecoder().decode([Workflow].self, from: Data(contentsOf: fileURL))
        #expect(persisted.map(\.name) == ["First", "Second"])
    }

    @Test func corruptFileIsBackedUpBeforeNextWrite() async throws {
        let directory = tempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not valid json".utf8)
            .write(to: directory.appending(path: "workflows.json"))

        let store = WorkflowStore(directory: directory)
        #expect(await store.addReporting(makeWorkflow(name: "Fresh")) == .stored)

        let backup = String(
            decoding: try Data(contentsOf: directory.appending(path: "workflows.json.backup")),
            as: UTF8.self
        )
        #expect(backup == "not valid json")
        #expect(await store.all().map(\.name) == ["Fresh"])
    }
}

/// Build a `Workflow` with sensible defaults for tests.
private func makeWorkflow(
    name: String = "Weekly report",
    appName: String = "Mail",
    goalTemplate: String = "Email {{recipient}} the weekly report",
    recipe: String = "",
    variables: [WorkflowVariable] = [WorkflowVariable(name: "recipient", description: "Who to email")],
    source: WorkflowSource = .manual,
    updatedAt: Date = Date(),
    runCount: Int = 0,
    successCount: Int = 0
) -> Workflow {
    Workflow(
        name: name,
        appName: appName,
        goalTemplate: goalTemplate,
        recipe: recipe,
        variables: variables,
        source: source,
        updatedAt: updatedAt,
        runCount: runCount,
        successCount: successCount
    )
}
