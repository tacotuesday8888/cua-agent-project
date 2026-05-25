import AppKit
import AutopilotUI
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import SwiftUI

@main
struct MacAutopilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Configure Firebase before any view or the app delegate touches Auth —
        // `Auth.auth()` hard-crashes if the default app isn't configured yet.
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

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
    private var notchController: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // The notch agent uses the signed-in account's token for hosted AI.
        // Firebase is already configured in MacAutopilotApp.init().
        let model = AgentViewModel()
        model.hostedTokenProvider = hostedFirebaseToken
        let controller = NotchController(model: model)
        notchController = controller
        controller.start()
    }

    func showAssistant() {
        notchController?.show(expanded: true)
    }
}

/// The hosted-AI token source: the signed-in Firebase user's ID token, or `nil`
/// when nobody is signed in. Shared by the notch and the test-harness window;
/// safe to call only after `FirebaseApp.configure()`.
@Sendable
func hostedFirebaseToken() async throws -> String? {
    guard FirebaseApp.app() != nil else { return nil }
    return try await Auth.auth().currentUser?.getIDToken()
}

/// Google Sign-In state for the hosted-AI account, bridged to Firebase Auth.
/// Lives in the app target so the on-device engine stays free of the Firebase
/// SDK; it only ever hands the engine a short-lived ID token.
@MainActor
@Observable
final class AuthModel {
    /// The signed-in account's email, or `nil` when signed out.
    private(set) var email: String?
    /// A user-facing message from the last sign-in/out attempt, if any.
    private(set) var statusMessage: String?

    var isSignedIn: Bool { email != nil }

    /// Reflect the persisted Firebase session into the UI. Call after launch,
    /// once `FirebaseApp.configure()` has run.
    func refresh() {
        guard FirebaseApp.app() != nil else { return }
        email = Auth.auth().currentUser?.email
    }

    /// Run the Google sign-in flow, exchange the Google credential for a
    /// Firebase session, and record the signed-in email.
    func signIn(presenting window: NSWindow) async {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            statusMessage = "Firebase is not configured."
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
            guard let idToken = result.user.idToken?.tokenString else {
                statusMessage = "Google did not return an ID token."
                return
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            let authResult = try await Auth.auth().signIn(with: credential)
            email = authResult.user.email
            statusMessage = nil
        } catch {
            statusMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    /// Sign out of both Firebase and Google.
    func signOut() {
        guard FirebaseApp.app() != nil else { return }
        do {
            try Auth.auth().signOut()
        } catch {
            statusMessage = "Sign-out failed: \(error.localizedDescription)"
        }
        GIDSignIn.sharedInstance.signOut()
        email = nil
    }
}
