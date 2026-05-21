import ApplicationServices
import AutopilotCore
import CoreGraphics
import Foundation

/// Actuation seam for `MacComputer`.
///
/// Hides `AXUIElement` behind string element ids and screen points so the
/// driver's orchestration — the press → click and focus → click fallbacks, turn
/// bookkeeping, and snapshot-based center math — can be unit-tested without
/// Accessibility permissions or a running app. `LiveMacActuator` is the
/// production conformer; tests use a recording mock.
///
/// Class-bound and intentionally **not** `Sendable`: the live conformer stores
/// non-`Sendable` `AXUIElement` references and is only ever touched from inside
/// the `MacComputer` actor's isolation domain.
protocol MacActuating: AnyObject {
    /// Replace the live element map and current turn after a capture.
    func updateElements(_ elements: [String: AXUIElement], turnIdentifier: Int?)

    /// Press / activate the element with the given id.
    func press(elementID: String) throws
    /// Move keyboard focus to the element with the given id.
    func focus(elementID: String) throws
    /// Replace the text value of the element with the given id.
    func setValue(elementID: String, to value: String) throws
    /// Perform a specific advertised AX action on the element with the given id.
    func perform(action: String, elementID: String) throws

    /// Click a screen point — the press → click and focus → click fallback target.
    func click(at point: CGPoint) throws
    /// Type Unicode text into the target app.
    func typeText(_ text: String) throws
    /// Send a key press to the target app.
    func pressKey(_ key: KeyPress) throws
    /// Scroll, optionally anchored at a screen point.
    func scroll(direction: ScrollDirection, amount: Int, at point: CGPoint?) throws
    /// Drag between two screen points.
    func drag(from start: CGPoint, to end: CGPoint) throws
}
