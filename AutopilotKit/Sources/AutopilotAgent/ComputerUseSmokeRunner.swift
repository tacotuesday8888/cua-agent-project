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

/// Accessibility identifiers used by the bundled smoke fixture app.
public struct ComputerUseSmokeFixtureIdentifiers: Sendable, Hashable {
    public var clickIdentifier: String
    public var scrollIdentifier: String?
    public var textIdentifier: String
    public var dragFromIdentifier: String
    public var dragToIdentifier: String
    public var secondaryIdentifier: String
    public var secondaryAction: String
    /// A checkbox, used to verify the reader captures a numeric `AXValue`.
    public var checkboxIdentifier: String?
    /// An icon-only button, used to verify an empty `AXTitle` still resolves a
    /// label from `AXDescription`.
    public var iconButtonIdentifier: String?

    public init(
        clickIdentifier: String,
        scrollIdentifier: String? = nil,
        textIdentifier: String,
        dragFromIdentifier: String,
        dragToIdentifier: String,
        secondaryIdentifier: String,
        secondaryAction: String,
        checkboxIdentifier: String? = nil,
        iconButtonIdentifier: String? = nil
    ) {
        self.clickIdentifier = clickIdentifier
        self.scrollIdentifier = scrollIdentifier
        self.textIdentifier = textIdentifier
        self.dragFromIdentifier = dragFromIdentifier
        self.dragToIdentifier = dragToIdentifier
        self.secondaryIdentifier = secondaryIdentifier
        self.secondaryAction = secondaryAction
        self.checkboxIdentifier = checkboxIdentifier
        self.iconButtonIdentifier = iconButtonIdentifier
    }

    public static let autopilotFixture = ComputerUseSmokeFixtureIdentifiers(
        clickIdentifier: "autopilot.fixture.run-button",
        scrollIdentifier: "autopilot.fixture.scroll",
        textIdentifier: "autopilot.fixture.input",
        dragFromIdentifier: "autopilot.fixture.drag-source",
        dragToIdentifier: "autopilot.fixture.drop-target",
        secondaryIdentifier: "autopilot.fixture.run-button",
        secondaryAction: "AXPress",
        checkboxIdentifier: "autopilot.fixture.checkbox",
        iconButtonIdentifier: "autopilot.fixture.icon-button"
    )
}

public enum ComputerUseSmokePlanResolutionError: Error, Sendable, Equatable {
    case missingElement(identifier: String)
    case invalidElementID(String)
}

extension ComputerUseSmokePlanResolutionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingElement(let identifier):
            return "The fixture tree does not contain accessibility identifier \(identifier)."
        case .invalidElementID(let id):
            return "The fixture element id \(id) does not use the expected e<number> format."
        }
    }
}

public extension ComputerUseSmokePlan {
    /// Resolve the bundled fixture app's accessibility identifiers to the
    /// element indexes expected by the 9-tool smoke runner.
    static func autopilotFixturePlan(
        for snapshot: UITreeSnapshot,
        identifiers: ComputerUseSmokeFixtureIdentifiers = .autopilotFixture,
        setValue: String = "direct smoke value",
        typeText: String = " typed smoke",
        keyPress: KeyPress = KeyPress(key: "return"),
        scrollDirection: ScrollDirection = .down,
        scrollAmount: Int = 3
    ) throws -> ComputerUseSmokePlan {
        ComputerUseSmokePlan(
            clickElementIndex: try index(
                forIdentifier: identifiers.clickIdentifier,
                in: snapshot
            ),
            scrollElementIndex: try identifiers.scrollIdentifier.map {
                try index(forIdentifier: $0, in: snapshot)
            },
            scrollDirection: scrollDirection,
            scrollAmount: scrollAmount,
            textElementIndex: try index(
                forIdentifier: identifiers.textIdentifier,
                in: snapshot
            ),
            setValue: setValue,
            typeText: typeText,
            keyPress: keyPress,
            dragFromElementIndex: try index(
                forIdentifier: identifiers.dragFromIdentifier,
                in: snapshot
            ),
            dragToElementIndex: try index(
                forIdentifier: identifiers.dragToIdentifier,
                in: snapshot
            ),
            secondaryElementIndex: try index(
                forIdentifier: identifiers.secondaryIdentifier,
                in: snapshot
            ),
            secondaryAction: identifiers.secondaryAction
        )
    }

    private static func index(
        forIdentifier identifier: String,
        in snapshot: UITreeSnapshot
    ) throws -> Int {
        guard let element = snapshot.root.flattened.first(where: {
            $0.identifier == identifier
        }) else {
            throw ComputerUseSmokePlanResolutionError.missingElement(
                identifier: identifier
            )
        }
        return try index(fromElementID: element.id)
    }

    private static func index(fromElementID id: String) throws -> Int {
        guard id.first == "e", let index = Int(id.dropFirst()) else {
            throw ComputerUseSmokePlanResolutionError.invalidElementID(id)
        }
        return index
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
        plan: ComputerUseSmokePlan,
        includeScreenshot: Bool = false,
        perceptionIdentifiers: ComputerUseSmokeFixtureIdentifiers? = nil
    ) async -> ComputerUseSmokeReport {
        await run(
            computer: computer,
            initialPlan: plan,
            includeScreenshot: includeScreenshot,
            planResolver: nil,
            perceptionIdentifiers: perceptionIdentifiers
        )
    }

