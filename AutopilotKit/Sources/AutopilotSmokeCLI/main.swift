import AutopilotAgent
import AutopilotCore
import AutopilotMac
import Darwin
import Foundation

@main
struct AutopilotSmokeCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.contains("--help"), !arguments.contains("-h") else {
            printUsage()
            return
        }

        let target = value(after: "--app", in: arguments) ?? "AutopilotFixtureApp"
        let app = await MainActor.run {
            AppLocator().runningApp(matching: target)
        }

        guard let app else {
            fputs("No running app matched '\(target)'.\n\n", stderr)
            printUsage()
            exit(2)
        }

        let computer = MacComputer(
            pid: app.processID,
            appName: app.name,
            bundleIdentifier: app.bundleIdentifier
        )

        let diagnostics = await computer.diagnose()
        printDiagnostics(diagnostics)
        guard diagnostics.isReady else {
            exit(2)
        }

        let report = await ComputerUseSmokeRunner().run(
            computer: computer,
            planForState: { state in
                try ComputerUseSmokePlan.autopilotFixturePlan(
                    for: state.snapshot
                )
            }
        )

        print("")
        print(report.summary)
        for step in report.steps {
            print("- \(step.status.rawValue): \(step.toolName) - \(step.detail)")
        }

        exit(report.passed ? 0 : 1)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }

    private static func printDiagnostics(_ diagnostics: ComputerDiagnostics) {
        print(diagnostics.summary)
        for check in diagnostics.checks {
            var line = "- \(check.status.rawValue): \(check.title) - \(check.detail)"
            if let recovery = check.recovery, !recovery.isEmpty {
                line += " \(recovery)"
            }
            print(line)
        }
    }

    private static func printUsage() {
        print("""
        Usage:
          swift run --package-path AutopilotKit AutopilotFixtureApp
          swift run --package-path AutopilotKit AutopilotSmokeCLI [--app AutopilotFixtureApp]

        The fixture app must be running and the smoke runner process must have
        Accessibility permission in System Settings > Privacy & Security.
        """)
    }

}
