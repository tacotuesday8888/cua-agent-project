import AppKit
import AutopilotLLM
import Foundation
import Observation

/// Sign-in state for existing paid AI accounts connected through app-owned
/// OAuth. Tokens are stored in Keychain by `SubscriptionOAuthCredentialStore`.
@MainActor
@Observable
public final class SubscriptionAccountAuthModel {
    public struct AccountState: Sendable, Equatable {
        public var isSignedIn: Bool
        public var isBusy: Bool
        public var statusMessage: String?

        public init(isSignedIn: Bool = false, isBusy: Bool = false, statusMessage: String? = nil) {
            self.isSignedIn = isSignedIn
            self.isBusy = isBusy
            self.statusMessage = statusMessage
        }
    }

    public typealias SignInRunner =
        @Sendable (SubscriptionOAuthProviderID) async throws -> SubscriptionOAuthCredential

    public private(set) var states: [SubscriptionOAuthProviderID: AccountState] = [:]

    @ObservationIgnored
    private let store: SubscriptionOAuthCredentialStore
    @ObservationIgnored
    private let tokenClient: SubscriptionOAuthTokenClient
    @ObservationIgnored
    private let signInRunner: SignInRunner

    public convenience init() {
        let tokenClient = SubscriptionOAuthTokenClient()
        self.init(
            store: SubscriptionOAuthCredentialStore(),
            tokenClient: tokenClient,
            signInRunner: { provider in
                let flow = SubscriptionOAuthBrowserSignIn(tokenClient: tokenClient) { url in
                    try await MainActor.run {
                        guard NSWorkspace.shared.open(url) else {
                            throw SubscriptionAccountAuthError.couldNotOpenBrowser
                        }
                    }
                }
                return try await flow.signIn(provider: provider)
            }
        )
    }

    init(
        store: SubscriptionOAuthCredentialStore,
        tokenClient: SubscriptionOAuthTokenClient,
        signInRunner: @escaping SignInRunner
    ) {
        self.store = store
        self.tokenClient = tokenClient
        self.signInRunner = signInRunner
    }

    public func state(for provider: SubscriptionOAuthProviderID) -> AccountState {
        states[provider] ?? AccountState()
    }

    public func knownState(for provider: SubscriptionOAuthProviderID) -> AccountState? {
        states[provider]
    }

    public func refresh(provider: SubscriptionOAuthProviderID) async {
        update(provider) { $0.isBusy = true }
        defer { update(provider) { $0.isBusy = false } }

        do {
            guard var credential = try store.load(provider: provider) else {
                update(provider) {
                    $0.isSignedIn = false
                    $0.statusMessage = nil
                }
                return
            }
            if credential.isExpired {
                credential = try await tokenClient.refresh(credential)
                try store.save(credential)
            }
            update(provider) {
                $0.isSignedIn = true
                $0.statusMessage = credential.accountID.map { "Signed in as \($0)" }
            }
        } catch {
            update(provider) {
                $0.isSignedIn = false
                $0.statusMessage = "Could not check \(provider.displayName): \(error.localizedDescription)"
            }
        }
    }

    public func signIn(provider: SubscriptionOAuthProviderID) async {
        update(provider) {
            $0.isBusy = true
            $0.statusMessage = nil
        }
        defer { update(provider) { $0.isBusy = false } }

        do {
            let credential = try await signInRunner(provider)
            try store.save(credential)
            update(provider) {
                $0.isSignedIn = true
                $0.statusMessage = credential.accountID.map { "Signed in as \($0)" }
            }
        } catch {
            update(provider) {
                $0.isSignedIn = false
                $0.statusMessage = "\(provider.displayName) sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    public func signOut(provider: SubscriptionOAuthProviderID) async {
        update(provider) { $0.isBusy = true }
        defer { update(provider) { $0.isBusy = false } }

        do {
            try store.delete(provider: provider)
            update(provider) {
                $0.isSignedIn = false
                $0.statusMessage = nil
            }
        } catch {
            update(provider) {
                $0.statusMessage = "\(provider.displayName) sign-out failed: \(error.localizedDescription)"
            }
        }
    }

    private func update(
        _ provider: SubscriptionOAuthProviderID,
        _ mutate: (inout AccountState) -> Void
    ) {
        var state = states[provider] ?? AccountState()
        mutate(&state)
        states[provider] = state
    }
}

private enum SubscriptionAccountAuthError: LocalizedError {
    case couldNotOpenBrowser

    var errorDescription: String? {
        switch self {
        case .couldNotOpenBrowser:
            "Could not open the sign-in page in the browser."
        }
    }
}
