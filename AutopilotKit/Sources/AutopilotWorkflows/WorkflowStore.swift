import Foundation

public enum WorkflowWriteResult: Sendable, Equatable {
    case stored
    case updated
    case duplicate
    case cleared
    case failed(String)
}

/// The local, on-disk store of reusable workflows.
///
/// Workflows are persisted as a JSON file in the app's Application Support
/// directory. All access is serialized through the actor, and the store is
/// capped so the file cannot grow without bound. Workflows must stay
/// secret-free (see `Workflow`).
public actor WorkflowStore {
    private let fileURL: URL
    /// The most workflows to keep; the least-recently-updated are dropped once a
    /// new one would push the store past this.
    private let limit: Int
    /// In-memory cache; `nil` until the first disk read.
    private var cache: [Workflow]?

    /// Create a store.
    ///
    /// - Parameters:
    ///   - directory: the directory holding `workflows.json`. Tests pass a
    ///     temporary directory; production uses Application Support.
    ///   - limit: how many of the most-recently-updated workflows to keep.
    public init(directory: URL? = nil, limit: Int = 200) {
        let directory = directory ?? Self.defaultDirectory()
        self.fileURL = directory.appendingPathComponent("workflows.json", isDirectory: false)
        self.limit = max(1, limit)
    }

    /// Every stored workflow, most-recently-updated first.
    public func all() -> [Workflow] {
        loaded().sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The workflow with the given id, if any.
    public func get(id: UUID) -> Workflow? {
        loaded().first { $0.id == id }
    }

    /// The workflow with the given name, case-insensitively, if any.
    public func get(name: String) -> Workflow? {
        let needle = name.lowercased()
        return loaded().first { $0.name.lowercased() == needle }
    }

    /// Store `workflow`, unless one with the same name already exists.
    /// Returns whether it was newly added.
    @discardableResult
    public func add(_ workflow: Workflow) -> Bool {
        addReporting(workflow) == .stored
    }

    /// Store `workflow` and report duplicate/write-failure cases separately.
    public func addReporting(_ workflow: Workflow) -> WorkflowWriteResult {
        var items = loaded()
        let name = workflow.name.lowercased()
        guard !items.contains(where: { $0.name.lowercased() == name }) else {
            return .duplicate
        }
        items.append(workflow)
        items = capped(items)
        if let error = commit(items) {
            return .failed("Could not save workflow: \(error)")
        }
        return .stored
    }

    /// Replace the stored workflow sharing `workflow.id` and stamp its updated
    /// time. Returns `.updated`, or `.duplicate` if no such workflow exists.
    @discardableResult
    public func update(_ workflow: Workflow) -> WorkflowWriteResult {
        var items = loaded()
        guard let index = items.firstIndex(where: { $0.id == workflow.id }) else {
            return .duplicate
        }
        var updated = workflow
        updated.updatedAt = Date()
        items[index] = updated
        if let error = commit(items) {
            return .failed("Could not save workflow: \(error)")
        }
        return .updated
    }

    /// Record a run's outcome: bump the run count (and, on success, the success
    /// count) and the updated time. Returns `.updated`, or `.duplicate` if the
    /// workflow no longer exists.
    @discardableResult
    public func recordRun(id: UUID, succeeded: Bool) -> WorkflowWriteResult {
        var items = loaded()
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return .duplicate
        }
        items[index].runCount += 1
        if succeeded {
            items[index].successCount += 1
        }
        items[index].updatedAt = Date()
        if let error = commit(items) {
            return .failed("Could not save workflow: \(error)")
        }
        return .updated
    }

    /// Delete the workflow with the given id.
    public func delete(id: UUID) {
        var items = loaded()
        let before = items.count
        items.removeAll { $0.id == id }
        guard items.count != before else { return }
        _ = commit(items)
    }

    /// Remove every stored workflow.
    public func clear() {
        _ = clearReporting()
    }

    /// Remove every stored workflow and report write failures separately.
    public func clearReporting() -> WorkflowWriteResult {
        guard !loaded().isEmpty else { return .cleared }
        if let error = commit([]) {
            return .failed("Could not clear workflows: \(error)")
        }
        return .cleared
    }

    // MARK: - Persistence

    /// Keep the most-recently-updated `limit` workflows; drop the rest.
    private func capped(_ items: [Workflow]) -> [Workflow] {
        guard items.count > limit else { return items }
        return Array(items.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    private func loaded() -> [Workflow] {
        if let cache { return cache }
        let items = Self.readItems(from: fileURL)
        cache = items
        return items
    }

    private func commit(_ items: [Workflow]) -> String? {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: fileURL, options: .atomic)
            cache = items
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func readItems(from url: URL) -> [Workflow] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Workflow].self, from: data)) ?? []
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MacAutopilot", isDirectory: true)
    }
}
