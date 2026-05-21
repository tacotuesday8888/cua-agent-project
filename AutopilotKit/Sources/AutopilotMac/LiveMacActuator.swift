import ApplicationServices
import AutopilotAction
import AutopilotAgent
import AutopilotCore
import CoreGraphics
import Foundation

/// The production `MacActuating`: resolves element ids from the latest capture
/// to live `AXUIElement`s and drives them through `AccessibilityActuator`.
///
/// This is the only type that handles `AXUIElement`, so `MacComputer`'s
/// orchestration (the fallbacks and turn bookkeeping) stays unit-testable.
/// Element resolution (`element(for:)` / `validateLiveElement`) is moved here
/// verbatim from `MacComputer`, so the recovery errors it raises are unchanged.
///
/// `@unchecked Sendable`: its mutable element map is only ever read or written
/// from inside the `MacComputer` actor's isolation domain (via `captureTree`,
/// `loadForTesting`, and the actor's action methods), so access is serialized.
final class LiveMacActuator: MacActuating, @unchecked Sendable {
    private let actuator: AccessibilityActuator
    private let pid: pid_t
    private let appName: String
    /// Live AX elements from the most recent capture, keyed by element id.
    private var elements: [String: AXUIElement] = [:]
    /// Turn id of the most recent capture, for stale-context error messages.
    private var turnIdentifier: Int?

    init(actuator: AccessibilityActuator, pid: pid_t, appName: String) {
        self.actuator = actuator
        self.pid = pid
        self.appName = appName
    }

    func updateElements(_ elements: [String: AXUIElement], turnIdentifier: Int?) {
        self.elements = elements
        self.turnIdentifier = turnIdentifier
    }

    func press(elementID: String) throws {
        try actuator.press(element(for: elementID))
    }

    func focus(elementID: String) throws {
        try actuator.focus(element(for: elementID))
    }

    func setValue(elementID: String, to value: String) throws {
        try actuator.setValue(element(for: elementID), to: value)
    }

    func value(elementID: String) throws -> String? {
        let element = try element(for: elementID)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &raw
        )
        guard status == .success else { return nil }
        return raw as? String
    }

    func perform(action: String, elementID: String) throws {
        try actuator.perform(action: action, on: element(for: elementID))
    }

    func click(at point: CGPoint) throws {
        try actuator.click(at: point, pid: pid)
    }

    func typeText(_ text: String) throws {
        try actuator.typeText(text, pid: pid)
    }

    func pressKey(_ key: KeyPress) throws {
        try actuator.pressKey(key, pid: pid)
    }

    func scroll(direction: ScrollDirection, amount: Int, at point: CGPoint?) throws {
        try actuator.scroll(direction: direction, amount: amount, at: point, pid: pid)
    }

    func drag(from start: CGPoint, to end: CGPoint) throws {
        try actuator.drag(from: start, to: end, pid: pid)
    }

    // MARK: - Element resolution (moved verbatim from MacComputer)

    /// Resolve an element id from the most recent capture to a live AX element.
    private func element(for id: String) throws -> AXUIElement {
        guard !elements.isEmpty else {
            throw ComputerControlError.noCachedState(appName: appName)
        }
        guard let element = elements[id] else {
            throw ComputerControlError.invalidElement(
                elementID: id,
                appName: appName,
                turnIdentifier: turnIdentifier
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
                turnIdentifier: turnIdentifier
            )
        }
    }
}
