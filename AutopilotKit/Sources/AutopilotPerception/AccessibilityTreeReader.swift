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
    /// Whether the captured window is currently minimized to the Dock.
    public let isWindowMinimized: Bool
}

/// Reads a macOS app's accessibility tree into a `UITreeSnapshot` — the
/// structured perception the agent reasons over.
public struct AccessibilityTreeReader: Sendable {
    /// Bounds on how much of a (potentially huge) AX tree to serialize.
    public struct Limits: Sendable {
        public var maxDepth: Int
        public var maxElements: Int
        /// Per-message accessibility timeout, in seconds, applied to the target
        /// app. Reading a window makes thousands of synchronous cross-process
        /// AX calls; without a bound, one unresponsive call hangs the whole run.
        /// This caps each call so a stuck app fails fast with a clear error
        /// instead of freezing. `0` keeps the system default.
        public var messagingTimeout: Double

        public init(maxDepth: Int = 40, maxElements: Int = 1500, messagingTimeout: Double = 5) {
            self.maxDepth = maxDepth
            self.maxElements = maxElements
            self.messagingTimeout = messagingTimeout
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
        bundleIdentifier: String? = nil,
        turnIdentifier: Int? = nil
    ) throws -> WindowScan {
        guard AXIsProcessTrusted() else { throw ReadError.notTrusted }

        let app = AXUIElementCreateApplication(pid)
        // Bound every AX message to this app so an unresponsive target cannot
        // hang the read (and the run). Set on the app element, it applies to all
        // messages to that application, including the elements captured below.
        if limits.messagingTimeout > 0 {
            _ = AXUIElementSetMessagingTimeout(app, Float(limits.messagingTimeout))
        }
        guard let window = focusedWindow(of: app) else { throw ReadError.noWindow }
        let windowTitle = window.stringAttribute(kAXTitleAttribute)
        let windowIdentifier = Self.windowIdentifier(pid: pid, title: windowTitle)
        let isWindowMinimized = window.boolAttribute(kAXMinimizedAttribute)

        var counter = 0
        var elements: [String: AXUIElement] = [:]
        let root = serialize(window, depth: 0, counter: &counter, elements: &elements)
        let snapshot = UITreeSnapshot(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: pid,
            windowTitle: windowTitle,
            windowIdentifier: windowIdentifier,
            turnIdentifier: turnIdentifier,
            root: root,
            isTruncated: counter >= limits.maxElements
        )
        return WindowScan(
            snapshot: snapshot,
            elements: elements,
            isWindowMinimized: isWindowMinimized
        )
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
        let subrole = element.stringAttribute(kAXSubroleAttribute)
        let identifier = element.stringAttribute(kAXIdentifierAttribute)
        let label = element.stringAttribute(kAXTitleAttribute)
            ?? element.stringAttribute(kAXDescriptionAttribute)
        let value = element.valueString(kAXValueAttribute)
        let isEnabled = element.attributeValue(kAXEnabledAttribute, as: Bool.self) ?? true
        let isFocused = element.boolAttribute(kAXFocusedAttribute)
        let isValueSettable = element.isAttributeSettable(kAXValueAttribute)
        let actions = element.actionNames().sorted()

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
            subrole: subrole,
            identifier: identifier,
            label: label,
            value: value,
            isEnabled: isEnabled,
            isFocused: isFocused,
            isValueSettable: isValueSettable,
            actions: actions,
            frame: frame,
            children: children
        )
    }

    /// Best-effort public-API lookup of the matching CoreGraphics window id.
    ///
    /// The Accessibility APIs do not expose CGWindowID directly. Reference
    /// projects use private SPI for an exact mapping; this heuristic keeps the
    /// production path on public APIs while still enabling targeted screenshots
    /// for the common single-window case.
    private static func windowIdentifier(pid: pid_t, title: String?) -> UInt32? {
        for attempt in 0..<3 {
            if let identifier = windowIdentifierOnce(pid: pid, title: title) {
                return identifier
            }
            // Newly-launched windows can be visible to AX just before they show
            // up in the CoreGraphics window list.
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return nil
    }

    private static func windowIdentifierOnce(pid: pid_t, title: String?) -> UInt32? {
        guard
            let rawWindows = CGWindowListCopyWindowInfo(
                [.excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return nil
        }

        let candidates = rawWindows.filter { info in
            guard let ownerPID = int32Value(info[kCGWindowOwnerPID as String]) else {
                return false
            }
            let layer = int32Value(info[kCGWindowLayer as String]) ?? 0
            return ownerPID == pid && layer == 0
        }

        if
            let title,
            !title.isEmpty,
            let exact = candidates.first(where: {
                ($0[kCGWindowName as String] as? String) == title
            }),
            let number = uint32Value(exact[kCGWindowNumber as String])
        {
            return number
        }

        if
            let named = candidates.first(where: {
                !(($0[kCGWindowName as String] as? String) ?? "").isEmpty
            }),
            let number = uint32Value(named[kCGWindowNumber as String])
        {
            return number
        }

        return candidates.compactMap { uint32Value($0[kCGWindowNumber as String]) }.first
    }

    private static func int32Value(_ value: Any?) -> Int32? {
        switch value {
        case let value as Int32:
            return value
        case let value as Int:
            return Int32(value)
        case let value as NSNumber:
            return value.int32Value
        default:
            return nil
        }
    }

    private static func uint32Value(_ value: Any?) -> UInt32? {
        switch value {
        case let value as UInt32:
            return value
        case let value as UInt:
            return UInt32(value)
        case let value as Int where value >= 0:
            return UInt32(value)
        case let value as NSNumber:
            return value.uint32Value
        default:
            return nil
        }
    }
}
