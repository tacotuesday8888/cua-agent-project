import ApplicationServices
import CoreGraphics

/// Thin, type-safe helpers over the C-style Accessibility attribute API.
extension AXUIElement {
    /// Copy an attribute value and cast it to the requested type.
    func attributeValue<T>(_ attribute: String, as type: T.Type = T.self) -> T? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(self, attribute as CFString, &raw)
        guard status == .success, let raw else { return nil }
        return raw as? T
    }

    /// A string attribute (e.g. role, title, description).
    func stringAttribute(_ attribute: String) -> String? {
        attributeValue(attribute, as: String.self)
    }

    /// A boolean attribute (e.g. enabled, focused). Defaults to `false`.
    func boolAttribute(_ attribute: String) -> Bool {
        attributeValue(attribute, as: Bool.self) ?? false
    }

    /// The element's children, or an empty array.
    func childElements() -> [AXUIElement] {
        attributeValue(kAXChildrenAttribute, as: [AXUIElement].self) ?? []
    }

    /// A `CGPoint`-typed AXValue attribute (e.g. position).
    func pointAttribute(_ attribute: String) -> CGPoint? {
        guard let axValue: AXValue = attributeValue(attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// A `CGSize`-typed AXValue attribute (e.g. size).
    func sizeAttribute(_ attribute: String) -> CGSize? {
        guard let axValue: AXValue = attributeValue(attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Accessibility action names advertised by this element.
    func actionNames() -> [String] {
        var raw: CFArray?
        let status = AXUIElementCopyActionNames(self, &raw)
        guard status == .success, let raw else { return [] }
        return (raw as? [String]) ?? []
    }

    /// Whether an accessibility attribute can be set directly.
    func isAttributeSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(self, attribute as CFString, &settable)
        return status == .success && settable.boolValue
    }
}
