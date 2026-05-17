import AutopilotAgent
import Foundation
import Testing
@testable import AutopilotMac

struct MacComputerTests {
    @Test func diagnoseReportsMissingTargetApp() async {
        let environment = MacComputerEnvironment(
            targetProcess: { _ in nil },
            isAccessibilityTrusted: { true },
            isScreenRecordingTrusted: { true }
        )
        let computer = MacComputer(pid: 999_999, appName: "Ghost", environment: environment)

        let diagnostics = await computer.diagnose()
        #expect(!diagnostics.isReady)
        #expect(diagnostics.failures.contains { $0.id == "target-app" })
    }

    @Test func prepareActivatesTheTargetApp() async {
        let recorder = ActivationRecorder()
        let environment = MacComputerEnvironment(
            targetProcess: { _ in TargetProcessState(isTerminated: false, isHidden: false) },
            isAccessibilityTrusted: { true },
            isScreenRecordingTrusted: { true },
            activateTarget: { pid in await recorder.record(pid) }
        )
        let computer = MacComputer(pid: 4242, appName: "TextEdit", environment: environment)

        await computer.prepare()
        #expect(await recorder.activatedPIDs == [4242])
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
