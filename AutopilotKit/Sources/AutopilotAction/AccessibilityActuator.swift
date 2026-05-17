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
        case attributeNotSettable(String)
        case unknownKey(String)
    }

    public init() {}

    /// Press / activate an element (button, link, menu item, checkbox, …).
    public func press(_ element: AXUIElement) throws {
        let advertisedActions = actionNames(of: element)
        let preferredActions = ["AXPress", "AXConfirm", "AXOpen"]
        let candidates = preferredActions.filter { advertisedActions.contains($0) }
            + preferredActions.filter { !advertisedActions.contains($0) }

        var failures: [String] = []
        for action in candidates {
            let status = AXUIElementPerformAction(element, action as CFString)
            if status == .success { return }
            failures.append("\(action): AXError \(status.rawValue)")
        }
        throw ActuationError.actionFailed("press failed (\(failures.joined(separator: ", ")))")
    }

    /// Perform a specific advertised accessibility action.
    public func perform(action: String, on element: AXUIElement) throws {
        let advertisedActions = actionNames(of: element)
        guard advertisedActions.contains(action) else {
            throw ActuationError.actionFailed("\(action) is not available on this element")
        }
        let status = AXUIElementPerformAction(element, action as CFString)
        guard status == .success else {
            throw ActuationError.actionFailed("\(action) failed (AXError \(status.rawValue))")
        }
    }

    /// Replace the text value of an element (text field / text area).
    public func setValue(_ element: AXUIElement, to value: String) throws {
        guard isAttributeSettable(kAXValueAttribute, on: element) else {
            throw ActuationError.attributeNotSettable(kAXValueAttribute)
        }
        let status = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        )
        guard status == .success else {
            throw ActuationError.actionFailed("set value failed (AXError \(status.rawValue))")
        }
    }

    /// Move keyboard focus to a focusable element before synthesized typing.
    public func focus(_ element: AXUIElement) throws {
        if isAttributeSettable(kAXFocusedAttribute, on: element) {
            let status = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            if status == .success { return }
        }

        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard status == .success else {
            throw ActuationError.actionFailed("focus failed (AXError \(status.rawValue))")
        }
    }

    /// Send a key press (with optional modifiers) as a synthesized event.
    public func pressKey(_ key: KeyPress, pid: pid_t? = nil) throws {
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
        post(keyDown, pid: pid)
        post(keyUp, pid: pid)
    }

    /// Type Unicode text into the target process.
    public func typeText(_ text: String, pid: pid_t? = nil) throws {
        for character in text {
            let scalars = Array(String(character).utf16)
            guard
                let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                throw ActuationError.actionFailed("could not create text event")
            }

            scalars.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                keyUp.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.flags = []
            keyUp.flags = []
            post(keyDown, pid: pid)
            post(keyUp, pid: pid)
        }
    }

    /// Scroll a number of line-steps in a direction.
    public func scroll(
        direction: ScrollDirection,
        amount: Int,
        at point: CGPoint? = nil,
        pid: pid_t? = nil
    ) throws {
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
        if let point {
            event.location = point
        }
        post(event, pid: pid)
    }

    /// Drag between two screen-space points.
    public func drag(from start: CGPoint, to end: CGPoint, pid: pid_t? = nil) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: start,
                mouseButton: .left
            ),
            let mouseDragged = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: end,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: end,
                mouseButton: .left
            )
        else {
            throw ActuationError.actionFailed("could not create drag event")
        }

        post(mouseDown, pid: pid)
        post(mouseDragged, pid: pid)
        post(mouseUp, pid: pid)
    }

    /// Click a screen-space point. Used as a fallback for focus-only elements
    /// that do not expose a reliable AX focus action.
    public func click(at point: CGPoint, pid: pid_t? = nil) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else {
            throw ActuationError.actionFailed("could not create click event")
        }

        post(mouseDown, pid: pid)
        post(mouseUp, pid: pid)
    }

    private func post(_ event: CGEvent, pid: pid_t?) {
        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var raw: CFArray?
        let status = AXUIElementCopyActionNames(element, &raw)
        guard status == .success, let raw else { return [] }
        return (raw as? [String]) ?? []
    }

    private func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return status == .success && settable.boolValue
    }
}

extension AccessibilityActuator.ActuationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .actionFailed(let detail):
            return detail
        case .attributeNotSettable(let attribute):
            return """
            \(attribute) is not settable on this element. Call get_app_state and \
            choose an editable element marked settable.
            """
        case .unknownKey(let key):
            return """
            Unknown key '\(key)'. Supported names: a letter or digit; return, \
            enter, tab, space, escape, delete, forwarddelete; the arrow keys \
            up, down, left, and right; home, end, pageup, pagedown; and f1-f12.
            """
        }
    }
}
