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
        let windowFrame = window.frame()
        let windowIdentifier = Self.windowIdentifier(
            pid: pid,
            title: windowTitle,
            frame: windowFrame
        )
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
        let label = AXUIElement.firstNonEmpty(
            element.stringAttribute(kAXTitleAttribute),
            element.stringAttribute(kAXDescriptionAttribute)
        )
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
    /// production path on public APIs, matching the AX window's frame against the
    /// CoreGraphics window list so even same-title windows resolve correctly.
    private static func windowIdentifier(pid: pid_t, title: String?, frame: CGRect?) -> UInt32? {
        for attempt in 0..<3 {
            if let identifier = windowIdentifierOnce(pid: pid, title: title, frame: frame) {
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

    private static func windowIdentifierOnce(pid: pid_t, title: String?, frame: CGRect?) -> UInt32? {
        guard
            let rawWindows = CGWindowListCopyWindowInfo(
                [.excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return nil
        }
        return selectWindowNumber(
            from: parseWindowList(rawWindows),
            pid: pid,
            title: title,
            frame: frame
        )
    }

    /// A value-typed view of one CoreGraphics window-list entry, holding just
    /// what window selection needs. Kept free of live state so selection can be
    /// unit-tested without the real window server.
    struct CGWindowDescriptor: Equatable, Sendable {
        var windowNumber: UInt32
        var ownerPID: pid_t
        var layer: Int32
        var title: String?
        var bounds: CGRect?
    }

    /// Parse the raw CoreGraphics window list into descriptors, dropping any
    /// entry without a usable window number (one we could never return anyway).
    static func parseWindowList(_ rawWindows: [[String: Any]]) -> [CGWindowDescriptor] {
        rawWindows.compactMap { info in
            guard
                let windowNumber = uint32Value(info[kCGWindowNumber as String]),
                let ownerPID = int32Value(info[kCGWindowOwnerPID as String])
            else {
                return nil
            }
            return CGWindowDescriptor(
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                layer: int32Value(info[kCGWindowLayer as String]) ?? 0,
                title: info[kCGWindowName as String] as? String,
                bounds: parseBounds(info[kCGWindowBounds as String])
            )
        }
    }

    /// Choose the CoreGraphics window number for the AX window we just read.
    ///
    /// Frame match wins over title. Same-title windows are common — two
    /// documents, two browser windows — and a title-only match resolves them to
    /// whichever the window list happens to report first, often the wrong one.
    /// The AX window's screen frame uniquely identifies it, so when a
    /// candidate's bounds match that frame we trust it; only with no frame match
    /// do we fall back to exact title, then the first named layer-0 window.
    static func selectWindowNumber(
        from descriptors: [CGWindowDescriptor],
        pid: pid_t,
        title: String?,
        frame: CGRect?
    ) -> UInt32? {
        let candidates = descriptors.filter { $0.ownerPID == pid && $0.layer == 0 }
        guard !candidates.isEmpty else { return nil }

        if let frame, frame.width > 0, frame.height > 0 {
            let closest = candidates
                .compactMap { candidate -> (number: UInt32, distance: CGFloat)? in
                    guard let bounds = candidate.bounds else { return nil }
                    return (candidate.windowNumber, frameDistance(bounds, frame))
                }
                .min { $0.distance < $1.distance }
            if let closest, closest.distance <= frameMatchTolerance {
                return closest.number
            }
        }

        if
            let title,
            !title.isEmpty,
            let exact = candidates.first(where: { $0.title == title })
        {
            return exact.windowNumber
        }

        if let named = candidates.first(where: { !($0.title ?? "").isEmpty }) {
            return named.windowNumber
        }

        return candidates.first?.windowNumber
    }

    /// Manhattan distance between two frames over both origin and size. Small
    /// when two frames describe the same on-screen window, large otherwise.
    static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY)
            + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// Largest total frame drift (in points) still treated as the same window.
    /// Generous enough to absorb rounding between AX and CoreGraphics, yet far
    /// tighter than the gap between distinct windows (macOS cascades by ~22pt).
    static let frameMatchTolerance: CGFloat = 10

    /// Parse a CoreGraphics bounds dictionary (`X`/`Y`/`Width`/`Height`) into a
    /// `CGRect`, or nil if any component is missing.
    private static func parseBounds(_ value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any] else { return nil }
        guard
            let x = doubleValue(dict["X"]),
            let y = doubleValue(dict["Y"]),
            let width = doubleValue(dict["Width"]),
            let height = doubleValue(dict["Height"])
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
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
