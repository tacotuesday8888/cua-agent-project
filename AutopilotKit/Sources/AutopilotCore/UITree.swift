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
    /// Human-readable label (AXTitle / AXDescription).
    public let label: String?
    /// Current value, e.g. a text field's contents.
    public let value: String?
    /// Whether the element is enabled and actionable.
    public let isEnabled: Bool
    /// Whether the element currently holds keyboard focus.
    public let isFocused: Bool
    /// Screen-space frame, used for screenshot disambiguation.
    public let frame: ElementFrame
    /// Child elements.
    public let children: [UIElement]

    public init(
        id: String,
        role: String,
        label: String? = nil,
        value: String? = nil,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        frame: ElementFrame = .zero,
        children: [UIElement] = []
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.isEnabled = isEnabled
        self.isFocused = isFocused
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
            label: label,
            value: self.id == id ? newValue : value,
            isEnabled: isEnabled,
            isFocused: isFocused,
            frame: frame,
            children: children.map { $0.settingValue(newValue, forID: id) }
        )
    }
}

/// A snapshot of one app's UI at a moment in time.
public struct UITreeSnapshot: Sendable, Codable {
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitle: String?
    public let root: UIElement
    public let capturedAt: Date

    public init(
        appName: String,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        root: UIElement,
        capturedAt: Date = Date()
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.root = root
        self.capturedAt = capturedAt
    }

    /// Look up an element anywhere in the tree by id.
    public func element(id: String) -> UIElement? {
        root.firstDescendant(id: id)
    }
}
