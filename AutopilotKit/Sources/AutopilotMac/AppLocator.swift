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
        let apps = runningApps()
        let needle = query.lowercased()
        if let exact = apps.first(where: { $0.name.lowercased() == needle }) {
            return exact
        }
        return apps.first { app in
            app.name.lowercased().contains(needle)
                || (app.bundleIdentifier?.lowercased().contains(needle) ?? false)
        }
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
}
