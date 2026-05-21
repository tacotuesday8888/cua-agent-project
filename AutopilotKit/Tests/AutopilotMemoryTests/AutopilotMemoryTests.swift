import Foundation
import Testing
@testable import AutopilotMemory

struct MemoryScopeCodingTests {
    @Test func roundTripsGlobalScope() throws {
        let data = try JSONEncoder().encode(MemoryScope.global)
        #expect(try JSONDecoder().decode(MemoryScope.self, from: data) == .global)
    }

    @Test func roundTripsAppAndContactScopes() throws {
        for scope in [MemoryScope.app("Music"), .contact("Maya")] {
            let data = try JSONEncoder().encode(scope)
            #expect(try JSONDecoder().decode(MemoryScope.self, from: data) == scope)
        }
    }

    @Test func encodesFlatShape() throws {
        let data = try JSONEncoder().encode(MemoryScope.app("Music"))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"kind\""))
        #expect(json.contains("\"value\""))
        #expect(json.contains("Music"))
    }

    @Test func memoryItemRoundTrips() throws {
        let item = MemoryItem(text: "signs with —M", scope: .contact("Maya"), source: .explicit)
        let decoded = try JSONDecoder().decode(
            MemoryItem.self,
            from: JSONEncoder().encode(item)
        )
        #expect(decoded == item)
    }
}

struct MemoryStoreTests {
    private func tempDirectory() -> URL {
        URL.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test func addThenAllReturnsItem() async {
        let store = MemoryStore(directory: tempDirectory())
        let added = await store.add(MemoryItem(text: "likes dark mode", source: .explicit))
        #expect(added)
        let all = await store.all()
        #expect(all.count == 1)
        #expect(all.first?.text == "likes dark mode")
    }

    @Test func persistsAcrossInstances() async {
        let directory = tempDirectory()
        let first = MemoryStore(directory: directory)
        await first.add(MemoryItem(text: "signs with —M", source: .explicit))

        let second = MemoryStore(directory: directory)
        let all = await second.all()
        #expect(all.count == 1)
        #expect(all.first?.text == "signs with —M")
    }

    @Test func deleteRemovesItem() async {
        let store = MemoryStore(directory: tempDirectory())
        let item = MemoryItem(text: "transient", source: .proposed)
        await store.add(item)
        await store.delete(id: item.id)
        #expect(await store.all().isEmpty)
    }

    @Test func clearRemovesEveryMemory() async {
        let store = MemoryStore(directory: tempDirectory())
        await store.add(MemoryItem(text: "one", source: .explicit))
        await store.add(MemoryItem(text: "two", source: .explicit))
        await store.clear()
        #expect(await store.all().isEmpty)
    }

    @Test func relevantFiltersByScope() async {
        let store = MemoryStore(directory: tempDirectory())
        await store.add(MemoryItem(text: "global fact", scope: .global, source: .explicit))
        await store.add(MemoryItem(text: "music fact", scope: .app("Music"), source: .explicit))
        await store.add(MemoryItem(text: "mail fact", scope: .app("Mail"), source: .explicit))
        await store.add(MemoryItem(text: "maya fact", scope: .contact("Maya"), source: .explicit))

        let relevant = await store.relevant(appName: "music", taskText: "send Maya the setlist")
        let texts = Set(relevant.map(\.text))
        #expect(texts == ["global fact", "music fact", "maya fact"])
        #expect(!texts.contains("mail fact"))
    }

    @Test func contactMemoryMatchesWholeWordOnly() async {
        let store = MemoryStore(directory: tempDirectory())
        await store.add(MemoryItem(text: "sam fact", scope: .contact("Sam"), source: .explicit))

        let named = await store.relevant(appName: "App", taskText: "ping Sam about lunch")
        #expect(named.map(\.text) == ["sam fact"])

        // "Sam" must not surface as a substring of an unrelated word.
        let unrelated = await store.relevant(appName: "App", taskText: "write a summary")
        #expect(unrelated.isEmpty)
    }

    @Test func missingFileYieldsEmpty() async {
        let store = MemoryStore(directory: tempDirectory())
        #expect(await store.all().isEmpty)
    }

    @Test func corruptFileYieldsEmpty() async throws {
        let directory = tempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: directory.appending(path: "memory.json"))

        let store = MemoryStore(directory: directory)
        #expect(await store.all().isEmpty)
    }

