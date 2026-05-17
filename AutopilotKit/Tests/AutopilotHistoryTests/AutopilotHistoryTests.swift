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
}

/// Build a `RunRecord` with sensible defaults for tests.
private func makeRecord(
    task: String = "task",
    appName: String = "Music",
    model: String = "test-model",
    status: RunStatus = .completed,
    summary: String = "Done.",
    actions: [String] = [],
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
        startedAt: startedAt,
        finishedAt: finishedAt ?? startedAt.addingTimeInterval(12)
    )
}
