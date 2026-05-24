import AutopilotCore
import Testing
@testable import AutopilotAgent

/// The fixture smoke run includes snapshot-only checks that the accessibility
/// reader still captures a checkbox's numeric value and an icon-only button's
/// label — the two perception fixes. These exercise that verification logic in
/// CI (no Accessibility permission needed) with hand-built snapshots; the real
/// AX extraction is proven on a Mac via the fixture app.
struct ComputerUseSmokePerceptionTests {
    private func snapshot(
        checkboxValue: String?,
        iconButtonLabel: String?
    ) -> UITreeSnapshot {
        let checkbox = UIElement(
            id: "e1",
            role: "AXCheckBox",
            identifier: "autopilot.fixture.checkbox",
            label: "Notify me",
            value: checkboxValue
        )
        let iconButton = UIElement(
            id: "e2",
            role: "AXButton",
            identifier: "autopilot.fixture.icon-button",
            label: iconButtonLabel
        )
        let root = UIElement(
            id: "e0",
            role: "AXWindow",
            children: [checkbox, iconButton]
        )
        return UITreeSnapshot(appName: "AutopilotFixtureApp", root: root)
    }

    @Test func capturedValueAndLabelPass() {
        let steps = ComputerUseSmokeRunner.perceptionVerificationSteps(
            snapshot: snapshot(checkboxValue: "1", iconButtonLabel: "Information"),
            identifiers: .autopilotFixture
        )
        #expect(steps.count == 2)
        #expect(steps.allSatisfy { $0.status == .passed })
    }

    @Test func droppedNumericValueFails() {
        // The pre-fix behavior: a numeric AXValue cast to String yields nil.
        let steps = ComputerUseSmokeRunner.perceptionVerificationSteps(
            snapshot: snapshot(checkboxValue: nil, iconButtonLabel: "Information"),
            identifiers: .autopilotFixture
        )
        #expect(steps.first { $0.toolName == "verify_checkbox_value" }?.status == .failed)
        #expect(steps.first { $0.toolName == "verify_icon_button_label" }?.status == .passed)
    }

    @Test func uncheckedCheckboxStillCountsAsCaptured() {
        // "0" is a real captured value (unchecked), not a dropped one.
        let steps = ComputerUseSmokeRunner.perceptionVerificationSteps(
            snapshot: snapshot(checkboxValue: "0", iconButtonLabel: "Information"),
            identifiers: .autopilotFixture
        )
        #expect(steps.first { $0.toolName == "verify_checkbox_value" }?.status == .passed)
    }

    @Test func missingLabelFails() {
        // The pre-fix behavior: an empty AXTitle suppresses the AXDescription
        // fallback, leaving the icon button unlabeled.
        let steps = ComputerUseSmokeRunner.perceptionVerificationSteps(
            snapshot: snapshot(checkboxValue: "1", iconButtonLabel: nil),
            identifiers: .autopilotFixture
        )
        #expect(steps.first { $0.toolName == "verify_icon_button_label" }?.status == .failed)
    }

    @Test func missingElementsFail() {
        let empty = UITreeSnapshot(
            appName: "Fixture",
            root: UIElement(id: "e0", role: "AXWindow")
        )
        let steps = ComputerUseSmokeRunner.perceptionVerificationSteps(
            snapshot: empty,
            identifiers: .autopilotFixture
        )
        #expect(steps.count == 2)
        #expect(steps.allSatisfy { $0.status == .failed })
    }

    @Test func absentIdentifiersProduceNoSteps() {
        // Identifiers without checkbox/icon-button (the default) add no steps, so
        // existing mock-based smoke runs are unaffected.
        let identifiers = ComputerUseSmokeFixtureIdentifiers(
            clickIdentifier: "click",
            textIdentifier: "text",
            dragFromIdentifier: "from",
            dragToIdentifier: "to",
            secondaryIdentifier: "secondary",
            secondaryAction: "AXPress"
        )
        let steps = ComputerUseSmokeRunner.perceptionVerificationSteps(
            snapshot: snapshot(checkboxValue: "1", iconButtonLabel: "Information"),
            identifiers: identifiers
        )
        #expect(steps.isEmpty)
    }
}
