import AutopilotAction
import AutopilotAgent
import AutopilotCore
import Foundation
import Testing
@testable import AutopilotMac

/// Action-path tests for `MacComputer`, driven through the `MacActuating` seam so
/// the press → click and focus → click fallbacks and the element-resolution
/// error paths are covered without Accessibility permissions or a real app.
struct MacComputerActionTests {
    /// Build a snapshot of `AXButton`s with the given ids and frames.
    private func snapshot(_ elements: [(String, ElementFrame)], turn: Int = 1) -> UITreeSnapshot {
        let children = elements.map { UIElement(id: $0.0, role: "AXButton", frame: $0.1) }
        let root = UIElement(id: "root", role: "AXWindow", children: children)
        return UITreeSnapshot(appName: "App", turnIdentifier: turn, root: root)
    }

    private func actuationError(_ detail: String) -> AccessibilityActuator.ActuationError {
        .actionFailed(detail)
    }

    // MARK: - click fallback

    @Test func pressFailureFallsBackToCoordinateClick() async throws {
        let mock = MockActuator()
        mock.pressError = actuationError("no press")
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)
        await computer.loadForTesting(
            snapshot: snapshot([("e1", ElementFrame(x: 10, y: 20, width: 100, height: 40))])
        )

        try await computer.click(elementID: "e1")

        #expect(mock.calls == ["press:e1", "click:60,40"])
    }

    @Test func pressAndClickBothFailSurfaceOriginalPressError() async {
        let mock = MockActuator()
        mock.pressError = actuationError("press detail")
        mock.clickError = actuationError("click detail")
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)
        await computer.loadForTesting(
            snapshot: snapshot([("e1", ElementFrame(x: 0, y: 0, width: 10, height: 10))])
        )

        do {
            try await computer.click(elementID: "e1")
            Issue.record("expected click to throw")
        } catch let error as AccessibilityActuator.ActuationError {
            // The more-informative press error wins over the fallback's failure.
            #expect(error.errorDescription == "press detail")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(mock.calls == ["press:e1", "click:5,5"])
    }

    @Test func clickResolutionErrorSkipsFallback() async {
        let mock = MockActuator()
        mock.resolutionError = ComputerControlError.invalidElement(
            elementID: "e1", appName: "App", turnIdentifier: 1
        )
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)
        await computer.loadForTesting(
            snapshot: snapshot([("e1", ElementFrame(x: 0, y: 0, width: 10, height: 10))])
        )

        do {
            try await computer.click(elementID: "e1")
            Issue.record("expected click to throw")
        } catch let error as ComputerControlError {
            #expect(error == .invalidElement(elementID: "e1", appName: "App", turnIdentifier: 1))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        // A resolution failure is not an actuation failure, so no fallback click.
        #expect(mock.calls == ["press:e1"])
    }

    @Test func clickOnEmptyCacheThrowsNoCachedState() async {
        // Uses the real LiveMacActuator (public init); the empty-map guard runs
        // before any AX call, so this needs no TCC.
        let computer = MacComputer(pid: 1, appName: "App")

        do {
            try await computer.click(elementID: "e1")
            Issue.record("expected click to throw")
        } catch let error as ComputerControlError {
            #expect(error == .noCachedState(appName: "App"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - typeText fallback

    @Test func typeIntoElementFocusFailsThenClicksThenTypes() async throws {
        let mock = MockActuator()
        mock.focusError = actuationError("no focus")
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)
        await computer.loadForTesting(
            snapshot: snapshot([("e1", ElementFrame(x: 10, y: 20, width: 100, height: 40))])
        )

        try await computer.typeText("hi", into: "e1")

        #expect(mock.calls == ["focus:e1", "click:60,40", "typeText:hi"])
    }

    @Test func typeIntoElementFocusSucceedsSkipsClick() async throws {
        let mock = MockActuator()
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)
        await computer.loadForTesting(
            snapshot: snapshot([("e1", ElementFrame(x: 0, y: 0, width: 10, height: 10))])
        )

        try await computer.typeText("hi", into: "e1")

        #expect(mock.calls == ["focus:e1", "typeText:hi"])
    }

    @Test func typeWithoutElementJustTypes() async throws {
        let mock = MockActuator()
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)

        try await computer.typeText("hi", into: nil)

        #expect(mock.calls == ["typeText:hi"])
    }

    // MARK: - straight delegation

    @Test func setValueDelegatesAndPropagatesErrors() async throws {
        let mock = MockActuator()
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)
        try await computer.setValue(elementID: "e1", value: "x")
        #expect(mock.calls == ["setValue:e1=x"])

        let failing = MockActuator()
        failing.setValueError = AccessibilityActuator.ActuationError.attributeNotSettable("AXValue")
        let computer2 = MacComputer(pid: 1, appName: "App", mac: failing)
        do {
            try await computer2.setValue(elementID: "e1", value: "x")
            Issue.record("expected setValue to throw")
        } catch is AccessibilityActuator.ActuationError {
            // expected
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func scrollWithElementComputesCenter() async throws {
        let mock = MockActuator()
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)
        await computer.loadForTesting(
            snapshot: snapshot([("e1", ElementFrame(x: 10, y: 20, width: 100, height: 40))])
        )

        try await computer.scroll(elementID: "e1", direction: .down, amount: 3)

        #expect(mock.calls == ["scroll:down:3:60,40"])
    }

    @Test func scrollWithoutElementPassesNilPoint() async throws {
        let mock = MockActuator()
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)

        try await computer.scroll(elementID: nil, direction: .up, amount: 2)

        #expect(mock.calls == ["scroll:up:2"])
    }

    @Test func dragComputesBothCenters() async throws {
        let mock = MockActuator()
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)
        await computer.loadForTesting(snapshot: snapshot([
            ("e1", ElementFrame(x: 0, y: 0, width: 10, height: 10)),
            ("e2", ElementFrame(x: 100, y: 100, width: 20, height: 20))
        ]))

        try await computer.drag(fromElementID: "e1", toElementID: "e2")

        #expect(mock.calls == ["drag:5,5->110,110"])
    }

    @Test func pressKeyDelegates() async throws {
        let mock = MockActuator()
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)

        try await computer.pressKey(KeyPress(key: "return"))

        #expect(mock.calls == ["key:return"])
    }

    @Test func performSecondaryActionDelegatesAndPropagatesErrors() async throws {
        let mock = MockActuator()
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)
        try await computer.performSecondaryAction(elementID: "e1", action: "AXShowMenu")
        #expect(mock.calls == ["perform:e1:AXShowMenu"])

        let failing = MockActuator()
        failing.performError = actuationError("nope")
        let computer2 = MacComputer(pid: 1, appName: "App", mac: failing)
        do {
            try await computer2.performSecondaryAction(elementID: "e1", action: "AXShowMenu")
            Issue.record("expected perform to throw")
        } catch is AccessibilityActuator.ActuationError {
            // expected
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func captureFeedsElementKeysToTheSeam() async {
        // loadForTesting mirrors what captureTree feeds the seam: element keys
        // plus the snapshot's turn id, so stale-context errors stay consistent.
        let mock = MockActuator()
        let computer = MacComputer(pid: 1, appName: "App", mac: mock)
        await computer.loadForTesting(
            snapshot: snapshot([("e1", .zero)], turn: 7),
            elements: [:]
        )
        #expect(mock.lastTurnIdentifier == 7)
    }
}
