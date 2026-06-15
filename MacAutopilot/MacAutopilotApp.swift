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
        WindowGroup("Mac Autopilot", id: "control-center") {
            ContentView()
        }
        .defaultSize(width: 920, height: 640)

        MenuBarExtra("Mac Autopilot", systemImage: "sparkles") {
            MenuBarControls(appDelegate: appDelegate)
        }
    }
}

private struct MenuBarControls: View {
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AppDelegate

    var body: some View {
        Button("Open Control Center") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "control-center")
        }

        Button("Show Compact Assistant") {
            appDelegate.showAssistant()
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchController?
    private let auth = AuthModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // The compact assistant uses the signed-in account's token for hosted AI.
        // Firebase is already configured in MacAutopilotApp.init().
        let model = AgentViewModel()
        model.hostedTokenProvider = hostedFirebaseToken
        auth.refresh()
        model.hostedAccountStatusProvider = { [auth] in
            AgentViewModel.HostedAccountStatus(
                email: auth.email,
                statusMessage: auth.statusMessage
            )
        }
        model.hostedSignInHandler = { [auth] in
            guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
            await auth.signIn(presenting: window)
        }
        model.hostedSignOutHandler = { [auth] in
            auth.signOut()
        }
        let controller = NotchController(model: model)
        notchController = controller
        controller.start()
    }

    func showAssistant() {
        notchController?.show(expanded: true)
    }
}

/// The hosted-AI token source: the signed-in Firebase user's ID token, or `nil`
/// when nobody is signed in. Shared by the compact assistant and Control Center;
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

    /// The Sendable bits we pull out of a Google sign-in result.
    private struct GoogleTokens: Sendable {
        let idToken: String
        let accessToken: String
    }

    private enum SignInError: LocalizedError {
        case noIDToken
        var errorDescription: String? {
            switch self {
            case .noIDToken: "Google did not return an ID token."
            }
        }
    }

    /// Run the Google sign-in flow, exchange the Google credential for a
    /// Firebase session, and record the signed-in email.
    ///
    /// Both vendor calls use completion handlers wrapped in continuations so we
    /// extract only the Sendable token/email strings inside each callback — the
    /// non-Sendable `GIDSignInResult`/`AuthDataResult` never cross actor
    /// isolation, which strict Swift concurrency would otherwise reject.
    func signIn(presenting window: NSWindow) async {
        guard FirebaseApp.app() != nil else {
            statusMessage = "Firebase isn't configured — GoogleService-Info.plist is "
                + "missing from the app bundle (do a clean build)."
            return
        }
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            statusMessage = "Google sign-in isn't set up — GoogleService-Info.plist has no "
                + "CLIENT_ID. Re-download it from Firebase."
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        do {
            let tokens: GoogleTokens = try await withCheckedThrowingContinuation { continuation in
                GIDSignIn.sharedInstance.signIn(withPresenting: window) { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let user = result?.user, let idToken = user.idToken?.tokenString {
                        continuation.resume(
                            returning: GoogleTokens(
                                idToken: idToken,
                                accessToken: user.accessToken.tokenString
                            )
                        )
                    } else {
                        continuation.resume(throwing: SignInError.noIDToken)
                    }
                }
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: tokens.idToken,
                accessToken: tokens.accessToken
            )
            let signedInEmail: String? = try await withCheckedThrowingContinuation { continuation in
                Auth.auth().signIn(with: credential) { authResult, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: authResult?.user.email)
                    }
                }
            }
            email = signedInEmail
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
