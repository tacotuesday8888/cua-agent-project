import Foundation

/// A rectangle in screen coordinates.
public struct ElementFrame: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// A zero-origin, zero-size frame.
    public static let zero = ElementFrame()
}

/// A single accessibility element captured from a macOS app's UI tree.
public struct UIElement: Sendable, Hashable, Codable, Identifiable {
    /// Stable identifier assigned during serialization, e.g. "e12".
    public let id: String
    /// Accessibility role, e.g. "AXButton", "AXTextField".
    public let role: String
    /// Accessibility subrole, when the app exposes one.
    public let subrole: String?
    /// App-provided accessibility identifier, when available.
    public let identifier: String?
    /// Human-readable label (AXTitle / AXDescription).
    public let label: String?
    /// Current value, e.g. a text field's contents.
    public let value: String?
    /// Whether the element is enabled and actionable.
    public let isEnabled: Bool
    /// Whether the element currently holds keyboard focus.
    public let isFocused: Bool
    /// Whether AXValue can be set directly on this element.
    public let isValueSettable: Bool
    /// Accessibility actions exposed by this element, e.g. AXPress or AXOpen.
    public let actions: [String]
    /// Screen-space frame, used for screenshot disambiguation.
    public let frame: ElementFrame
    /// Child elements.
    public let children: [UIElement]

    public init(
        id: String,
        role: String,
        subrole: String? = nil,
        identifier: String? = nil,
        label: String? = nil,
        value: String? = nil,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        isValueSettable: Bool = false,
        actions: [String] = [],
        frame: ElementFrame = .zero,
        children: [UIElement] = []
    ) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.label = label
        self.value = value
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isValueSettable = isValueSettable
        self.actions = actions
        self.frame = frame
        self.children = children
    }
}

public extension UIElement {
    /// Depth-first search for an element by id, including self.
    func firstDescendant(id: String) -> UIElement? {
        if self.id == id { return self }
        for child in children {
            if let found = child.firstDescendant(id: id) { return found }
        }
        return nil
    }

    /// Every element in the subtree, depth-first, including self.
    var flattened: [UIElement] {
        [self] + children.flatMap(\.flattened)
    }

    /// A copy of the subtree with the value of element `id` replaced.
    func settingValue(_ newValue: String, forID id: String) -> UIElement {
        UIElement(
            id: self.id,
            role: role,
            subrole: subrole,
            identifier: identifier,
            label: label,
            value: self.id == id ? newValue : value,
            isEnabled: isEnabled,
            isFocused: isFocused,
            isValueSettable: isValueSettable,
            actions: actions,
            frame: frame,
            children: children.map { $0.settingValue(newValue, forID: id) }
        )
    }
}

/// A snapshot of one app's UI at a moment in time.
public struct UITreeSnapshot: Sendable, Codable {
    public let appName: String
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let windowTitle: String?
    public let windowIdentifier: UInt32?
    public let turnIdentifier: Int?
    public let root: UIElement
    /// Whether the capture hit the element budget and stopped early, so this
    /// tree is an incomplete view of the app's UI. Surfaced to the model so it
    /// knows to scroll or narrow its focus rather than assume it sees everything.
    public let isTruncated: Bool
    public let capturedAt: Date

    public init(
        appName: String,
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil,
        windowTitle: String? = nil,
        windowIdentifier: UInt32? = nil,
        turnIdentifier: Int? = nil,
        root: UIElement,
        isTruncated: Bool = false,
        capturedAt: Date = Date()
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowTitle = windowTitle
        self.windowIdentifier = windowIdentifier
        self.turnIdentifier = turnIdentifier
        self.root = root
        self.isTruncated = isTruncated
        self.capturedAt = capturedAt
    }

    /// Look up an element anywhere in the tree by id.
    public func element(id: String) -> UIElement? {
        root.firstDescendant(id: id)
    }
}
