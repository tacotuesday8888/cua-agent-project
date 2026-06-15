import CryptoKit
import Foundation
import Network
import Security

/// Subscription account providers that use OAuth credentials instead of API
/// keys. The shape follows the same product pattern as Pi: the user signs in to
/// an existing paid account, the app stores refreshable OAuth credentials, and
/// provider calls use the resulting access token.
public enum SubscriptionOAuthProviderID: String, Sendable, Codable, CaseIterable {
    case chatGPTCodex = "openai-codex"
    case anthropic = "anthropic"

    public var displayName: String {
        switch self {
        case .chatGPTCodex:
            "ChatGPT Plus/Pro"
        case .anthropic:
            "Claude Pro/Max"
        }
    }

    public var keychainAccount: String {
        switch self {
        case .chatGPTCodex:
            "AutopilotSubscriptionOAuth.openai-codex"
        case .anthropic:
            "AutopilotSubscriptionOAuth.anthropic"
        }
    }

    public var configuration: SubscriptionOAuthConfiguration {
        switch self {
        case .chatGPTCodex:
            SubscriptionOAuthConfiguration(
                provider: self,
                clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
                authorizeURL: URL(string: "https://auth.openai.com/oauth/authorize")!,
                tokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
                redirectURI: "http://localhost:1455/auth/callback",
                callbackPort: 1455,
                callbackPath: "/auth/callback",
                scopes: "openid profile email offline_access",
                tokenRequestEncoding: .form,
                authorizationExtras: [
                    "id_token_add_organizations": "true",
                    "codex_cli_simplified_flow": "true",
                    "originator": "mac-autopilot"
                ],
                refreshExpirySkewSeconds: 0
            )
        case .anthropic:
            SubscriptionOAuthConfiguration(
                provider: self,
                clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                authorizeURL: URL(string: "https://claude.ai/oauth/authorize")!,
                tokenURL: URL(string: "https://platform.claude.com/v1/oauth/token")!,
                redirectURI: "http://localhost:53692/callback",
                callbackPort: 53692,
                callbackPath: "/callback",
                scopes: "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
                tokenRequestEncoding: .json,
                authorizationExtras: ["code": "true"],
                refreshExpirySkewSeconds: 300
            )
        }
    }
}

public struct SubscriptionOAuthConfiguration: Sendable, Equatable {
    public enum TokenRequestEncoding: Sendable, Equatable {
        case form
        case json
    }

    public let provider: SubscriptionOAuthProviderID
    public let clientID: String
    public let authorizeURL: URL
    public let tokenURL: URL
    public let redirectURI: String
    public let callbackPort: UInt16
    public let callbackPath: String
    public let scopes: String
    public let tokenRequestEncoding: TokenRequestEncoding
    public let authorizationExtras: [String: String]
    public let refreshExpirySkewSeconds: TimeInterval

    public func authorizationURL(codeChallenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        queryItems.append(contentsOf: authorizationExtras
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = queryItems
        return components.url!
    }
}

public struct SubscriptionOAuthCredential: Codable, Sendable, Equatable {
    public let provider: SubscriptionOAuthProviderID
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var accountID: String?

    public init(
        provider: SubscriptionOAuthProviderID,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        accountID: String? = nil
    ) {
        self.provider = provider
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
    }

    public var isExpired: Bool {
        expiresAt <= Date()
    }
}

public enum SubscriptionOAuthCredentialProvider {
    public typealias Load =
        @Sendable (SubscriptionOAuthProviderID) async throws -> SubscriptionOAuthCredential?

    public static func keychain(
        store: SubscriptionOAuthCredentialStore = SubscriptionOAuthCredentialStore(),
        tokenClient: SubscriptionOAuthTokenClient = SubscriptionOAuthTokenClient()
    ) -> Load {
        { provider in
            guard let credential = try store.load(provider: provider) else {
                return nil
            }
            guard credential.isExpired else {
                return credential
            }
            let refreshed = try await tokenClient.refresh(credential)
            try store.save(refreshed)
            return refreshed
        }
    }
}

public struct SubscriptionOAuthBrowserSignIn: Sendable {
    public typealias URLOpener = @Sendable (URL) async throws -> Void

    private let tokenClient: SubscriptionOAuthTokenClient
    private let openURL: URLOpener
    private let timeoutSeconds: TimeInterval

