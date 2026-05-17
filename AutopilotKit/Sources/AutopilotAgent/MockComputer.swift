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

    public func listApps() async throws -> [ComputerAppInfo] {
        [
            ComputerAppInfo(
                name: appName,
                bundleIdentifier: snapshot.bundleIdentifier,
                processIdentifier: snapshot.processIdentifier,
                isTarget: true
            )
        ]
    }

    public func click(elementID: String) async throws {
        guard snapshot.element(id: elementID) != nil else {
            throw invalidElement(elementID)
        }
        actionLog.append("click:\(elementID)")
    }

    public func setValue(elementID: String, value: String) async throws {
        guard snapshot.element(id: elementID) != nil else {
            throw invalidElement(elementID)
        }
        snapshot = UITreeSnapshot(
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle,
            root: snapshot.root.settingValue(value, forID: elementID)
        )
        actionLog.append("setValue:\(elementID)=\(value)")
    }

    public func typeText(_ text: String) async throws {
        actionLog.append("typeText:\(text)")
    }

    public func scroll(elementID: String?, direction: ScrollDirection, amount: Int) async throws {
        if let elementID, snapshot.element(id: elementID) == nil {
            throw invalidElement(elementID)
        }
        actionLog.append("scroll:\(direction.rawValue):\(amount)")
    }

    public func pressKey(_ key: KeyPress) async throws {
        actionLog.append("key:\(key.key)")
    }

    public func drag(fromElementID: String, toElementID: String) async throws {
        guard snapshot.element(id: fromElementID) != nil else {
            throw invalidElement(fromElementID)
        }
        guard snapshot.element(id: toElementID) != nil else {
            throw invalidElement(toElementID)
        }
        actionLog.append("drag:\(fromElementID)->\(toElementID)")
    }

    public func performSecondaryAction(elementID: String, action: String) async throws {
        guard let element = snapshot.element(id: elementID) else {
            throw invalidElement(elementID)
        }
        guard element.actions.contains(action) else {
            throw ComputerControlError.unavailableAction(elementID: elementID, action: action)
        }
        actionLog.append("secondary:\(elementID):\(action)")
    }

    public func captureScreenshot() async throws -> Data {
        actionLog.append("screenshot")
        return Data()
    }

    /// The actions performed so far, in order — for test assertions.
    public var performedActions: [String] {
        actionLog
    }

    private func invalidElement(_ elementID: String) -> ComputerControlError {
        ComputerControlError.invalidElement(
            elementID: elementID,
            appName: appName,
            turnIdentifier: snapshot.turnIdentifier
        )
    }
}
