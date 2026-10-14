import AppKit
import CryptoKit
import Foundation
import Network
import Security

// MARK: - Models

struct OAuthClientConfig: Codable, Equatable {
    var clientID: String
    var clientSecret: String

    /// Parses the JSON file Google Cloud Console offers for "Desktop app" OAuth clients:
    /// `{"installed": {"client_id": "...", "client_secret": "...", ...}}`
    static func fromGoogleJSON(_ data: Data) throws -> OAuthClientConfig {
        struct Inner: Decodable { let client_id: String; let client_secret: String? }
        struct Outer: Decodable { let installed: Inner?; let web: Inner? }
        let outer = try JSONDecoder().decode(Outer.self, from: data)
        guard let inner = outer.installed ?? outer.web else {
            throw AuthError.message("That JSON file doesn't look like a Google OAuth client file.")
        }
        return OAuthClientConfig(clientID: inner.client_id, clientSecret: inner.client_secret ?? "")
    }
}

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
}

enum AuthError: LocalizedError {
    case message(String)
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .notSignedIn: return "You are not signed in."
        }
    }
}

// MARK: - Keychain

enum Keychain {
    static let service = "local.googletasks.mac"

    static func set(_ data: Data, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func getCodable<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let data = get(account: account) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func setCodable<T: Encodable>(_ value: T, account: String) {
        if let data = try? JSONEncoder().encode(value) { set(data, account: account) }
    }
}

// MARK: - OAuth manager

/// Google OAuth 2.0 for installed apps: browser consent + loopback redirect + PKCE.
@MainActor
final class OAuthManager {
    static let scope = "https://www.googleapis.com/auth/tasks"
    private static let clientAccount = "oauth-client"
    private static let tokensAccount = "oauth-tokens"

    private(set) var clientConfig: OAuthClientConfig?
    private var tokens: OAuthTokens?
    private var refreshTask: Task<String, Error>?

    init(loadFromKeychain: Bool = true) {
        guard loadFromKeychain else { return }
        clientConfig = Keychain.getCodable(OAuthClientConfig.self, account: Self.clientAccount)
        tokens = Keychain.getCodable(OAuthTokens.self, account: Self.tokensAccount)
    }

    var hasClientConfig: Bool { clientConfig != nil }
    var isSignedIn: Bool { tokens != nil }

    func saveClientConfig(_ config: OAuthClientConfig) {
        clientConfig = config
        Keychain.setCodable(config, account: Self.clientAccount)
    }

    func forgetClientConfig() {
        signOut()
        clientConfig = nil
        Keychain.delete(account: Self.clientAccount)
    }

    func signOut() {
        if let token = tokens?.refreshToken {
            // Best effort revoke; ignore the result.
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = formEncode(["token": token])
            networkSession.dataTask(with: req).resume()
        }
        tokens = nil
        Keychain.delete(account: Self.tokensAccount)
    }

    func signIn() async throws {
        guard let config = clientConfig else { throw AuthError.message("Missing OAuth client configuration.") }

        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = Self.randomURLSafeString(length: 24)

        let server = LoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let redirectURI = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(comps.url!)

        let params = try await server.waitForCallback(timeout: 300)
        if let error = params["error"] {
            throw AuthError.message("Google sign-in failed: \(error)")
        }
        guard params["state"] == state else { throw AuthError.message("Sign-in state mismatch. Please try again.") }
        guard let code = params["code"] else { throw AuthError.message("No authorization code was returned.") }

        let response = try await tokenRequest([
            "code": code,
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = response.refresh_token else {
            throw AuthError.message("Google did not return a refresh token. Remove the app's access at myaccount.google.com/permissions and try again.")
        }
        let newTokens = OAuthTokens(
            accessToken: response.access_token,
            refreshToken: refresh,
            expiry: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600))
        )
        tokens = newTokens
        Keychain.setCodable(newTokens, account: Self.tokensAccount)
    }

    /// Returns a valid access token, refreshing it when it's close to expiring.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw AuthError.notSignedIn }
        if !forceRefresh, current.expiry.timeIntervalSinceNow > 60 {
            return current.accessToken
        }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard let config = clientConfig, var current = tokens else { throw AuthError.notSignedIn }
        do {
            let response = try await tokenRequest([
                "client_id": config.clientID,
                "client_secret": config.clientSecret,
                "refresh_token": current.refreshToken,
                "grant_type": "refresh_token",
            ])
            current.accessToken = response.access_token
            current.expiry = Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600))
            if let r = response.refresh_token { current.refreshToken = r }
            tokens = current
            Keychain.setCodable(current, account: Self.tokensAccount)
            return current.accessToken
        } catch TokenEndpointError.invalidGrant {
            // Refresh token revoked or expired: force a fresh sign-in.
            tokens = nil
            Keychain.delete(account: Self.tokensAccount)
            throw AuthError.notSignedIn
        }
    }

    // MARK: Token endpoint

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
    }

    private enum TokenEndpointError: Error { case invalidGrant }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(form)
        let (data, response) = try await networkSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = body?["error"] as? String ?? "HTTP \(status)"
            if code == "invalid_grant" { throw TokenEndpointError.invalidGrant }
            let desc = body?["error_description"] as? String ?? ""
            throw AuthError.message("Token request failed: \(code) \(desc)")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        .joined(separator: "&")
        .data(using: .utf8)!
    }

    private static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(Data(bytes).base64URLEncoded().prefix(length))
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback server

/// Tiny one-shot HTTP server on 127.0.0.1 that captures the OAuth redirect.
@MainActor
final class LoopbackServer {
    private var listener: NWListener?
    private var callback: CheckedContinuation<[String: String], Error>?
    private var pendingResult: Result<[String: String], Error>?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handle(connection) }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        if let pendingResult { return try pendingResult.get() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.finish(.failure(AuthError.message("Timed out waiting for Google sign-in.")))
        }
        return try await withCheckedThrowingContinuation { cont in
            callback = cont
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func finish(_ result: Result<[String: String], Error>) {
        if let callback {
            self.callback = nil
            callback.resume(with: result)
        } else if pendingResult == nil {
            pendingResult = result
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return }
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
                let parts = firstLine.split(separator: " ")
                let target = parts.count >= 2 ? String(parts[1]) : "/"

                guard let comps = URLComponents(string: "http://127.0.0.1\(target)"), comps.path == "/" || comps.path.isEmpty else {
                    self.respond(connection, status: "404 Not Found", body: "")
                    return
                }
                var params: [String: String] = [:]
                for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
                guard params["code"] != nil || params["error"] != nil else {
                    self.respond(connection, status: "404 Not Found", body: "")
                    return
                }

                let ok = params["code"] != nil
                let html = """
                <!doctype html><html><head><meta charset="utf-8"><title>Google Tasks</title>
                <style>body{font:16px -apple-system,system-ui;display:flex;align-items:center;justify-content:center;height:90vh;color:#333}
                @media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#ddd}}</style></head>
                <body><div style="text-align:center"><h2>\(ok ? "✓ Signed in" : "Sign-in failed")</h2>
                <p>You can close this tab and return to the Google Tasks app.</p></div></body></html>
                """
                self.respond(connection, status: "200 OK", body: html)
                self.finish(.success(params))
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
