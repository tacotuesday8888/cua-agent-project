import Foundation
import Testing
@testable import AutopilotHistory

struct RunRecordTests {
    @Test func roundTripsThroughCodable() throws {
        let record = makeRecord(task: "play jazz", actions: ["get_app_state", "click"])
        let decoded = try JSONDecoder().decode(
            RunRecord.self,
            from: JSONEncoder().encode(record)
        )
        #expect(decoded == record)
    }

    @Test func actionCountReflectsActions() {
        let record = makeRecord(actions: ["get_app_state", "click", "type_text"])
        #expect(record.actionCount == 3)
    }

    @Test func totalTokensSumsInputAndOutput() {
        let record = makeRecord(inputTokens: 1200, outputTokens: 340)
        #expect(record.totalTokens == 1540)
        #expect(record.compactTokens == "1.5k")
    }

    @Test func compactTokensStaysExactBelowAThousand() {
        #expect(makeRecord(inputTokens: 200, outputTokens: 50).compactTokens == "250")
    }

    @Test func durationIsNeverNegative() {
        let now = Date()
        let record = makeRecord(startedAt: now, finishedAt: now.addingTimeInterval(-5))
        #expect(record.duration == 0)
    }
}

struct RunHistoryStoreTests {
    private func tempDirectory() -> URL {
        URL.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test func recordThenAllReturnsRun() async {
        let store = RunHistoryStore(directory: tempDirectory())
        await store.record(makeRecord(task: "play jazz"))
        let all = await store.all()
        #expect(all.count == 1)
        #expect(all.first?.task == "play jazz")
    }

    @Test func persistsAcrossInstances() async {
        let directory = tempDirectory()
        let first = RunHistoryStore(directory: directory)
        await first.record(makeRecord(task: "first run"))

        let second = RunHistoryStore(directory: directory)
        let all = await second.all()
        #expect(all.count == 1)
        #expect(all.first?.task == "first run")
    }

    @Test func allIsSortedNewestFirst() async {
        let store = RunHistoryStore(directory: tempDirectory())
        let base = Date(timeIntervalSince1970: 1_000_000)
        await store.record(makeRecord(task: "oldest", startedAt: base))
        await store.record(makeRecord(task: "newest", startedAt: base.addingTimeInterval(200)))
        await store.record(makeRecord(task: "middle", startedAt: base.addingTimeInterval(100)))

        let tasks = await store.all().map(\.task)
        #expect(tasks == ["newest", "middle", "oldest"])
    }

    @Test func recentReturnsNewestSubset() async {
        let store = RunHistoryStore(directory: tempDirectory())
        let base = Date(timeIntervalSince1970: 1_000_000)
        for offset in 0..<5 {
            await store.record(makeRecord(
                task: "run \(offset)",
                startedAt: base.addingTimeInterval(Double(offset) * 60)
            ))
        }

        let recent = await store.recent(2)
        #expect(recent.map(\.task) == ["run 4", "run 3"])
    }

    @Test func capDropsOldestPastLimit() async {
        let store = RunHistoryStore(directory: tempDirectory(), limit: 3)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for offset in 0..<6 {
            await store.record(makeRecord(
                task: "run \(offset)",
                startedAt: base.addingTimeInterval(Double(offset) * 60)
            ))
        }

        let tasks = await store.all().map(\.task)
        #expect(tasks == ["run 5", "run 4", "run 3"])
    }

    @Test func deleteRemovesRun() async {
        let store = RunHistoryStore(directory: tempDirectory())
        let record = makeRecord(task: "transient")
        await store.record(record)
        await store.delete(id: record.id)
        #expect(await store.all().isEmpty)
    }

    @Test func clearEmptiesHistory() async {
        let store = RunHistoryStore(directory: tempDirectory())
        await store.record(makeRecord(task: "one"))
        await store.record(makeRecord(task: "two"))
        await store.clear()
        #expect(await store.all().isEmpty)
    }

    @Test func recordReportingSurfacesWriteFailures() async throws {
        let notADirectory = tempDirectory()
        try Data("file, not directory".utf8).write(to: notADirectory)
        defer { try? FileManager.default.removeItem(at: notADirectory) }

        let store = RunHistoryStore(directory: notADirectory)
        let result = await store.recordReporting(makeRecord(task: "cannot persist"))

        guard case .failed(let message) = result else {
            Issue.record("expected recordReporting to fail")
            return
        }
        #expect(message.contains("Could not save run history"))
        #expect(await store.all().isEmpty)
    }

    @Test func missingFileYieldsEmpty() async {
        let store = RunHistoryStore(directory: tempDirectory())
        #expect(await store.all().isEmpty)
    }

    @Test func corruptFileYieldsEmpty() async throws {
        let directory = tempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not valid json".utf8)
            .write(to: directory.appending(path: "run-history.json"))

        let store = RunHistoryStore(directory: directory)
        #expect(await store.all().isEmpty)
    }

    @Test func overwriteKeepsBackupOfPreviousFile() async throws {
        let directory = tempDirectory()
        let fileURL = directory.appending(path: "run-history.json")
        let backupURL = directory.appending(path: "run-history.json.backup")
        let store = RunHistoryStore(directory: directory)
        let base = Date(timeIntervalSince1970: 1_000_000)

        #expect(await store.recordReporting(makeRecord(task: "first run", startedAt: base)) == .recorded)
        let originalData = try Data(contentsOf: fileURL)
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))

        #expect(await store.recordReporting(makeRecord(
            task: "second run",
            startedAt: base.addingTimeInterval(60)
        )) == .recorded)

        #expect(try Data(contentsOf: backupURL) == originalData)
        let persisted = try JSONDecoder().decode([RunRecord].self, from: Data(contentsOf: fileURL))
        #expect(persisted.map(\.task) == ["second run", "first run"])
    }

    @Test func corruptFileIsBackedUpBeforeNextWrite() async throws {
        let directory = tempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not valid json".utf8)
            .write(to: directory.appending(path: "run-history.json"))

        let store = RunHistoryStore(directory: directory)
        #expect(await store.recordReporting(makeRecord(task: "fresh run")) == .recorded)

        let backup = String(
            decoding: try Data(contentsOf: directory.appending(path: "run-history.json.backup")),
            as: UTF8.self
        )
        #expect(backup == "not valid json")
        #expect(await store.all().map(\.task) == ["fresh run"])
    }
}

/// Build a `RunRecord` with sensible defaults for tests.
private func makeRecord(
    task: String = "task",
    appName: String = "Music",
    model: String = "test-model",
    status: RunStatus = .completed,
    summary: String = "Done.",
    actions: [String] = [],
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    startedAt: Date = Date(),
    finishedAt: Date? = nil
) -> RunRecord {
    RunRecord(
        task: task,
        appName: appName,
        model: model,
        status: status,
        summary: summary,
        actions: actions,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        startedAt: startedAt,
        finishedAt: finishedAt ?? startedAt.addingTimeInterval(12)
    )
}
