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
        let accessibility = check("accessibility", in: checks)
        #expect(accessibility?.status == .failed)
        // The recovery must cover the stale-grant case: a grant from an earlier
        // ad-hoc build still shows ON in System Settings but no longer matches the
        // current cdhash, so the fix is reset + re-grant, not a plain re-grant.
        #expect(accessibility?.recovery?.contains("tccutil reset Accessibility com.langqi.MacAutopilot") == true)
        #expect(accessibility?.recovery?.contains("--launch-only") == true)
    }

    @Test func missingScreenRecordingIsWarningNotFailure() {
        let checks = MacDriverDiagnostics.checks(for: inputs(screenRecordingTrusted: false))
        let screenRecording = check("screen-recording", in: checks)
        #expect(screenRecording?.status == .warning)
        #expect(screenRecording?.recovery?.contains("tccutil reset ScreenCapture com.langqi.MacAutopilot") == true)
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
        let windowMatch = check("window-match", in: checks)
        #expect(windowMatch?.status == .warning)
        #expect(windowMatch?.recovery?.contains("screenshot fallback is disabled") == true)
        #expect(ComputerDiagnostics(appName: "TextEdit", checks: checks).isReady)
    }

    @Test func failedWindowProbeFails() {
        let checks = MacDriverDiagnostics.checks(for: inputs(window: .failed("boom")))
        let tree = check("accessibility-tree", in: checks)
        #expect(tree?.status == .failed)
        #expect(tree?.detail.contains("boom") == true)
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
