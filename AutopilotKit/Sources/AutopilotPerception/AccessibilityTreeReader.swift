import ApplicationServices
import AutopilotCore
import Foundation

/// The result of reading a window: the Sendable snapshot the agent reasons
/// over, plus the live AX element references needed to act on it.
///
/// `WindowScan` is intentionally **not** `Sendable` — `elements` holds live
/// `AXUIElement` references that must stay in the isolation domain that read
/// them. Hand `snapshot` to the agent; keep `elements` for actuation.
public struct WindowScan {
    /// The structured snapshot, safe to pass to the agent.
    public let snapshot: UITreeSnapshot
    /// Live AX element references, keyed by the snapshot's element ids.
    public let elements: [String: AXUIElement]
}

/// Reads a macOS app's accessibility tree into a `UITreeSnapshot` — the
/// structured perception the agent reasons over.
public struct AccessibilityTreeReader: Sendable {
    /// Bounds on how much of a (potentially huge) AX tree to serialize.
    public struct Limits: Sendable {
        public var maxDepth: Int
        public var maxElements: Int

        public init(maxDepth: Int = 40, maxElements: Int = 1500) {
            self.maxDepth = maxDepth
            self.maxElements = maxElements
        }
    }

    /// Why reading an app's tree failed.
    public enum ReadError: Error, Sendable {
        /// The process lacks Accessibility permission.
        case notTrusted
        /// The app exposes no readable window.
        case noWindow
    }

    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Read the focused (or main) window of the app with the given pid.
    public func readWindow(
        pid: pid_t,
        appName: String,
        bundleIdentifier: String? = nil
    ) throws -> WindowScan {
        guard AXIsProcessTrusted() else { throw ReadError.notTrusted }

        let app = AXUIElementCreateApplication(pid)
        guard let window = focusedWindow(of: app) else { throw ReadError.noWindow }

        var counter = 0
        var elements: [String: AXUIElement] = [:]
        let root = serialize(window, depth: 0, counter: &counter, elements: &elements)
        let snapshot = UITreeSnapshot(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: window.stringAttribute(kAXTitleAttribute),
            root: root
        )
        return WindowScan(snapshot: snapshot, elements: elements)
    }

    /// Pick the window the user is most likely working in.
    private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        if let focused: AXUIElement = app.attributeValue(kAXFocusedWindowAttribute) {
            return focused
        }
        if let main: AXUIElement = app.attributeValue(kAXMainWindowAttribute) {
            return main
        }
        return app.attributeValue(kAXWindowsAttribute, as: [AXUIElement].self)?.first
    }

    /// Depth-first serialize an element and its subtree, assigning stable ids
    /// and recording each element in the index.
    private func serialize(
        _ element: AXUIElement,
        depth: Int,
        counter: inout Int,
        elements: inout [String: AXUIElement]
    ) -> UIElement {
        let id = "e\(counter)"
        counter += 1
        elements[id] = element

        let role = element.stringAttribute(kAXRoleAttribute) ?? "AXUnknown"
        let label = element.stringAttribute(kAXTitleAttribute)
            ?? element.stringAttribute(kAXDescriptionAttribute)
        let value = element.stringAttribute(kAXValueAttribute)
        let isEnabled = element.attributeValue(kAXEnabledAttribute, as: Bool.self) ?? true
        let isFocused = element.boolAttribute(kAXFocusedAttribute)

        let position = element.pointAttribute(kAXPositionAttribute) ?? .zero
        let size = element.sizeAttribute(kAXSizeAttribute) ?? .zero
        let frame = ElementFrame(
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height
        )

        var children: [UIElement] = []
        if depth < limits.maxDepth {
            for child in element.childElements() {
                guard counter < limits.maxElements else { break }
                children.append(serialize(child, depth: depth + 1,
                                           counter: &counter, elements: &elements))
            }
        }

        return UIElement(
            id: id,
            role: role,
            label: label,
            value: value,
            isEnabled: isEnabled,
            isFocused: isFocused,
            frame: frame,
            children: children
        )
    }
}
