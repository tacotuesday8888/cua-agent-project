import AppKit
import AutopilotUI
import SwiftUI

@main
struct MacAutopilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            ContentView()
        }

        MenuBarExtra("Mac Autopilot", systemImage: "sparkles") {
            Button("Show Assistant") {
                appDelegate.showAssistant()
            }

            SettingsLink {
                Text("Debug Harness")
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notchController = NotchController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notchController.start()
    }

    func showAssistant() {
        notchController.show(expanded: true)
    }
}
