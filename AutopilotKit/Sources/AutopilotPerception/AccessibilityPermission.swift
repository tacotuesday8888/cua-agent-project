import ApplicationServices

/// Checks and requests the macOS Accessibility permission the agent needs to
/// read other apps' UI trees and control them.
///
/// Accessibility is a runtime TCC permission — there is no entitlement or
/// Info.plist key for it; the user must grant it in System Settings.
public enum AccessibilityPermission {
    /// Whether this process is currently trusted for Accessibility.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility access, surfacing the System
    /// Settings pane if needed. Returns the trust state at the time of the call
    /// (granting is asynchronous, so this is usually `false` on first run).
    @discardableResult
    public static func request() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a C global that Swift 6 flags as
        // non-concurrency-safe; its value is this stable string constant.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
