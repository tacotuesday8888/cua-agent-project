import AutopilotCore
import Testing
@testable import AutopilotAgent

struct ActionEffectVerifierTests {
    @Test func noOpClickProducesWarning() {
        let before = snapshot(children: [
            UIElement(id: "e2", role: "AXButton", identifier: "run", label: "Run")
        ])
        let target = ActionTarget(
            appName: "Fixture",
            elementID: "e2",
            role: "AXButton",
            label: "Run",
            identifier: "run",
            description: "Click \"Run\""
        )

        let result = ActionEffectVerifier().verify(
            tool: .click,
            input: ["element_index": 2],
            target: target,
            before: before,
            after: before
        )

        #expect(result.status == .unchanged)
        #expect(result.signals.contains(.noVisibleChange))
        #expect(result.shouldWarnModel)
    }

    @Test func setValueSeesExpectedTextOnMatchedTarget() {
        let before = snapshot(children: [
            UIElement(
                id: "e2",
                role: "AXTextField",
                identifier: "input",
                label: "Input",
                value: "",
                isValueSettable: true
            )
        ])
        let after = snapshot(children: [
            UIElement(
                id: "e4",
                role: "AXTextField",
                identifier: "input",
                label: "Input",
                value: "hello",
                isValueSettable: true
            )
        ])
        let target = ActionTarget(
            appName: "Fixture",
            elementID: "e2",
            role: "AXTextField",
            label: "Input",
            identifier: "input",
            value: "",
            description: "Type \"hello\""
        )

        let result = ActionEffectVerifier().verify(
            tool: .setValue,
            input: ["element_index": 2, "value": "hello"],
            target: target,
            before: before,
            after: after
        )

        #expect(result.status == .changed)
        #expect(result.signals.contains(.expectedTextObserved))
        #expect(result.signals.contains(.targetValueChanged))
        #expect(!result.shouldWarnModel)
    }

    @Test func changedWindowIsCapturedAsSignal() {
        let before = snapshot(windowTitle: "Doc A", windowIdentifier: 10, children: [
            UIElement(id: "e2", role: "AXButton", label: "Open")
        ])
        let after = snapshot(windowTitle: "Doc B", windowIdentifier: 20, children: [
            UIElement(id: "e2", role: "AXButton", label: "Open")
        ])

        let result = ActionEffectVerifier().verify(
            tool: .click,
            input: ["element_index": 2],
            target: ActionTarget(appName: "Fixture", elementID: "e2", description: "Click Open"),
            before: before,
            after: after
        )

        #expect(result.status == .changed)
        #expect(result.signals.contains(.windowChanged))
    }

    @Test func missingTargetWarnsModel() {
        let before = snapshot(children: [
            UIElement(id: "e2", role: "AXButton", identifier: "run", label: "Run")
        ])
        let after = snapshot(children: [
            UIElement(id: "e2", role: "AXButton", identifier: "other", label: "Other")
        ])

        let result = ActionEffectVerifier().verify(
            tool: .click,
            input: ["element_index": 2],
            target: ActionTarget(
                appName: "Fixture",
                elementID: "e2",
                role: "AXButton",
                label: "Run",
                identifier: "run",
                description: "Click Run"
            ),
            before: before,
            after: after
        )

        #expect(result.signals.contains(.targetMissing))
        #expect(result.shouldWarnModel)
    }

    @Test func modalPresenceIsCapturedAsSignal() {
        let before = snapshot(children: [
            UIElement(id: "e2", role: "AXButton", label: "Details")
        ])
        let after = snapshot(children: [
            UIElement(id: "e2", role: "AXButton", label: "Details"),
            UIElement(id: "e3", role: "AXSheet", label: "Details")
        ])

        let result = ActionEffectVerifier().verify(
            tool: .click,
            input: ["element_index": 2],
            target: ActionTarget(appName: "Fixture", elementID: "e2", description: "Click Details"),
            before: before,
            after: after
        )

        #expect(result.status == .changed)
        #expect(result.signals.contains(.modalPresent))
    }

    private func snapshot(
        windowTitle: String = "Fixture",
        windowIdentifier: UInt32 = 1,
        children: [UIElement]
    ) -> UITreeSnapshot {
        UITreeSnapshot(
            appName: "Fixture",
            windowTitle: windowTitle,
            windowIdentifier: windowIdentifier,
            root: UIElement(id: "e1", role: "AXWindow", children: children)
        )
    }
}
