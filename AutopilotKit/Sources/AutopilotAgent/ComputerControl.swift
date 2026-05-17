import AutopilotCore
import Foundation

/// The set of actions the agent can perform on a single controlled app.
///
/// The production implementation is backed by the macOS Accessibility APIs
/// (via cua's Driver); tests use `MockComputer`.
public protocol ComputerControl: Sendable {
    /// The name of the app this controller operates.
    var appName: String { get }

    /// Capture the current accessibility-tree snapshot of the app.
    func captureTree() async throws -> UITreeSnapshot

    /// Press or activate the element with the given id.
    func click(elementID: String) async throws

    /// Set the text value of the element with the given id.
    func setValue(elementID: String, value: String) async throws

    /// Scroll, optionally within a specific scrollable element.
    func scroll(elementID: String?, direction: ScrollDirection, amount: Int) async throws

    /// Send a key press to the app.
    func pressKey(_ key: KeyPress) async throws

    /// Capture a PNG screenshot of the app window.
    func captureScreenshot() async throws -> Data
}
