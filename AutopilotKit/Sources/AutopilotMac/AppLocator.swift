import AppKit
import Foundation

/// Discovers the running macOS apps the agent can operate.
///
/// `MacComputer` needs a process id to attach to; `AppLocator` resolves a
/// natural-language app reference (a name or bundle id) to a running process.
@MainActor
public struct AppLocator {
    /// A discovered running application.
    public struct RunningApp: Sendable, Hashable {
        public let name: String
        public let bundleIdentifier: String?
        public let processID: pid_t

        public init(name: String, bundleIdentifier: String?, processID: pid_t) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.processID = processID
        }
    }

    /// The result of resolving a user-provided app name or bundle id.
    public enum MatchResult: Sendable, Equatable {
        case matched(RunningApp)
        case notFound
        case ambiguous([RunningApp])
    }

    public init() {}

    /// All currently-running, regular (Dock-visible) applications.
    public func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return RunningApp(
                    name: name,
                    bundleIdentifier: app.bundleIdentifier,
                    processID: app.processIdentifier
                )
            }
    }

    /// Find a running app whose name or bundle id matches `query`
    /// (case-insensitive). An exact name match is preferred over a substring.
    public func runningApp(matching query: String) -> RunningApp? {
        Self.match(query, in: runningApps())
    }

    /// Resolve a running app and preserve why resolution failed.
    public func resolveRunningApp(matching query: String) -> MatchResult {
        Self.resolve(query, in: runningApps())
    }

    /// Resolve `query` against `apps`. Exact name or bundle-id matches win.
    /// Fuzzy matches are accepted only when they resolve to one app; ambiguous
    /// queries match nothing, rather than risking control of the wrong app.
    nonisolated static func match(_ query: String, in apps: [RunningApp]) -> RunningApp? {
        guard case .matched(let app) = resolve(query, in: apps) else { return nil }
        return app
    }

    /// Resolve `query` against `apps` and distinguish not-found from ambiguous
    /// matches so callers can tell the user what happened.
    nonisolated static func resolve(_ query: String, in apps: [RunningApp]) -> MatchResult {
        let needle = normalized(query)
        guard !needle.isEmpty else { return .notFound }
        let exactNames = apps.filter { normalized($0.name) == needle }
        if let exact = unique(exactNames) {
            return .matched(exact)
        }
        if exactNames.count > 1 {
            return .ambiguous(exactNames)
        }
        let exactBundles = apps.filter {
            $0.bundleIdentifier.map(normalized) == needle
        }
        if let exactBundle = unique(exactBundles) {
            return .matched(exactBundle)
        }
        if exactBundles.count > 1 {
            return .ambiguous(exactBundles)
        }
        let fuzzyMatches = apps.filter { app in
            normalized(app.name).contains(needle)
                || (app.bundleIdentifier.map(normalized)?.contains(needle) ?? false)
        }
        if let fuzzy = unique(fuzzyMatches) {
            return .matched(fuzzy)
        }
        return fuzzyMatches.isEmpty ? .notFound : .ambiguous(fuzzyMatches)
    }

    /// The frontmost regular application, if any.
    public func frontmostApp() -> RunningApp? {
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            let name = app.localizedName
        else { return nil }
        return RunningApp(
            name: name,
            bundleIdentifier: app.bundleIdentifier,
            processID: app.processIdentifier
        )
    }

    private nonisolated static func unique(_ apps: [RunningApp]) -> RunningApp? {
        apps.count == 1 ? apps[0] : nil
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
