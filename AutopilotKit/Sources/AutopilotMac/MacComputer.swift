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
    /// The AX window could not be matched to a CoreGraphics window. Falling
    /// back to the full display would expose unrelated screen content.
    case targetWindowNotMatched
    /// A screenshot could not be produced.
    case screenshotUnavailable
}

extension MacComputerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .targetWindowNotMatched:
            return """
            The target app window could not be matched for a private \
            target-window screenshot.
            """
        case .screenshotUnavailable:
            return "The target-window screenshot could not be produced."
        }
    }
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
    private let environment: MacComputerEnvironment

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
        actuator: AccessibilityActuator = AccessibilityActuator(),
        environment: MacComputerEnvironment = .live
    ) {
        self.pid = pid
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.reader = reader
        self.actuator = actuator
        self.environment = environment
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

    /// Bring the target app forward so input and window reads land on a
    /// frontmost window, and report what was done.
    public func prepare() async -> String {
        let result = await environment.activateTarget(pid)
        guard result.appFound else {
            return "\(appName) is not running, so it could not be brought forward."
        }
        return result.wasHidden
            ? "Unhid and activated \(appName)."
            : "Activated \(appName)."
    }

    public func diagnose() async -> ComputerDiagnostics {
        let process = environment.targetProcess(pid)
        let accessibilityTrusted = environment.isAccessibilityTrusted()
        let screenRecordingTrusted = environment.isScreenRecordingTrusted()

        var inputs = MacDriverDiagnostics.Inputs(
            appName: appName,
            process: process,
            accessibilityTrusted: accessibilityTrusted,
            screenRecordingTrusted: screenRecordingTrusted,
            window: nil
        )
        if MacDriverDiagnostics.shouldProbeWindows(
            process: process,
            accessibilityTrusted: accessibilityTrusted
        ) {
            inputs.window = probeWindow()
        }
        return ComputerDiagnostics(
            appName: appName,
            checks: MacDriverDiagnostics.checks(for: inputs)
        )
    }

    /// Read the target window once to classify its availability for the
    /// readiness checks.
    private func probeWindow() -> MacDriverDiagnostics.WindowProbe {
        do {
            let scan = try reader.readWindow(
                pid: pid,
                appName: appName,
                bundleIdentifier: bundleIdentifier
            )
            if scan.isWindowMinimized {
                return .minimized
            }
            return .readable(
                elementCount: scan.snapshot.root.flattened.count,
                windowMatched: scan.snapshot.windowIdentifier != nil
            )
        } catch AccessibilityTreeReader.ReadError.noWindow {
            return .noWindow
        } catch {
            return .failed(String(describing: error))
        }
    }

    public func click(elementID: String) async throws {
        let element = try element(for: elementID)
        do {
            try actuator.press(element)
        } catch let pressError {
            // Many real controls — icon-only buttons, Electron, and web views —
            // advertise no working AX press action, so press throws. Fall back
            // to a synthesized click at the element's center (the same target
            // that already passed the risk gate), mirroring the focus → click
            // fallback used for typing. If the fallback also fails, surface the
            // original press error, which names the underlying AX failure.
            guard let point = try? center(of: elementID) else { throw pressError }
            do {
                try actuator.click(at: point, pid: pid)
            } catch {
                throw pressError
            }
        }
    }

    public func setValue(elementID: String, value: String) async throws {
        try actuator.setValue(element(for: elementID), to: value)
    }

    public func typeText(_ text: String) async throws {
        try actuator.typeText(text, pid: pid)
    }

    public func typeText(_ text: String, into elementID: String?) async throws {
        if let elementID {
            let element = try element(for: elementID)
            do {
                try actuator.focus(element)
            } catch {
                try actuator.click(at: center(of: elementID), pid: pid)
            }
        }
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
        guard let windowIdentifier else {
            throw MacComputerError.targetWindowNotMatched
        }

        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { $0.windowID == windowIdentifier }) else {
            throw MacComputerError.targetWindowNotMatched
        }

        return try await capture(window: window)
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
        try validateLiveElement(element, id: id)
        return element
    }

    private func validateLiveElement(_ element: AXUIElement, id: String) throws {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &raw
        )
        guard status == .success else {
            throw ComputerControlError.invalidElement(
                elementID: id,
                appName: appName,
                turnIdentifier: latestSnapshot?.turnIdentifier
            )
        }
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

}

private extension ElementFrame {
    var center: CGPoint {
        CGPoint(x: x + width / 2, y: y + height / 2)
    }
}