    public func run(
        computer: any ComputerControl,
        includeScreenshot: Bool = false,
        perceptionIdentifiers: ComputerUseSmokeFixtureIdentifiers? = nil,
        planForState planResolver: @escaping @Sendable (ComputerAppState) throws -> ComputerUseSmokePlan
    ) async -> ComputerUseSmokeReport {
        await run(
            computer: computer,
            initialPlan: nil,
            includeScreenshot: includeScreenshot,
            planResolver: planResolver,
            perceptionIdentifiers: perceptionIdentifiers
        )
    }

    private func run(
        computer: any ComputerControl,
        initialPlan: ComputerUseSmokePlan?,
        includeScreenshot: Bool,
        planResolver: (@Sendable (ComputerAppState) throws -> ComputerUseSmokePlan)?,
        perceptionIdentifiers: ComputerUseSmokeFixtureIdentifiers?
    ) async -> ComputerUseSmokeReport {
        var steps: [ComputerUseSmokeStepResult] = []
        var plan = initialPlan
        var latestSnapshot: UITreeSnapshot?

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
            let state = try await computer.getAppState(includeScreenshot: includeScreenshot)
            latestSnapshot = state.snapshot
            let count = state.snapshot.root.flattened.count
            guard count > 0 else {
                throw AgentError.computer("get_app_state returned an empty tree")
            }
            if includeScreenshot {
                if let warning = state.screenshotWarning {
                    throw AgentError.computer(warning)
                }
                guard let screenshot = state.screenshot, !screenshot.isEmpty else {
                    throw AgentError.computer("get_app_state did not return screenshot bytes")
                }
            }
            if let planResolver {
                plan = try planResolver(state)
            }
            if includeScreenshot {
                return "Read \(count) element(s) and captured screenshot."
            }
            return "Read \(count) element(s)."
        })
        steps.append(step)
        guard step.status == .passed else {
            return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
        }

        // Verify the reader still captures control state the agent depends on
        // (numeric checkbox value, icon-button label). Snapshot-only, so it adds
        // no driver actions; only runs when the fixture identifiers are supplied.
        if let perceptionIdentifiers, let snapshot = latestSnapshot {
            steps.append(contentsOf: Self.perceptionVerificationSteps(
                snapshot: snapshot,
                identifiers: perceptionIdentifiers
            ))
        }

        guard var activePlan = plan else {
            steps.append(ComputerUseSmokeStepResult(
                toolName: "resolve_plan",
                status: .failed,
                detail: "No smoke plan was provided or resolved from get_app_state."
            ))
            return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
        }

        // The seven driver actions run unconditionally and each result is
        // collected, so one validation run reports the full pass/fail matrix for
        // the tool surface rather than stopping at the first failure — which
        // matters most on a real Mac, where each run needs manual setup.
        steps.append(await record(
            "click",
            target: activePlan.elementID(activePlan.clickElementIndex),
            snapshot: latestSnapshot
        ) {
            try await computer.click(elementID: activePlan.elementID(activePlan.clickElementIndex))
            return "Clicked element \(activePlan.clickElementIndex)."
        })

        steps.append(await record(
            "scroll",
            target: activePlan.scrollElementIndex.map { activePlan.elementID($0) },
            snapshot: latestSnapshot
        ) {
            try await computer.scroll(
                elementID: activePlan.scrollElementIndex.map { activePlan.elementID($0) },
                direction: activePlan.scrollDirection,
                amount: activePlan.scrollAmount
            )
            return "Scrolled \(activePlan.scrollDirection.rawValue)."
        })

        steps.append(await record(
            "set_value",
            target: activePlan.elementID(activePlan.textElementIndex),
            snapshot: latestSnapshot
        ) {
            try await computer.setValue(
                elementID: activePlan.elementID(activePlan.textElementIndex),
                value: activePlan.setValue
            )
            let state = try await computer.getAppState(includeScreenshot: false)
            latestSnapshot = state.snapshot
            if let planResolver {
                activePlan = try planResolver(state)
            }
            let value = state.snapshot.element(
                id: activePlan.elementID(activePlan.textElementIndex)
            )?.value
            guard value == activePlan.setValue else {
                let observed = value.map { "'\($0)'" } ?? "nil"
                throw AgentError.computer(
                    "set_value did not update element \(activePlan.textElementIndex); observed \(observed)."
                )
            }
            return "Set and verified element \(activePlan.textElementIndex)."
        })

        steps.append(await record(
            "type_text",
            target: activePlan.elementID(activePlan.textElementIndex),
            snapshot: latestSnapshot
        ) {
            try await computer.typeText(
                activePlan.typeText,
                into: activePlan.elementID(activePlan.textElementIndex)
            )
            return "Typed \(activePlan.typeText.count) character(s)."
        })

        steps.append(await record("press_key", snapshot: latestSnapshot) {
            try await computer.pressKey(activePlan.keyPress)
            return "Pressed \(activePlan.keyPress.key)."
        })

        steps.append(await record(
            "drag",
            target: activePlan.elementID(activePlan.dragFromElementIndex),
            snapshot: latestSnapshot
        ) {
            try await computer.drag(
                fromElementID: activePlan.elementID(activePlan.dragFromElementIndex),
                toElementID: activePlan.elementID(activePlan.dragToElementIndex)
            )
            return "Dragged \(activePlan.dragFromElementIndex) to \(activePlan.dragToElementIndex)."
        })

        steps.append(await record(
            "perform_secondary_action",
            target: activePlan.elementID(activePlan.secondaryElementIndex),
            snapshot: latestSnapshot
        ) {
            try await computer.performSecondaryAction(
                elementID: activePlan.elementID(activePlan.secondaryElementIndex),
                action: activePlan.secondaryAction
            )
            return "Performed \(activePlan.secondaryAction)."
        })

        return ComputerUseSmokeReport(appName: computer.appName, steps: steps)
    }

    private func record(
        _ toolName: String,
        target: String? = nil,
        snapshot: UITreeSnapshot? = nil,
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
                detail: failureDetail(describe(error), target: target, snapshot: snapshot)
            )
        }
    }

    /// Append the targeted element's id, role, and label (when resolvable) to a
    /// failure message, so a smoke failure on a real app is self-explanatory
    /// rather than a bare AX error.
    private func failureDetail(
        _ message: String,
        target: String?,
        snapshot: UITreeSnapshot?
    ) -> String {
        guard let target else { return message }
        guard let element = snapshot?.element(id: target) else {
            return "\(message) [target \(target)]"
        }
        var parts = [element.id, element.role]
        if let label = element.label, !label.isEmpty {
            parts.append("\"\(label)\"")
        }
        return "\(message) [target \(parts.joined(separator: " "))]"
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

public extension ComputerUseSmokeRunner {
    /// Verify the accessibility reader still captures the control state the agent
    /// relies on: a checkbox's numeric `AXValue` (which a string-only cast would
    /// drop) and an icon-only button's label (which lives in `AXDescription`
    /// when `AXTitle` is empty). Returns one step per identifier supplied; an
    /// absent identifier is skipped. Pure and snapshot-only, so it runs in CI
    /// without Accessibility permission and on a real Mac via the fixture.
    static func perceptionVerificationSteps(
        snapshot: UITreeSnapshot,
        identifiers: ComputerUseSmokeFixtureIdentifiers
    ) -> [ComputerUseSmokeStepResult] {
        var results: [ComputerUseSmokeStepResult] = []
        if let checkboxIdentifier = identifiers.checkboxIdentifier {
            results.append(verifyNumericValue(
                snapshot: snapshot,
                identifier: checkboxIdentifier
            ))
        }
        if let iconButtonIdentifier = identifiers.iconButtonIdentifier {
            results.append(verifyDescriptionLabel(
                snapshot: snapshot,
                identifier: iconButtonIdentifier
            ))
        }
        return results
    }

    private static func verifyNumericValue(
        snapshot: UITreeSnapshot,
        identifier: String
    ) -> ComputerUseSmokeStepResult {
        let tool = "verify_checkbox_value"
        guard let element = element(in: snapshot, identifier: identifier) else {
            return ComputerUseSmokeStepResult(
                toolName: tool,
                status: .failed,
                detail: "No element with identifier \(identifier)."
            )
        }
        guard let value = element.value, !value.isEmpty else {
            return ComputerUseSmokeStepResult(
                toolName: tool,
                status: .failed,
                detail: "\(element.id) (\(element.role)) has no captured value — a "
                    + "numeric AXValue was dropped."
            )
        }
        return ComputerUseSmokeStepResult(
            toolName: tool,
            status: .passed,
            detail: "Captured numeric value \"\(value)\" on \(element.id)."
        )
    }

    private static func verifyDescriptionLabel(
        snapshot: UITreeSnapshot,
        identifier: String
    ) -> ComputerUseSmokeStepResult {
        let tool = "verify_icon_button_label"
        guard let element = element(in: snapshot, identifier: identifier) else {
            return ComputerUseSmokeStepResult(
                toolName: tool,
                status: .failed,
                detail: "No element with identifier \(identifier)."
            )
        }
        guard let label = element.label, !label.isEmpty else {
            return ComputerUseSmokeStepResult(
                toolName: tool,
                status: .failed,
                detail: "\(element.id) (\(element.role)) has no label — an empty "
                    + "AXTitle did not fall back to AXDescription."
            )
        }
        return ComputerUseSmokeStepResult(
            toolName: tool,
            status: .passed,
            detail: "Resolved label \"\(label)\" on \(element.id)."
        )
    }

    private static func element(
        in snapshot: UITreeSnapshot,
        identifier: String
    ) -> UIElement? {
        snapshot.root.flattened.first { $0.identifier == identifier }
    }
}
