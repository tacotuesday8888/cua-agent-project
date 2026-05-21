import AutopilotAgent

/// Pure readiness logic for the macOS driver.
///
/// `MacComputer.diagnose()` gathers live system facts and hands them here, so
/// the readiness rules can be unit-tested without a running app or TCC grants.
enum MacDriverDiagnostics {
    /// The outcome of probing the target app's windows.
    enum WindowProbe: Sendable, Equatable {
        /// A readable window was found. `windowMatched` is whether it could be
        /// paired with a CoreGraphics window id for screenshot fallback.
        case readable(elementCount: Int, windowMatched: Bool)
        /// The app exposes no window the driver can read.
        case noWindow
        /// A window exists but is minimized, so the driver cannot act on it.
        case minimized
        /// Reading the tree failed for some other reason.
        case failed(String)
    }

    /// The live facts gathered for one readiness check.
    struct Inputs: Sendable {
        var appName: String
        /// Process facts, or `nil` when nothing runs under the target pid.
        var process: TargetProcessState?
        var accessibilityTrusted: Bool
        var screenRecordingTrusted: Bool
        /// The window probe result, or `nil` when probing was skipped because
        /// an earlier check already failed.
        var window: WindowProbe?
    }

    /// Whether probing the target's windows is worthwhile given earlier facts.
    ///
    /// A window read only succeeds when the app is running, visible, and the
    /// driver is Accessibility-trusted, so anything else skips the probe.
    static func shouldProbeWindows(
        process: TargetProcessState?,
        accessibilityTrusted: Bool
    ) -> Bool {
        guard let process else { return false }
        return accessibilityTrusted && !process.isTerminated && !process.isHidden
    }

    /// Build the ordered readiness checks for the gathered inputs.
    static func checks(for inputs: Inputs) -> [ComputerDiagnosticCheck] {
        var checks = [targetAppCheck(inputs)]
        checks.append(accessibilityCheck(inputs))
        checks.append(screenRecordingCheck(inputs))
        if let window = inputs.window {
            checks.append(contentsOf: windowChecks(window, appName: inputs.appName))
        }
        return checks
    }

    private static func targetAppCheck(_ inputs: Inputs) -> ComputerDiagnosticCheck {
        let appName = inputs.appName
        guard let process = inputs.process, !process.isTerminated else {
            return ComputerDiagnosticCheck(
                id: "target-app",
                status: .failed,
                title: "Target app",
                detail: "\(appName) is not running.",
                recovery: "Open the app, select it again, then start the task."
            )
        }
        if process.isHidden {
            return ComputerDiagnosticCheck(
                id: "target-app",
                status: .failed,
                title: "Target app",
                detail: "\(appName) is running but hidden, so its windows cannot be read.",
                recovery: "Unhide \(appName) (click its Dock icon), then start the task again."
            )
        }
        return ComputerDiagnosticCheck(
            id: "target-app",
            status: .passed,
            title: "Target app",
            detail: "\(appName) is running."
        )
    }

    private static func accessibilityCheck(_ inputs: Inputs) -> ComputerDiagnosticCheck {
        ComputerDiagnosticCheck(
            id: "accessibility",
            status: inputs.accessibilityTrusted ? .passed : .failed,
            title: "Accessibility permission",
            detail: inputs.accessibilityTrusted
                ? "Mac Autopilot can read and control other app UIs."
                : "Mac Autopilot does not have Accessibility permission.",
            recovery: inputs.accessibilityTrusted
                ? nil
                : "Grant Accessibility in System Settings > Privacy & Security > Accessibility."
        )
    }

    private static func screenRecordingCheck(_ inputs: Inputs) -> ComputerDiagnosticCheck {
        ComputerDiagnosticCheck(
            id: "screen-recording",
            status: inputs.screenRecordingTrusted ? .passed : .warning,
            title: "Screen Recording permission",
            detail: inputs.screenRecordingTrusted
                ? "Target-window screenshots are available."
                : "Screen Recording is not granted, so screenshot fallback may fail.",
            recovery: inputs.screenRecordingTrusted
                ? nil
                : "Grant Screen Recording in System Settings > Privacy & Security > Screen Recording."
        )
    }

    private static func windowChecks(
        _ probe: WindowProbe,
        appName: String
    ) -> [ComputerDiagnosticCheck] {
        switch probe {
        case let .readable(elementCount, windowMatched):
            return [
                ComputerDiagnosticCheck(
                    id: "accessibility-tree",
                    status: .passed,
                    title: "Accessibility tree",
                    detail: "Read \(elementCount) accessibility element(s) from the target window."
                ),
                ComputerDiagnosticCheck(
                    id: "window-match",
                    status: windowMatched ? .passed : .warning,
                    title: "Target window match",
                    detail: windowMatched
                        ? "Matched the target window to a CoreGraphics window id."
                        : "Could not match the AX window to a CoreGraphics window id.",
                    recovery: windowMatched
                        ? nil
                        : "The driver can still use AX, but screenshot fallback is disabled until the target window can be matched."
                )
            ]
        case .noWindow:
            return [ComputerDiagnosticCheck(
                id: "accessibility-tree",
                status: .failed,
                title: "Accessibility tree",
                detail: "\(appName) exposes no window the driver can read.",
                recovery: "Open a window in \(appName) and make sure it is not minimized, then start the task again."
            )]
        case .minimized:
            return [ComputerDiagnosticCheck(
                id: "accessibility-tree",
                status: .failed,
                title: "Accessibility tree",
                detail: "\(appName)'s window is minimized, so the driver cannot read or act on it.",
                recovery: "Unminimize the \(appName) window (click it in the Dock), then start the task again."
            )]
        case let .failed(message):
            return [ComputerDiagnosticCheck(
                id: "accessibility-tree",
                status: .failed,
                title: "Accessibility tree",
                detail: "Could not read \(appName)'s accessibility tree: \(message).",
                recovery: "Call get_app_state after confirming the app is visible and permissions are granted."
            )]
        }
    }
}
