import Foundation

public enum RunHistoryWriteResult: Sendable, Equatable {
    case recorded
    case cleared
    case failed(String)
}

/// The local, on-disk log of finished agent runs.
///
/// History is persisted as a JSON file in the app's Application Support
/// directory. All access is serialized through the actor. Records are
/// metadata-only (see `RunRecord`); the store is capped so the file cannot
/// grow without bound.
public actor RunHistoryStore {
    private let fileURL: URL
    /// The most-recent records kept on disk; older runs are dropped.
    private let limit: Int
    /// In-memory cache; `nil` until the first disk read.
    private var cache: [RunRecord]?

    /// Create a store.
    ///
    /// - Parameters:
    ///   - directory: the directory holding `run-history.json`. Tests pass a
    ///     temporary directory; production uses Application Support.
    ///   - limit: how many of the most-recent runs to keep.
    public init(directory: URL? = nil, limit: Int = 200) {
        let directory = directory ?? Self.defaultDirectory()
        self.fileURL = directory.appendingPathComponent("run-history.json", isDirectory: false)
        self.limit = max(1, limit)
    }

    /// Append a finished run, dropping the oldest records past the limit.
    public func record(_ record: RunRecord) {
        _ = recordReporting(record)
    }

    /// Append a finished run and report write failures separately.
    public func recordReporting(_ record: RunRecord) -> RunHistoryWriteResult {
        var items = loaded()
        items.append(record)
        items.sort { $0.startedAt > $1.startedAt }
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        if let error = commit(items) {
            return .failed("Could not save run history: \(error)")
        }
        return .recorded
    }

    /// Every stored run, newest first.
    public func all() -> [RunRecord] {
        loaded().sorted { $0.startedAt > $1.startedAt }
    }

    /// The `count` most-recent runs, newest first.
    public func recent(_ count: Int) -> [RunRecord] {
        Array(all().prefix(max(0, count)))
    }

    /// Delete the run with the given id.
    public func delete(id: UUID) {
        var items = loaded()
        let before = items.count
        items.removeAll { $0.id == id }
        guard items.count != before else { return }
        _ = commit(items)
    }

    /// Remove every stored run.
    public func clear() {
        _ = clearReporting()
    }

    /// Remove every stored run and report write failures separately.
    public func clearReporting() -> RunHistoryWriteResult {
        guard !loaded().isEmpty else { return .cleared }
        if let error = commit([]) {
            return .failed("Could not clear run history: \(error)")
        }
        return .cleared
    }

    // MARK: - Persistence

    private func loaded() -> [RunRecord] {
        if let cache { return cache }
        let items = Self.readItems(from: fileURL)
        cache = items
        return items
    }

    private func commit(_ items: [RunRecord]) -> String? {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.backUpExistingFile(at: fileURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: fileURL, options: .atomic)
            cache = items
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func readItems(from url: URL) -> [RunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RunRecord].self, from: data)) ?? []
    }

    private static func backUpExistingFile(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".backup", isDirectory: false)
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MacAutopilot", isDirectory: true)
    }
}
