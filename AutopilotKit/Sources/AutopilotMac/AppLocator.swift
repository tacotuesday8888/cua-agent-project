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

    /// Resolve `query` against `apps`. Exact name or bundle-id matches win.
    /// Fuzzy matches are accepted only when they resolve to one app; ambiguous
    /// queries match nothing, rather than risking control of the wrong app.
    nonisolated static func match(_ query: String, in apps: [RunningApp]) -> RunningApp? {
        let needle = normalized(query)
        guard !needle.isEmpty else { return nil }
        if let exact = unique(apps.filter { normalized($0.name) == needle }) {
            return exact
        }
        if let exactBundle = unique(apps.filter {
            $0.bundleIdentifier.map(normalized) == needle
        }) {
            return exactBundle
        }
        return unique(apps.filter { app in
            normalized(app.name).contains(needle)
                || (app.bundleIdentifier.map(normalized)?.contains(needle) ?? false)
        })
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
