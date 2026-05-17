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
    /// An element id was not found in the most recent capture.
    case unknownElement(String)
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
        let scan = try reader.readWindow(
            pid: pid,
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
        latestElements = scan.elements
        return scan.snapshot
    }

    public func click(elementID: String) async throws {
        try actuator.press(element(for: elementID))
    }

    public func setValue(elementID: String, value: String) async throws {
        try actuator.setValue(element(for: elementID), to: value)
    }

    public func scroll(
        elementID: String?,
        direction: ScrollDirection,
        amount: Int
    ) async throws {
        // v1 scrolls the frontmost scrollable area; element-targeted scrolling
        // is a later refinement.
        try actuator.scroll(direction: direction, amount: amount)
    }

    public func pressKey(_ key: KeyPress) async throws {
        try actuator.pressKey(key)
    }

    public nonisolated func captureScreenshot() async throws -> Data {
        let content = try await SCShareableContent.current
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
        guard let element = latestElements[id] else {
            throw MacComputerError.unknownElement(id)
        }
        return element
    }
}
