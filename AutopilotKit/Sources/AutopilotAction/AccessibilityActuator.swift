import ApplicationServices
import AutopilotCore
import CoreGraphics

/// Performs actions on macOS UI: Accessibility actions on elements, plus
/// synthesized keyboard and scroll events.
///
/// Acting via Accessibility actions (rather than synthetic clicks at
/// coordinates) is more reliable and does not move the user's cursor.
public struct AccessibilityActuator: Sendable {
    /// Why an actuation failed.
    public enum ActuationError: Error, Sendable {
        case actionFailed(String)
        case unknownKey(String)
    }

    public init() {}

    /// Press / activate an element (button, link, menu item, checkbox, …).
    public func press(_ element: AXUIElement) throws {
        // `kAXPressAction` is a C global; its stable value is "AXPress".
        let status = AXUIElementPerformAction(element, "AXPress" as CFString)
        guard status == .success else {
            throw ActuationError.actionFailed("press failed (AXError \(status.rawValue))")
        }
    }

    /// Replace the text value of an element (text field / text area).
    public func setValue(_ element: AXUIElement, to value: String) throws {
        let status = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        )
        guard status == .success else {
            throw ActuationError.actionFailed("set value failed (AXError \(status.rawValue))")
        }
    }

    /// Send a key press (with optional modifiers) as a synthesized event.
    public func pressKey(_ key: KeyPress) throws {
        guard let keyCode = KeyCodes.code(for: key.key) else {
            throw ActuationError.unknownKey(key.key)
        }
        let flags = CGEventFlags(modifiers: key.modifiers)
        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            throw ActuationError.actionFailed("could not create key event")
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Scroll a number of line-steps in a direction.
    public func scroll(direction: ScrollDirection, amount: Int) throws {
        let steps = Int32(max(1, amount))
        let vertical: Int32
        let horizontal: Int32
        switch direction {
        case .up: (vertical, horizontal) = (steps, 0)
        case .down: (vertical, horizontal) = (-steps, 0)
        case .left: (vertical, horizontal) = (0, steps)
        case .right: (vertical, horizontal) = (0, -steps)
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else {
            throw ActuationError.actionFailed("could not create scroll event")
        }
        event.post(tap: .cghidEventTap)
    }
}
