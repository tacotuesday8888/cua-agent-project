import AutopilotCore
import Foundation

/// A macOS app visible to the computer-use driver.
public struct ComputerAppInfo: Sendable, Hashable, Codable {
    public let name: String
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let isTarget: Bool

    public init(
        name: String,
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil,
        isTarget: Bool = false
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.isTarget = isTarget
    }
}

/// The current state returned by `get_app_state`.
public struct ComputerAppState: Sendable {
    public let snapshot: UITreeSnapshot
    public let screenshot: Data?

    public init(snapshot: UITreeSnapshot, screenshot: Data? = nil) {
        self.snapshot = snapshot
        self.screenshot = screenshot
    }
}

/// The set of actions the agent can perform on a single controlled app.
///
/// The production implementation is backed by the macOS Accessibility APIs
/// (via cua's Driver); tests use `MockComputer`.
public protocol ComputerControl: Sendable {
    /// The name of the app this controller operates.
    var appName: String { get }

    /// List apps available to the driver.
    func listApps() async throws -> [ComputerAppInfo]

    /// Return the target app state.
    func getAppState(includeScreenshot: Bool) async throws -> ComputerAppState

    /// Capture the current accessibility-tree snapshot of the app.
    func captureTree() async throws -> UITreeSnapshot

    /// Press or activate the element with the given id.
    func click(elementID: String) async throws

    /// Set the text value of the element with the given id.
    func setValue(elementID: String, value: String) async throws

    /// Type text into the app's currently-focused editable element.
    func typeText(_ text: String) async throws

    /// Scroll, optionally within a specific scrollable element.
    func scroll(elementID: String?, direction: ScrollDirection, amount: Int) async throws

    /// Send a key press to the app.
    func pressKey(_ key: KeyPress) async throws

    /// Drag from one captured element to another.
    func drag(fromElementID: String, toElementID: String) async throws

    /// Perform a non-primary AX action exposed by an element.
    func performSecondaryAction(elementID: String, action: String) async throws

    /// Capture a PNG screenshot of the app window.
    func captureScreenshot() async throws -> Data
}

public extension ComputerControl {
    func listApps() async throws -> [ComputerAppInfo] {
        [
            ComputerAppInfo(
                name: appName,
                bundleIdentifier: nil,
                processIdentifier: nil,
                isTarget: true
            )
        ]
    }

    func getAppState(includeScreenshot: Bool) async throws -> ComputerAppState {
        let snapshot = try await captureTree()
        let screenshot = includeScreenshot ? try await captureScreenshot() : nil
        return ComputerAppState(snapshot: snapshot, screenshot: screenshot)
    }

    func typeText(_ text: String) async throws {
        throw AgentError.computer("type_text is not implemented for \(appName)")
    }

    func drag(fromElementID: String, toElementID: String) async throws {
        throw AgentError.computer("drag is not implemented for \(appName)")
    }

    func performSecondaryAction(elementID: String, action: String) async throws {
        throw AgentError.computer("perform_secondary_action is not implemented for \(appName)")
    }
}
