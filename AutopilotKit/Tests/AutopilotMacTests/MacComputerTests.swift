import AutopilotAgent
import Foundation
import Testing
@testable import AutopilotMac

struct MacComputerTests {
    private func environment(
        process: TargetProcessState? = TargetProcessState(isTerminated: false, isHidden: false),
        accessibilityTrusted: Bool = true,
        screenRecordingTrusted: Bool = true,
        activate: @escaping @Sendable (pid_t) async -> ActivationResult
            = { _ in ActivationResult(appFound: true, wasHidden: false) }
    ) -> MacComputerEnvironment {
        MacComputerEnvironment(
            targetProcess: { _ in process },
            isAccessibilityTrusted: { accessibilityTrusted },
            isScreenRecordingTrusted: { screenRecordingTrusted },
            activateTarget: activate
        )
    }

    @Test func diagnoseReportsMissingTargetApp() async {
        let computer = MacComputer(
            pid: 999_999,
            appName: "Ghost",
            environment: environment(process: nil)
        )

        let diagnostics = await computer.diagnose()
        #expect(!diagnostics.isReady)
        #expect(diagnostics.failures.contains { $0.id == "target-app" })
    }

    @Test func prepareActivatesTheTargetApp() async {
        let recorder = ActivationRecorder()
        let computer = MacComputer(
            pid: 4242,
            appName: "TextEdit",
            environment: environment(activate: { pid in
                await recorder.record(pid)
                return ActivationResult(appFound: true, wasHidden: false)
            })
        )

        let summary = await computer.prepare()
        #expect(await recorder.activatedPIDs == [4242])
        #expect(summary == "Activated TextEdit.")
    }

    @Test func prepareReportsUnhideWhenTheAppWasHidden() async {
        let computer = MacComputer(
            pid: 7,
            appName: "TextEdit",
            environment: environment(activate: { _ in
                ActivationResult(appFound: true, wasHidden: true)
            })
        )

        #expect(await computer.prepare() == "Unhid and activated TextEdit.")
    }

    @Test func prepareReportsWhenTheAppIsNotRunning() async {
        let computer = MacComputer(
            pid: 7,
            appName: "TextEdit",
            environment: environment(activate: { _ in
                ActivationResult(appFound: false, wasHidden: false)
            })
        )

        #expect(await computer.prepare().contains("not running"))
    }
}

/// Records which pids `MacComputerEnvironment.activateTarget` was asked to
/// bring forward, for activation tests.
private actor ActivationRecorder {
    private(set) var activatedPIDs: [pid_t] = []

    func record(_ pid: pid_t) {
        activatedPIDs.append(pid)
    }
}
