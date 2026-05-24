import ApplicationServices
import Foundation
import Testing
@testable import AutopilotPerception

/// `AccessibilityTreeReader` reads each element's value with `coerceValue` so
/// the agent can perceive the state of controls that report a numeric `AXValue`
/// — checkboxes, radio buttons, sliders, steppers, and disclosure triangles —
/// not just text fields. A strict `String` cast (the previous behavior) dropped
/// those values, leaving the agent unable to tell, say, whether a checkbox was
/// already checked.
struct AccessibilityValueTests {
    @Test func textValuePassesThrough() {
        #expect(AXUIElement.coerceValue("jazz") == "jazz")
    }

    @Test func emptyTextStaysEmptySoTheRendererCanHideIt() {
        // The renderer drops empty values; coercion must not turn "" into nil
        // (a real, focused-but-empty text field) or vice versa.
        #expect(AXUIElement.coerceValue("") == "")
    }

    @Test func checkboxCheckedAndUncheckedAreCaptured() {
        // AXCheckBox / AXRadioButton report AXValue as a number: 0, 1, or 2.
        #expect(AXUIElement.coerceValue(NSNumber(value: 1)) == "1")
        #expect(AXUIElement.coerceValue(NSNumber(value: 0)) == "0")
    }

    @Test func checkboxMixedStateIsCaptured() {
        #expect(AXUIElement.coerceValue(NSNumber(value: 2)) == "2")
    }

    @Test func sliderFractionalValueIsCaptured() {
        #expect(AXUIElement.coerceValue(NSNumber(value: 0.5)) == "0.5")
        #expect(AXUIElement.coerceValue(NSNumber(value: 50.0)) == "50")
    }

    @Test func booleanBackedValueIsCaptured() {
        #expect(AXUIElement.coerceValue(NSNumber(value: true)) == "1")
        #expect(AXUIElement.coerceValue(NSNumber(value: false)) == "0")
    }

    @Test func missingValueStaysNil() {
        #expect(AXUIElement.coerceValue(nil) == nil)
    }

    @Test func unsupportedValueTypeIsDroppedRatherThanStringified() {
        // A structured AXValue (e.g. a wrapped CGPoint/CGSize) is not a useful
        // value string; coercion returns nil instead of an opaque description.
        #expect(AXUIElement.coerceValue(["a", "b"]) == nil)
    }
}

/// `AccessibilityTreeReader` resolves an element's label as the first non-empty
/// of its title and description. AppKit reports a missing `AXTitle` as an empty
/// string, not nil, so a plain `title ?? description` would keep the empty title
/// and never reach the description that actually names an icon-only control.
struct AccessibilityLabelTests {
    @Test func titlePreferredWhenPresent() {
        #expect(AXUIElement.firstNonEmpty("OK", "Confirm the dialog") == "OK")
    }

    @Test func emptyTitleFallsBackToDescription() {
        // The real bug: an icon button with no title (AXTitle == "") but an
        // accessibility label (AXDescription) must still surface a name.
        #expect(AXUIElement.firstNonEmpty("", "Back") == "Back")
    }

    @Test func nilTitleFallsBackToDescription() {
        #expect(AXUIElement.firstNonEmpty(nil, "Back") == "Back")
    }

    @Test func noTitleOrDescriptionIsNil() {
        #expect(AXUIElement.firstNonEmpty("", "") == nil)
        #expect(AXUIElement.firstNonEmpty(nil, nil) == nil)
    }

    @Test func whitespaceTitleIsKeptVerbatim() {
        // Coercion does not trim, matching the rest of the reader; only truly
        // empty strings count as absent.
        #expect(AXUIElement.firstNonEmpty(" ", "Back") == " ")
    }
}