    public init(
        tokenClient: SubscriptionOAuthTokenClient = SubscriptionOAuthTokenClient(),
        timeoutSeconds: TimeInterval = 300,
        openURL: @escaping URLOpener
    ) {
        self.tokenClient = tokenClient
        self.timeoutSeconds = max(10, timeoutSeconds)
        self.openURL = openURL
    }

    public func signIn(provider: SubscriptionOAuthProviderID) async throws -> SubscriptionOAuthCredential {
        let config = provider.configuration
        let codeVerifier = SubscriptionOAuthPKCE.codeVerifier()
        let state = provider == .anthropic ? codeVerifier : UUID().uuidString
        let server = try SubscriptionOAuthCallbackServer(config: config, expectedState: state)

        async let callback = server.waitForCallback(timeoutSeconds: timeoutSeconds)
        try await openURL(config.authorizationURL(
            codeChallenge: SubscriptionOAuthPKCE.codeChallenge(for: codeVerifier),
            state: state
        ))
        let result = try await callback
        return try await tokenClient.exchangeAuthorizationCode(
            provider: provider,
            code: result.code,
            state: state,
            codeVerifier: codeVerifier
        )
    }
}

public enum SubscriptionOAuthPKCE {
    public static func codeVerifier(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: max(32, byteCount))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64URLEncodedString()
    }

    public static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

public struct SubscriptionOAuthCredentialStore: Sendable {
    private let service: String

    public init(service: String = "com.langqi.MacAutopilot.subscription-oauth") {
        self.service = service
    }

    public func load(provider: SubscriptionOAuthProviderID) throws -> SubscriptionOAuthCredential? {
        var query = baseQuery(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SubscriptionOAuthKeychainError(status: status)
        }
        return try JSONDecoder().decode(SubscriptionOAuthCredential.self, from: data)
    }

    public func save(_ credential: SubscriptionOAuthCredential) throws {
        let data = try JSONEncoder().encode(credential)
        var query = baseQuery(provider: credential.provider)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SubscriptionOAuthKeychainError(status: updateStatus)
        }

        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SubscriptionOAuthKeychainError(status: addStatus)
        }
    }

    public func delete(provider: SubscriptionOAuthProviderID) throws {
        let status = SecItemDelete(baseQuery(provider: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SubscriptionOAuthKeychainError(status: status)
        }
    }

    private func baseQuery(provider: SubscriptionOAuthProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainAccount
        ]
    }
}

public struct SubscriptionOAuthTokenResponse: Decodable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

public struct SubscriptionOAuthTokenClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport

    public init(transport: @escaping Transport = Self.urlSessionTransport) {
        self.transport = transport
    }

    public func refresh(_ credential: SubscriptionOAuthCredential) async throws -> SubscriptionOAuthCredential {
        let config = credential.provider.configuration
        let response = try await requestToken(
            config: config,
            parameters: [
                "grant_type": "refresh_token",
                "client_id": config.clientID,
                "refresh_token": credential.refreshToken
            ]
        )
        return Self.credential(
            provider: credential.provider,
            response: response,
            skew: config.refreshExpirySkewSeconds
        )
    }

    public func exchangeAuthorizationCode(
        provider: SubscriptionOAuthProviderID,
        code: String,
        state: String,
        codeVerifier: String
    ) async throws -> SubscriptionOAuthCredential {
        let config = provider.configuration
        var parameters = [
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "code": code,
            "redirect_uri": config.redirectURI,
            "code_verifier": codeVerifier
        ]
        if provider == .anthropic {
            parameters["state"] = state
        }
        let response = try await requestToken(config: config, parameters: parameters)
        return Self.credential(provider: provider, response: response, skew: config.refreshExpirySkewSeconds)
    }

    private func requestToken(
        config: SubscriptionOAuthConfiguration,
        parameters: [String: String]
    ) async throws -> SubscriptionOAuthTokenResponse {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch config.tokenRequestEncoding {
        case .form:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(parameters)
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(parameters)
        }

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? response.description
            throw LLMError.service(message: "\(config.provider.displayName) OAuth failed: \(body)")
        }
        return try JSONDecoder().decode(SubscriptionOAuthTokenResponse.self, from: data)
    }

    private static func credential(
        provider: SubscriptionOAuthProviderID,
        response: SubscriptionOAuthTokenResponse,
        skew: TimeInterval
    ) -> SubscriptionOAuthCredential {
        SubscriptionOAuthCredential(
            provider: provider,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date().addingTimeInterval(max(0, response.expiresIn - skew)),
            accountID: provider == .chatGPTCodex ? chatGPTAccountID(from: response.accessToken) : nil
        )
    }

    private func formBody(_ parameters: [String: String]) -> Data {
        let body = parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(escape(key))=\(escape(value))"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public static func urlSessionTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("OAuth token endpoint returned a non-HTTP response")
        }
        return (data, http)
    }

    private static func chatGPTAccountID(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard
            let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let auth = json["https://api.openai.com/auth"] as? [String: Any],
            let accountID = auth["chatgpt_account_id"] as? String,
            !accountID.isEmpty
        else {
            return nil
        }
        return accountID
    }
}

