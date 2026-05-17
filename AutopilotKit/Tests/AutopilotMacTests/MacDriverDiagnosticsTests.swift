import AutopilotAgent
import Testing
@testable import AutopilotMac

struct MacDriverDiagnosticsTests {
    private func inputs(
        process: TargetProcessState? = TargetProcessState(isTerminated: false, isHidden: false),
        accessibilityTrusted: Bool = true,
        screenRecordingTrusted: Bool = true,
        window: MacDriverDiagnostics.WindowProbe? = .readable(elementCount: 12, windowMatched: true)
    ) -> MacDriverDiagnostics.Inputs {
        MacDriverDiagnostics.Inputs(
            appName: "TextEdit",
            process: process,
            accessibilityTrusted: accessibilityTrusted,
            screenRecordingTrusted: screenRecordingTrusted,
            window: window
        )
    }

    private func check(_ id: String, in checks: [ComputerDiagnosticCheck]) -> ComputerDiagnosticCheck? {
        checks.first { $0.id == id }
    }

    @Test func readyWhenEverythingPasses() {
        let diagnostics = ComputerDiagnostics(
            appName: "TextEdit",
            checks: MacDriverDiagnostics.checks(for: inputs())
        )
        #expect(diagnostics.isReady)
        #expect(diagnostics.failures.isEmpty)
    }

    @Test func missingTargetAppFails() {
        let checks = MacDriverDiagnostics.checks(for: inputs(process: nil, window: nil))
        let targetApp = check("target-app", in: checks)
        #expect(targetApp?.status == .failed)
        #expect(targetApp?.detail.contains("is not running") == true)
    }

    @Test func terminatedTargetAppFails() {
        let checks = MacDriverDiagnostics.checks(for: inputs(
            process: TargetProcessState(isTerminated: true, isHidden: false),
            window: nil
        ))
        #expect(check("target-app", in: checks)?.status == .failed)
    }

    @Test func hiddenTargetAppFailsWithUnhideRecovery() {
        let checks = MacDriverDiagnostics.checks(for: inputs(
            process: TargetProcessState(isTerminated: false, isHidden: true),
            window: nil
        ))
        let targetApp = check("target-app", in: checks)
        #expect(targetApp?.status == .failed)
        #expect(targetApp?.detail.contains("hidden") == true)
        #expect(targetApp?.recovery?.contains("Unhide") == true)
    }

    @Test func missingAccessibilityPermissionFails() {
        let checks = MacDriverDiagnostics.checks(for: inputs(
            accessibilityTrusted: false,
            window: nil
        ))
        #expect(check("accessibility", in: checks)?.status == .failed)
    }

    @Test func missingScreenRecordingIsWarningNotFailure() {
        let checks = MacDriverDiagnostics.checks(for: inputs(screenRecordingTrusted: false))
        #expect(check("screen-recording", in: checks)?.status == .warning)
        // A warning must not block readiness.
        #expect(ComputerDiagnostics(appName: "TextEdit", checks: checks).isReady)
    }

    @Test func noWindowFails() {
        let checks = MacDriverDiagnostics.checks(for: inputs(window: .noWindow))
        let tree = check("accessibility-tree", in: checks)
        #expect(tree?.status == .failed)
        #expect(tree?.detail.contains("no window") == true)
    }

    @Test func minimizedWindowFailsWithUnminimizeRecovery() {
        let checks = MacDriverDiagnostics.checks(for: inputs(window: .minimized))
        let tree = check("accessibility-tree", in: checks)
        #expect(tree?.status == .failed)
        #expect(tree?.detail.contains("minimized") == true)
        #expect(tree?.recovery?.contains("Unminimize") == true)
    }

    @Test func unmatchedWindowIsWarningNotFailure() {
        let checks = MacDriverDiagnostics.checks(for: inputs(
            window: .readable(elementCount: 8, windowMatched: false)
        ))
        #expect(check("window-match", in: checks)?.status == .warning)
        #expect(ComputerDiagnostics(appName: "TextEdit", checks: checks).isReady)
    }

    @Test func windowProbeSkippedUntilTheAppIsReady() {
        #expect(!MacDriverDiagnostics.shouldProbeWindows(process: nil, accessibilityTrusted: true))
        #expect(!MacDriverDiagnostics.shouldProbeWindows(
            process: TargetProcessState(isTerminated: false, isHidden: true),
            accessibilityTrusted: true
        ))
        #expect(!MacDriverDiagnostics.shouldProbeWindows(
            process: TargetProcessState(isTerminated: false, isHidden: false),
            accessibilityTrusted: false
        ))
        #expect(MacDriverDiagnostics.shouldProbeWindows(
            process: TargetProcessState(isTerminated: false, isHidden: false),
            accessibilityTrusted: true
        ))
    }
}
