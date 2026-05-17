import AppKit
import ApplicationServices
import AutopilotAction
import AutopilotAgent
import AutopilotCore
import AutopilotPerception
import Foundation
import ScreenCaptureKit

/// Errors specific to driving a real macOS app.
public enum MacComputerError: Error, Sendable {
    /// A screenshot could not be produced.
    case screenshotUnavailable
}

/// The production `ComputerControl`: drives a real macOS app by reading its
/// accessibility tree (`AutopilotPerception`) and acting on it
/// (`AutopilotAction`).
///
/// Each `captureTree` refreshes a private index of live `AXUIElement`s keyed by
/// the snapshot's element ids; subsequent actions resolve ids through it, so
/// the agent only ever deals with stable string ids.
public actor MacComputer: ComputerControl {
    public nonisolated let appName: String

    private let pid: pid_t
    private let bundleIdentifier: String?
    private let reader: AccessibilityTreeReader
    private let actuator: AccessibilityActuator

    /// Live AX elements from the most recent `captureTree`, keyed by element id.
    private var latestElements: [String: AXUIElement] = [:]
    /// Sendable metadata from the most recent capture.
    private var latestSnapshot: UITreeSnapshot?
    /// Monotonic snapshot counter used to detect stale model context.
    private var nextTurnIdentifier = 1

    public init(
        pid: pid_t,
        appName: String,
        bundleIdentifier: String? = nil,
        reader: AccessibilityTreeReader = AccessibilityTreeReader(),
        actuator: AccessibilityActuator = AccessibilityActuator()
    ) {
        self.pid = pid
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.reader = reader
        self.actuator = actuator
    }

    public func captureTree() async throws -> UITreeSnapshot {
        let turnIdentifier = nextTurnIdentifier
        nextTurnIdentifier += 1
        let scan = try reader.readWindow(
            pid: pid,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            turnIdentifier: turnIdentifier
        )
        latestElements = scan.elements
        latestSnapshot = scan.snapshot
        return scan.snapshot
    }

    public func listApps() async throws -> [ComputerAppInfo] {
        [
            ComputerAppInfo(
                name: appName,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: pid,
                isTarget: true
            )
        ]
    }

    public func diagnose() async -> ComputerDiagnostics {
        var checks: [ComputerDiagnosticCheck] = []

        let runningApp = NSRunningApplication(processIdentifier: pid)
        checks.append(ComputerDiagnosticCheck(
            id: "target-app",
            status: runningApp == nil || runningApp?.isTerminated == true ? .failed : .passed,
            title: "Target app",
            detail: runningApp == nil || runningApp?.isTerminated == true
                ? "\(appName) is not running."
                : "\(appName) is running with pid \(pid).",
            recovery: runningApp == nil || runningApp?.isTerminated == true
                ? "Open the app, select it again, then start the task."
                : nil
        ))

        let accessibilityTrusted = AccessibilityPermission.isTrusted
        checks.append(ComputerDiagnosticCheck(
            id: "accessibility",
            status: accessibilityTrusted ? .passed : .failed,
            title: "Accessibility permission",
            detail: accessibilityTrusted
                ? "Mac Autopilot can read and control other app UIs."
                : "Mac Autopilot does not have Accessibility permission.",
            recovery: accessibilityTrusted
                ? nil
                : "Grant Accessibility in System Settings > Privacy & Security > Accessibility."
        ))

        let screenRecordingTrusted = CGPreflightScreenCaptureAccess()
        checks.append(ComputerDiagnosticCheck(
            id: "screen-recording",
            status: screenRecordingTrusted ? .passed : .warning,
            title: "Screen Recording permission",
            detail: screenRecordingTrusted
                ? "Target-window screenshots are available."
                : "Screen Recording is not granted, so screenshot fallback may fail.",
            recovery: screenRecordingTrusted
                ? nil
                : "Grant Screen Recording in System Settings > Privacy & Security > Screen Recording."
        ))

        if accessibilityTrusted, runningApp != nil, runningApp?.isTerminated == false {
            checks.append(contentsOf: windowDiagnostics())
        }

        return ComputerDiagnostics(appName: appName, checks: checks)
    }

    public func click(elementID: String) async throws {
        try actuator.press(element(for: elementID))
    }

    public func setValue(elementID: String, value: String) async throws {
        try actuator.setValue(element(for: elementID), to: value)
    }

    public func typeText(_ text: String) async throws {
        try actuator.typeText(text, pid: pid)
    }

    public func scroll(
        elementID: String?,
        direction: ScrollDirection,
        amount: Int
    ) async throws {
        let point = try elementID.map { try center(of: $0) }
        try actuator.scroll(direction: direction, amount: amount, at: point, pid: pid)
    }

    public func pressKey(_ key: KeyPress) async throws {
        try actuator.pressKey(key, pid: pid)
    }

    public func drag(fromElementID: String, toElementID: String) async throws {
        let start = try center(of: fromElementID)
        let end = try center(of: toElementID)
        try actuator.drag(from: start, to: end, pid: pid)
    }

    public func performSecondaryAction(elementID: String, action: String) async throws {
        try actuator.perform(action: action, on: element(for: elementID))
    }

    public func captureScreenshot() async throws -> Data {
        try await Self.captureScreenshot(windowIdentifier: latestSnapshot?.windowIdentifier)
    }

    private static func captureScreenshot(windowIdentifier: UInt32?) async throws -> Data {
        let content = try await SCShareableContent.current
        if
            let windowIdentifier,
            let window = content.windows.first(where: { $0.windowID == windowIdentifier })
        {
            return try await capture(window: window)
        }

        guard let display = content.displays.first else {
            throw MacComputerError.screenshotUnavailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard let png = NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:]) else {
            throw MacComputerError.screenshotUnavailable
        }
        return png
    }

    /// Resolve an element id from the most recent capture to a live AX element.
    private func element(for id: String) throws -> AXUIElement {
        guard !latestElements.isEmpty else {
            throw ComputerControlError.noCachedState(appName: appName)
        }
        guard let element = latestElements[id] else {
            throw ComputerControlError.invalidElement(
                elementID: id,
                appName: appName,
                turnIdentifier: latestSnapshot?.turnIdentifier
            )
        }
        return element
    }

    private func center(of id: String) throws -> CGPoint {
        guard latestSnapshot != nil else {
            throw ComputerControlError.noCachedState(appName: appName)
        }
        guard let element = latestSnapshot?.element(id: id) else {
            throw ComputerControlError.invalidElement(
                elementID: id,
                appName: appName,
                turnIdentifier: latestSnapshot?.turnIdentifier
            )
        }
        return element.frame.center
    }

    private static func capture(window: SCWindow) async throws -> Data {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width))
        configuration.height = max(1, Int(window.frame.height))
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard let png = NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:]) else {
            throw MacComputerError.screenshotUnavailable
        }
        return png
    }

    private func windowDiagnostics() -> [ComputerDiagnosticCheck] {
        do {
            let scan = try reader.readWindow(
                pid: pid,
                appName: appName,
                bundleIdentifier: bundleIdentifier
            )
            let count = scan.snapshot.root.flattened.count
            var checks = [
                ComputerDiagnosticCheck(
                    id: "accessibility-tree",
                    status: .passed,
                    title: "Accessibility tree",
                    detail: "Read \(count) accessibility element(s) from the target window."
                )
            ]
            checks.append(ComputerDiagnosticCheck(
                id: "window-match",
                status: scan.snapshot.windowIdentifier == nil ? .warning : .passed,
                title: "Target window match",
                detail: scan.snapshot.windowIdentifier == nil
                    ? "Could not match the AX window to a CoreGraphics window id."
                    : "Matched target window id \(scan.snapshot.windowIdentifier ?? 0).",
                recovery: scan.snapshot.windowIdentifier == nil
                    ? "The driver can still use AX, but screenshot fallback may capture the display instead of the window."
                    : nil
            ))
            return checks
        } catch AccessibilityTreeReader.ReadError.noWindow {
            return [
                ComputerDiagnosticCheck(
                    id: "accessibility-tree",
                    status: .failed,
                    title: "Accessibility tree",
                    detail: "\(appName) exposes no readable window.",
                    recovery: "Make sure the target app has a visible, unminimized window."
                )
            ]
        } catch {
            return [
                ComputerDiagnosticCheck(
                    id: "accessibility-tree",
                    status: .failed,
                    title: "Accessibility tree",
                    detail: "Could not read \(appName)'s accessibility tree: \(error).",
                    recovery: "Call get_app_state after confirming the app is visible and permissions are granted."
                )
            ]
        }
    }
}

private extension ElementFrame {
    var center: CGPoint {
        CGPoint(x: x + width / 2, y: y + height / 2)
    }
}
