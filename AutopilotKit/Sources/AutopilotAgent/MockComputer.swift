import AutopilotCore
import Foundation

/// An in-memory `ComputerControl` for tests: it holds a mutable UI tree, applies
/// actions to it, and records what it was asked to do — so the agent loop can be
/// exercised without real macOS automation.
public actor MockComputer: ComputerControl {
    public nonisolated let appName: String

    private var snapshot: UITreeSnapshot
    private var actionLog: [String] = []

    public init(appName: String, root: UIElement, windowTitle: String? = nil) {
        self.appName = appName
        self.snapshot = UITreeSnapshot(appName: appName, windowTitle: windowTitle, root: root)
    }

    public func captureTree() async throws -> UITreeSnapshot {
        snapshot
    }

    public func click(elementID: String) async throws {
        guard snapshot.element(id: elementID) != nil else {
            throw AgentError.computer("no element with id \(elementID)")
        }
        actionLog.append("click:\(elementID)")
    }

    public func setValue(elementID: String, value: String) async throws {
        guard snapshot.element(id: elementID) != nil else {
            throw AgentError.computer("no element with id \(elementID)")
        }
        snapshot = UITreeSnapshot(
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle,
            root: snapshot.root.settingValue(value, forID: elementID)
        )
        actionLog.append("setValue:\(elementID)=\(value)")
    }

    public func scroll(elementID: String?, direction: ScrollDirection, amount: Int) async throws {
        actionLog.append("scroll:\(direction.rawValue):\(amount)")
    }

    public func pressKey(_ key: KeyPress) async throws {
        actionLog.append("key:\(key.key)")
    }

    public func captureScreenshot() async throws -> Data {
        actionLog.append("screenshot")
        return Data()
    }

    /// The actions performed so far, in order — for test assertions.
    public var performedActions: [String] {
        actionLog
    }
}
