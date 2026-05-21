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

struct AppLocatorMatchTests {
    private let apps = [
        AppLocator.RunningApp(name: "Safari", bundleIdentifier: "com.apple.Safari", processID: 1),
        AppLocator.RunningApp(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            processID: 2
        ),
        AppLocator.RunningApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processID: 3)
    ]

    @Test func exactNameMatchWins() {
        #expect(AppLocator.match("Safari", in: apps)?.processID == 1)
    }

    @Test func matchIsCaseInsensitive() {
        #expect(AppLocator.match("safari", in: apps)?.processID == 1)
    }

    @Test func substringMatchesAppName() {
        // "@chrome" should resolve to "Google Chrome".
        #expect(AppLocator.match("chrome", in: apps)?.processID == 2)
    }

    @Test func substringMatchesBundleIdentifier() {
        #expect(AppLocator.match("google", in: apps)?.processID == 2)
    }

    @Test func ambiguousSubstringMatchesNothing() {
        let apps = [
            AppLocator.RunningApp(
                name: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                processID: 2
            ),
            AppLocator.RunningApp(
                name: "Chrome Canary",
                bundleIdentifier: "com.google.Chrome.canary",
                processID: 4
            )
        ]
        #expect(AppLocator.match("chrome", in: apps) == nil)
    }

    @Test func resolveReportsAmbiguousMatches() {
        let apps = [
            AppLocator.RunningApp(
                name: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                processID: 2
            ),
            AppLocator.RunningApp(
                name: "Chrome Canary",
                bundleIdentifier: "com.google.Chrome.canary",
                processID: 4
            )
        ]
        guard case .ambiguous(let matches) = AppLocator.resolve("chrome", in: apps) else {
            Issue.record("expected ambiguous app resolution")
            return
        }
        #expect(matches.map(\.processID).sorted() == [2, 4])
    }

    @Test func resolveReportsNotFound() {
        #expect(AppLocator.resolve("Xcode", in: apps) == .notFound)
    }

    @Test func exactBundleIdentifierWinsBeforeFuzzyAmbiguity() {
        let apps = [
            AppLocator.RunningApp(
                name: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                processID: 2
            ),
            AppLocator.RunningApp(
                name: "Chrome Canary",
                bundleIdentifier: "com.google.Chrome.canary",
                processID: 4
            )
        ]
        #expect(AppLocator.match("com.google.Chrome", in: apps)?.processID == 2)
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(AppLocator.match("", in: apps) == nil)
        #expect(AppLocator.match("   ", in: apps) == nil)
    }

    @Test func unknownQueryMatchesNothing() {
        #expect(AppLocator.match("Xcode", in: apps) == nil)
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