    @Test func overwriteKeepsBackupOfPreviousFile() async throws {
        let directory = tempDirectory()
        let fileURL = directory.appending(path: "memory.json")
        let backupURL = directory.appending(path: "memory.json.backup")
        let store = MemoryStore(directory: directory)

        #expect(await store.addReporting(MemoryItem(
            text: "first memory",
            source: .explicit,
            createdAt: Date(timeIntervalSince1970: 1)
        )) == .stored)
        let originalData = try Data(contentsOf: fileURL)
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))

        #expect(await store.addReporting(MemoryItem(
            text: "second memory",
            source: .explicit,
            createdAt: Date(timeIntervalSince1970: 2)
        )) == .stored)

        #expect(try Data(contentsOf: backupURL) == originalData)
        let persisted = try JSONDecoder().decode([MemoryItem].self, from: Data(contentsOf: fileURL))
        #expect(Set(persisted.map(\.text)) == Set(["first memory", "second memory"]))
    }

    @Test func corruptFileIsBackedUpBeforeNextWrite() async throws {
        let directory = tempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: directory.appending(path: "memory.json"))

        let store = MemoryStore(directory: directory)
        #expect(await store.addReporting(MemoryItem(text: "fresh", source: .explicit)) == .stored)

        let backup = String(decoding: try Data(contentsOf: directory.appending(path: "memory.json.backup")), as: UTF8.self)
        #expect(backup == "not valid json")
        #expect(await store.all().map(\.text) == ["fresh"])
    }

    @Test func deDuplicatesIdenticalMemory() async {
        let store = MemoryStore(directory: tempDirectory())
        let first = await store.add(MemoryItem(text: "same", scope: .global, source: .explicit))
        let second = await store.add(MemoryItem(text: "same", scope: .global, source: .explicit))
        #expect(first)
        #expect(!second)
        #expect(await store.all().count == 1)
    }

    @Test func addReportingSurfacesWriteFailures() async throws {
        let notADirectory = tempDirectory()
        try Data("file, not directory".utf8).write(to: notADirectory)
        defer { try? FileManager.default.removeItem(at: notADirectory) }

        let store = MemoryStore(directory: notADirectory)
        let result = await store.addReporting(MemoryItem(text: "cannot persist", source: .explicit))

        guard case .failed(let message) = result else {
            Issue.record("expected addReporting to fail")
            return
        }
        #expect(message.contains("Could not save memory"))
        #expect(await store.all().isEmpty)
    }

    @Test func clearReportingSurfacesWriteFailures() async throws {
        let directory = tempDirectory()
        let store = MemoryStore(directory: directory)
        await store.add(MemoryItem(text: "persisted", source: .explicit))
        try FileManager.default.removeItem(at: directory)
        try Data("file, not directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await store.clearReporting()
        guard case .failed(let message) = result else {
            Issue.record("expected clearReporting to fail")
            return
        }
        #expect(message.contains("Could not clear memory"))
        #expect(await store.all().count == 1)
    }

    @Test func cappingDropsTheOldestMemories() async {
        let store = MemoryStore(directory: tempDirectory(), limit: 3)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<5 {
            await store.add(MemoryItem(
                text: "fact \(index)",
                source: .explicit,
                createdAt: base.addingTimeInterval(Double(index))
            ))
        }
        // Only the newest three survive the limit; the two oldest are dropped.
        let all = await store.all()
        #expect(all.count == 3)
        #expect(all.map(\.text) == ["fact 4", "fact 3", "fact 2"])
    }
}
