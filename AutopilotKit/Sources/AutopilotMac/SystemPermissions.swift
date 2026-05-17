import AppKit
import AutopilotPerception
import CoreGraphics

/// The TCC permissions Mac Autopilot needs, and the calls to check, request,
/// and surface them.
///
/// Accessibility lets the agent read and control other apps' UI; Screen
/// Recording backs the screenshot fallback. Both are runtime permissions the
/// user grants in System Settings — there is no entitlement that confers them,
/// so the app must guide the user through granting them.
public enum SystemPermissions {
    /// Whether this process can read and control other apps via Accessibility.
    public static var accessibilityTrusted: Bool {
        AccessibilityPermission.isTrusted
    }

    /// Whether this process can capture the screen for screenshot fallback.
    public static var screenRecordingTrusted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompt for Accessibility access, registering the app in the System
    /// Settings list. Returns the trust state at call time; because granting
    /// is asynchronous, this is usually `false` on first run.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        AccessibilityPermission.request()
    }

    /// Prompt for Screen Recording access. Returns whether it is now granted.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Open the Accessibility pane of System Settings.
    @MainActor
    public static func openAccessibilitySettings() {
        open("com.apple.preference.security?Privacy_Accessibility")
    }

    /// Open the Screen Recording pane of System Settings.
    @MainActor
    public static func openScreenRecordingSettings() {
        open("com.apple.preference.security?Privacy_ScreenCapture")
    }

    @MainActor
    private static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
