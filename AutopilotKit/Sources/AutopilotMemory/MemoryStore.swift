import Foundation

/// The local, on-disk store of everything the agent remembers about the user.
///
/// Memory is persisted as a JSON file in the app's Application Support
/// directory and read back on demand. All access is serialized through the
/// actor. Relevant memory may later be included in an LLM request by
/// `AgentSession`, so this store must not be used for secrets.
public actor MemoryStore {
    private let fileURL: URL
    /// In-memory cache; `nil` until the first disk read.
    private var cache: [MemoryItem]?

    /// Create a store.
    ///
    /// - Parameter directory: the directory holding `memory.json`. Tests pass a
    ///   temporary directory; production uses Application Support.
    public init(directory: URL? = nil) {
        let directory = directory ?? Self.defaultDirectory()
        self.fileURL = directory.appendingPathComponent("memory.json", isDirectory: false)
    }

    /// Every stored memory, newest first.
    public func all() -> [MemoryItem] {
        loaded().sorted { $0.createdAt > $1.createdAt }
    }

    /// Store `item`, unless an identical text-and-scope pair already exists.
    /// Returns whether the item was newly added.
    @discardableResult
    public func add(_ item: MemoryItem) -> Bool {
        var items = loaded()
        guard !items.contains(where: { $0.text == item.text && $0.scope == item.scope }) else {
            return false
        }
        items.append(item)
        commit(items)
        return true
    }

    /// Delete the memory with the given id.
    public func delete(id: UUID) {
        var items = loaded()
        let before = items.count
        items.removeAll { $0.id == id }
        guard items.count != before else { return }
        commit(items)
    }

    /// The memories relevant to a task: every global memory, the target app's
    /// memories, and the memories of any named contact. Newest first.
    public func relevant(appName: String, contacts: [String] = []) -> [MemoryItem] {
        let app = appName.lowercased()
        let people = Set(contacts.map { $0.lowercased() })
        return all().filter { item in
            switch item.scope {
            case .global:
                true
            case .app(let name):
                name.lowercased() == app
            case .contact(let name):
                people.contains(name.lowercased())
            }
        }
    }

    // MARK: - Persistence

    private func loaded() -> [MemoryItem] {
        if let cache { return cache }
        let items = Self.readItems(from: fileURL)
        cache = items
        return items
    }

    private func commit(_ items: [MemoryItem]) {
        cache = items
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: fileURL, options: .atomic)
        } catch {
            // Memory is best-effort: a write failure must never fail a task.
        }
    }

    private static func readItems(from url: URL) -> [MemoryItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MemoryItem].self, from: data)) ?? []
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MacAutopilot", isDirectory: true)
    }
}
