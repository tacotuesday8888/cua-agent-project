import AutopilotCore
import Foundation

/// A deterministic smoke plan for the 9-tool computer-use driver surface.
public struct ComputerUseSmokePlan: Sendable, Hashable {
    public var clickElementIndex: Int
    public var scrollElementIndex: Int?
    public var scrollDirection: ScrollDirection
    public var scrollAmount: Int
    public var textElementIndex: Int
    public var setValue: String
    public var typeText: String
    public var keyPress: KeyPress
    public var dragFromElementIndex: Int
    public var dragToElementIndex: Int
    public var secondaryElementIndex: Int
    public var secondaryAction: String

    public init(
        clickElementIndex: Int,
        scrollElementIndex: Int? = nil,
        scrollDirection: ScrollDirection = .down,
        scrollAmount: Int = 3,
        textElementIndex: Int,
        setValue: String,
        typeText: String,
        keyPress: KeyPress,
        dragFromElementIndex: Int,
        dragToElementIndex: Int,
        secondaryElementIndex: Int,
        secondaryAction: String
    ) {
        self.clickElementIndex = clickElementIndex
        self.scrollElementIndex = scrollElementIndex
        self.scrollDirection = scrollDirection
        self.scrollAmount = scrollAmount
        self.textElementIndex = textElementIndex
        self.setValue = setValue
        self.typeText = typeText
        self.keyPress = keyPress
        self.dragFromElementIndex = dragFromElementIndex
        self.dragToElementIndex = dragToElementIndex
        self.secondaryElementIndex = secondaryElementIndex
        self.secondaryAction = secondaryAction
    }

    func elementID(_ index: Int) -> String {
        "e\(index)"
    }
}

/// One smoke-suite step result.
public struct ComputerUseSmokeStepResult: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case passed
        case failed
    }

    public let toolName: String
    public let status: Status
    public let detail: String

    public init(toolName: String, status: Status, detail: String) {
        self.toolName = toolName
        self.status = status
        self.detail = detail
    }
}

/// Report returned by a 9-tool driver smoke run.
public struct ComputerUseSmokeReport: Sendable, Hashable {
    public let appName: String
    public let steps: [ComputerUseSmokeStepResult]

    public init(appName: String, steps: [ComputerUseSmokeStepResult]) {
        self.appName = appName
        self.steps = steps
    }

    public var passed: Bool {
        !steps.contains { $0.status == .failed }
    }

    public var summary: String {
        let failed = steps.filter { $0.status == .failed }.count
        if failed == 0 {
            return "Computer-use smoke suite passed \(steps.count) step(s) for \(appName)."
        }
        return "Computer-use smoke suite failed \(failed) of \(steps.count) step(s) for \(appName)."
    }
}

/// Exercises the 9-tool computer-use surface without involving an LLM.
///
/// This gives us a reusable, deterministic validation path for mocks today and
/// for a real fixture app once the interactive macOS run is available.
public struct ComputerUseSmokeRunner: Sendable {
    public init() {}

    public func run(
        computer: any ComputerControl,
        plan: ComputerUseSmokePlan
    ) async -> ComputerUseSmokeReport {
        var steps: [ComputerUseSmokeStepResult] = []

        var step = await record("list_apps", {
            let apps = try await computer.listApps()
            guard apps.contains(where: { $0.isTarget }) else {
                throw AgentError.computer("list_apps did not include a target app")
            }
            return "Found \(apps.count) app(s)."
        })
        steps.append(step)
        guard step.status == .passed else {
            return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
        }

        step = await record("get_app_state", {
            let state = try await computer.getAppState(includeScreenshot: false)
            let count = state.snapshot.root.flattened.count
            guard count > 0 else {
                throw AgentError.computer("get_app_state returned an empty tree")
            }
            return "Read \(count) element(s)."
        })
        steps.append(step)
        guard step.status == .passed else {
            return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
        }

        step = await record("click", {
            try await computer.click(elementID: plan.elementID(plan.clickElementIndex))
            return "Clicked element \(plan.clickElementIndex)."
        })
        steps.append(step)
        guard step.status == .passed else {
            return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
        }

        step = await record("scroll", {
            try await computer.scroll(
                elementID: plan.scrollElementIndex.map { plan.elementID($0) },
                direction: plan.scrollDirection,
                amount: plan.scrollAmount
            )
            return "Scrolled \(plan.scrollDirection.rawValue)."
        })
        steps.append(step)
        guard step.status == .passed else {
            return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
        }

        step = await record("type_text", {
            try await computer.typeText(plan.typeText)
            return "Typed \(plan.typeText.count) character(s)."
        })
        steps.append(step)
        guard step.status == .passed else {
            return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
        }

        step = await record("press_key", {
            try await computer.pressKey(plan.keyPress)
            return "Pressed \(plan.keyPress.key)."
        })
        steps.append(step)
        guard step.status == .passed else {
            return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
        }

        step = await record("set_value", {
            try await computer.setValue(
                elementID: plan.elementID(plan.textElementIndex),
                value: plan.setValue
            )
            return "Set element \(plan.textElementIndex)."
        })
        steps.append(step)
        guard step.status == .passed else {
            return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
        }

        step = await record("drag", {
            try await computer.drag(
                fromElementID: plan.elementID(plan.dragFromElementIndex),
                toElementID: plan.elementID(plan.dragToElementIndex)
            )
            return "Dragged \(plan.dragFromElementIndex) to \(plan.dragToElementIndex)."
        })
        steps.append(step)
        guard step.status == .passed else {
            return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
        }

        step = await record("perform_secondary_action", {
            try await computer.performSecondaryAction(
                elementID: plan.elementID(plan.secondaryElementIndex),
                action: plan.secondaryAction
            )
            return "Performed \(plan.secondaryAction)."
        })
        steps.append(step)

        return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
    }

    private func record(
        _ toolName: String,
        _ operation: () async throws -> String
    ) async -> ComputerUseSmokeStepResult {
        do {
            let detail = try await operation()
            return ComputerUseSmokeStepResult(
                toolName: toolName,
                status: .passed,
                detail: detail
            )
        } catch {
            return ComputerUseSmokeStepResult(
                toolName: toolName,
                status: .failed,
                detail: describe(error)
            )
        }
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}