private struct SubscriptionOAuthCallback: Sendable {
    let code: String
}

private final class SubscriptionOAuthCallbackServer: @unchecked Sendable {
    private let config: SubscriptionOAuthConfiguration
    private let expectedState: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MacAutopilot.SubscriptionOAuthCallback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SubscriptionOAuthCallback, Error>?
    private var pendingResult: Result<SubscriptionOAuthCallback, Error>?

    init(config: SubscriptionOAuthConfiguration, expectedState: String) throws {
        self.config = config
        self.expectedState = expectedState
        guard let port = NWEndpoint.Port(rawValue: config.callbackPort) else {
            throw SubscriptionOAuthBrowserError.invalidCallbackPort
        }
        listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    func waitForCallback(timeoutSeconds: TimeInterval) async throws -> SubscriptionOAuthCallback {
        defer { listener.cancel() }
        return try await withThrowingTaskGroup(of: SubscriptionOAuthCallback.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.register(continuation)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw SubscriptionOAuthBrowserError.callbackTimedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func register(_ continuation: CheckedContinuation<SubscriptionOAuthCallback, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func complete(_ result: Result<SubscriptionOAuthCallback, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        pendingResult = result
        lock.unlock()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }
            let result: Result<SubscriptionOAuthCallback, Error>
            if let error {
                result = .failure(error)
            } else if let data, let request = String(data: data, encoding: .utf8) {
                result = self.parse(request)
            } else {
                result = .failure(SubscriptionOAuthBrowserError.invalidCallbackRequest)
            }

            self.respond(on: connection, success: result.isSuccess)
            self.complete(result)
        }
    }

    private func parse(_ request: String) -> Result<SubscriptionOAuthCallback, Error> {
        guard
            let requestLine = request.components(separatedBy: "\r\n").first,
            let target = requestLine.split(separator: " ").dropFirst().first,
            let components = URLComponents(string: "http://localhost\(target)")
        else {
            return .failure(SubscriptionOAuthBrowserError.invalidCallbackRequest)
        }
        guard components.path == config.callbackPath else {
            return .failure(SubscriptionOAuthBrowserError.invalidCallbackPath)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        if let error = query["error"], !error.isEmpty {
            return .failure(SubscriptionOAuthBrowserError.providerError(error))
        }
        guard query["state"] == expectedState else {
            return .failure(SubscriptionOAuthBrowserError.stateMismatch)
        }
        guard let code = query["code"], !code.isEmpty else {
            return .failure(SubscriptionOAuthBrowserError.missingAuthorizationCode)
        }
        return .success(SubscriptionOAuthCallback(code: code))
    }

    private func respond(on connection: NWConnection, success: Bool) {
        let body = success
            ? "<html><body>Mac Autopilot sign-in is complete. You can close this window.</body></html>"
            : "<html><body>Mac Autopilot sign-in failed. Return to the app and try again.</body></html>"
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(Data(body.utf8).count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private enum SubscriptionOAuthBrowserError: LocalizedError {
    case invalidCallbackPort
    case callbackTimedOut
    case invalidCallbackRequest
    case invalidCallbackPath
    case stateMismatch
    case missingAuthorizationCode
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .invalidCallbackPort:
            "The OAuth callback port is invalid."
        case .callbackTimedOut:
            "The sign-in browser callback timed out."
        case .invalidCallbackRequest:
            "The sign-in callback was not a valid HTTP request."
        case .invalidCallbackPath:
            "The sign-in callback used the wrong path."
        case .stateMismatch:
            "The sign-in callback state did not match."
        case .missingAuthorizationCode:
            "The sign-in callback did not include an authorization code."
        case .providerError(let message):
            "The provider rejected sign-in: \(message)"
        }
    }
}

private struct SubscriptionOAuthKeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Subscription OAuth Keychain error \(status)"
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
