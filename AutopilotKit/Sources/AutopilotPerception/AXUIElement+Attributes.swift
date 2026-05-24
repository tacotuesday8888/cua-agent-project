import ApplicationServices
import CoreGraphics
import Foundation

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

    /// A display string for an attribute whose value may be text *or* a number.
    ///
    /// Text fields report `AXValue` as a string, but checkboxes, radio buttons,
    /// sliders, steppers, and disclosure triangles report it as a number (for
    /// example a checkbox is 0, 1, or 2). `stringAttribute` casts strictly to
    /// `String` and so drops those numeric values, hiding control state from the
    /// agent — it could not tell whether a checkbox was already checked.
    func valueString(_ attribute: String) -> String? {
        Self.coerceValue(attributeValue(attribute, as: AnyObject.self))
    }

    /// Coerce a raw Accessibility value into a faithful display string. Kept
    /// pure and free of live AX state so it can be unit-tested directly.
    static func coerceValue(_ raw: Any?) -> String? {
        switch raw {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    /// The first non-empty string among `values`, or nil if all are empty/nil.
    ///
    /// AppKit reports a missing `AXTitle` as an *empty* string rather than nil
    /// (an icon-only button created without a title is the common case), so a
    /// plain `title ?? description` keeps the empty title and never falls back to
    /// the description that actually labels the control. Treating empty as absent
    /// lets the fallback fire so the agent still sees a name for the element.
    static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values where !(value ?? "").isEmpty {
            return value
        }
        return nil
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

    /// The element's screen frame (top-left origin) when both position and size
    /// read successfully. Used to disambiguate windows that share a title from
    /// the CoreGraphics window list, which AX position/size match by geometry.
    func frame() -> CGRect? {
        guard
            let origin = pointAttribute(kAXPositionAttribute),
            let size = sizeAttribute(kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: origin, size: size)
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
