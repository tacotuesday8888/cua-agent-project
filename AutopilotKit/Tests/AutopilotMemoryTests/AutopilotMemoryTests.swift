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

    @Test func deDuplicatesIdenticalMemory() async {
        let store = MemoryStore(directory: tempDirectory())
        let first = await store.add(MemoryItem(text: "same", scope: .global, source: .explicit))
        let second = await store.add(MemoryItem(text: "same", scope: .global, source: .explicit))
        #expect(first)
        #expect(!second)
        #expect(await store.all().count == 1)
    }
}
