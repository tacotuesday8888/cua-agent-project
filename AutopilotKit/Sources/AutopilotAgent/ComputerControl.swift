import AutopilotCore
import Foundation

/// One readiness check for the computer-use driver.
public struct ComputerDiagnosticCheck: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable {
        case passed
        case warning
        case failed
    }

    public let id: String
    public let status: Status
    public let title: String
    public let detail: String
    public let recovery: String?

    public init(
        id: String,
        status: Status,
        title: String,
        detail: String,
        recovery: String? = nil
    ) {
        self.id = id
        self.status = status
        self.title = title
        self.detail = detail
        self.recovery = recovery
    }
}

/// Readiness information for the selected target app and driver.
public struct ComputerDiagnostics: Sendable, Hashable, Codable {
    public let appName: String
    public let checks: [ComputerDiagnosticCheck]

    public init(appName: String, checks: [ComputerDiagnosticCheck]) {
        self.appName = appName
        self.checks = checks
    }

    public var isReady: Bool {
        !checks.contains { $0.status == .failed }
    }

    public var failures: [ComputerDiagnosticCheck] {
        checks.filter { $0.status == .failed }
    }

    public var warnings: [ComputerDiagnosticCheck] {
        checks.filter { $0.status == .warning }
    }

    public var summary: String {
        let failed = failures.count
        let warning = warnings.count
        if failed == 0 && warning == 0 {
            return "Driver readiness check passed for \(appName)."
        }
        return "Driver readiness check found \(failed) failure(s) and \(warning) warning(s) for \(appName)."
    }

    public var failureSummary: String {
        guard !failures.isEmpty else { return summary }
        let lines = failures.map { check in
            if let recovery = check.recovery, !recovery.isEmpty {
                return "\(check.title): \(check.detail) \(recovery)"
            }
            return "\(check.title): \(check.detail)"
        }
        return """
        \(summary)
        \(lines.joined(separator: "\n"))
        """
    }
}

/// Recovery-oriented driver errors returned to the agent as tool-result text.
public enum ComputerControlError: Error, Sendable, Equatable {
    case noCachedState(appName: String)
    case invalidElement(elementID: String, appName: String, turnIdentifier: Int?)
    case unavailableAction(elementID: String, action: String)
    case unsupportedTool(String)
}

extension ComputerControlError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noCachedState(let appName):
            return """
            No cached app state for \(appName). Call get_app_state before \
            interacting, then use element_index values from that latest result.
            """
        case .invalidElement(let elementID, let appName, let turnIdentifier):
            let turnText = turnIdentifier.map { " turn \($0)" } ?? ""
            return """
            No element \(elementID) exists in \(appName)'s latest app state\(turnText). \
            The UI may have changed. Call get_app_state again and use a current \
            element_index.
            """
        case .unavailableAction(let elementID, let action):
            return """
            \(action) is not available on \(elementID). Call get_app_state and use \
            one of the actions shown for that element.
            """
        case .unsupportedTool(let tool):
            return "\(tool) is not implemented by this driver yet."
        }
    }
}

/// A macOS app visible to the computer-use driver.
public struct ComputerAppInfo: Sendable, Hashable, Codable {
    public let name: String
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let isTarget: Bool

    public init(
        name: String,
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil,
        isTarget: Bool = false
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.isTarget = isTarget
    }
}

/// The current state returned by `get_app_state`.
public struct ComputerAppState: Sendable {
    public let snapshot: UITreeSnapshot
    public let screenshot: Data?
    /// Non-fatal reason a requested screenshot could not be returned. The tree
    /// is still valid and should remain available to the model.
    public let screenshotWarning: String?

    public init(
        snapshot: UITreeSnapshot,
        screenshot: Data? = nil,
        screenshotWarning: String? = nil
    ) {
        self.snapshot = snapshot
        self.screenshot = screenshot
        self.screenshotWarning = screenshotWarning
    }
}

/// The set of actions the agent can perform on a single controlled app.
///
/// The production implementation is backed by the macOS Accessibility APIs
/// (via cua's Driver); tests use `MockComputer`.
public protocol ComputerControl: Sendable {
    /// The name of the app this controller operates.
    var appName: String { get }

    /// Bring the target app forward and ready it for a run.
    ///
    /// Called once before `diagnose()`. Returns a short human-readable summary
    /// of what was done, or an empty string when nothing was. The default is a
    /// no-op; the macOS driver uses it to activate and unhide the target app
    /// so input and window reads land on a frontmost window.
    func prepare() async -> String

    /// Check whether the driver can read and control the selected target app.
    func diagnose() async -> ComputerDiagnostics

    /// List apps available to the driver.
    func listApps() async throws -> [ComputerAppInfo]

    /// Return the target app state.
    func getAppState(includeScreenshot: Bool) async throws -> ComputerAppState

    /// Capture the current accessibility-tree snapshot of the app.
    func captureTree() async throws -> UITreeSnapshot

    /// Press or activate the element with the given id.
    func click(elementID: String) async throws

    /// Set the text value of the element with the given id.
    func setValue(elementID: String, value: String) async throws

    /// Type text into the app's currently-focused editable element.
    func typeText(_ text: String) async throws

    /// Focus an editable element, when provided, then type text into the app.
    func typeText(_ text: String, into elementID: String?) async throws

    /// Scroll, optionally within a specific scrollable element.
    func scroll(elementID: String?, direction: ScrollDirection, amount: Int) async throws

    /// Send a key press to the app.
    func pressKey(_ key: KeyPress) async throws

    /// Drag from one captured element to another.
    func drag(fromElementID: String, toElementID: String) async throws

    /// Perform a non-primary AX action exposed by an element.
    func performSecondaryAction(elementID: String, action: String) async throws

    /// Capture a PNG screenshot of the app window.
    func captureScreenshot() async throws -> Data
}

public extension ComputerControl {
    func prepare() async -> String { "" }

    func diagnose() async -> ComputerDiagnostics {
        ComputerDiagnostics(appName: appName, checks: [
            ComputerDiagnosticCheck(
                id: "driver",
                status: .passed,
                title: "Driver",
                detail: "Default driver diagnostics are available."
            )
        ])
    }

    func listApps() async throws -> [ComputerAppInfo] {
        [
            ComputerAppInfo(
                name: appName,
                bundleIdentifier: nil,
                processIdentifier: nil,
                isTarget: true
            )
        ]
    }

    func getAppState(includeScreenshot: Bool) async throws -> ComputerAppState {
        let snapshot = try await captureTree()
        guard includeScreenshot else {
            return ComputerAppState(snapshot: snapshot)
        }

        do {
            return ComputerAppState(snapshot: snapshot, screenshot: try await captureScreenshot())
        } catch {
            return ComputerAppState(
                snapshot: snapshot,
                screenshotWarning: Self.screenshotWarning(for: error)
            )
        }
    }

    func typeText(_ text: String) async throws {
        throw ComputerControlError.unsupportedTool("type_text")
    }

    func typeText(_ text: String, into elementID: String?) async throws {
        if let elementID {
            try await click(elementID: elementID)
        }
        try await typeText(text)
    }

    func drag(fromElementID: String, toElementID: String) async throws {
        throw ComputerControlError.unsupportedTool("drag")
    }

    func performSecondaryAction(elementID: String, action: String) async throws {
        throw ComputerControlError.unsupportedTool("perform_secondary_action")
    }

    private static func screenshotWarning(for error: Error) -> String {
        let reason: String
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            reason = description
        } else {
            reason = String(describing: error)
        }
        return "Screenshot unavailable: \(reason)"
    }
}
