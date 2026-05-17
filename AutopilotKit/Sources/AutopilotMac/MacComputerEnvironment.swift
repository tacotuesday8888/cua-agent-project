import AppKit
import AutopilotPerception
import CoreGraphics
import Foundation

/// Running-process facts the macOS driver needs to assess readiness.
public struct TargetProcessState: Sendable, Hashable {
    /// Whether the process has terminated.
    public var isTerminated: Bool
    /// Whether the app is hidden, so its windows are off screen.
    public var isHidden: Bool

    public init(isTerminated: Bool, isHidden: Bool) {
        self.isTerminated = isTerminated
        self.isHidden = isHidden
    }
}

/// What bringing the target app forward actually did, so a run can report it.
public struct ActivationResult: Sendable, Hashable {
    /// Whether a running process was found for the pid.
    public var appFound: Bool
    /// Whether the app was hidden and an unhide was issued.
    public var wasHidden: Bool

    public init(appFound: Bool, wasHidden: Bool) {
        self.appFound = appFound
        self.wasHidden = wasHidden
    }
}

/// The live macOS facts the `MacComputer` driver depends on.
///
/// Bundling them behind injectable closures lets the driver's readiness logic
/// be unit-tested without a real running app or TCC permission grants. The
/// production driver uses ``live``.
public struct MacComputerEnvironment: Sendable {
    /// Running-process facts for a pid, or `nil` when nothing runs under it.
    public var targetProcess: @Sendable (pid_t) -> TargetProcessState?
    /// Whether this process holds the Accessibility permission.
    public var isAccessibilityTrusted: @Sendable () -> Bool
    /// Whether this process holds the Screen Recording permission.
    public var isScreenRecordingTrusted: @Sendable () -> Bool
    /// Bring the target app to the front, unhiding it first when needed.
    public var activateTarget: @Sendable (pid_t) async -> ActivationResult

    public init(
        targetProcess: @escaping @Sendable (pid_t) -> TargetProcessState?,
        isAccessibilityTrusted: @escaping @Sendable () -> Bool,
        isScreenRecordingTrusted: @escaping @Sendable () -> Bool,
        activateTarget: @escaping @Sendable (pid_t) async -> ActivationResult = { _ in
            ActivationResult(appFound: false, wasHidden: false)
        }
    ) {
        self.targetProcess = targetProcess
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.isScreenRecordingTrusted = isScreenRecordingTrusted
        self.activateTarget = activateTarget
    }

    /// The production environment, backed by AppKit and the TCC preflight APIs.
    public static let live = MacComputerEnvironment(
        targetProcess: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                return nil
            }
            return TargetProcessState(isTerminated: app.isTerminated, isHidden: app.isHidden)
        },
        isAccessibilityTrusted: { AccessibilityPermission.isTrusted },
        isScreenRecordingTrusted: { CGPreflightScreenCaptureAccess() },
        activateTarget: { pid in
            await MainActor.run {
                guard let app = NSRunningApplication(processIdentifier: pid) else {
                    return ActivationResult(appFound: false, wasHidden: false)
                }
                let wasHidden = app.isHidden
                if wasHidden { _ = app.unhide() }
                _ = app.activate()
                return ActivationResult(appFound: true, wasHidden: wasHidden)
            }
        }
    )
}
