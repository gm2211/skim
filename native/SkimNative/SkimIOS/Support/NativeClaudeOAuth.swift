import CryptoKit
import Foundation

// MARK: - Data models

/// Shared flow state for both the ASWeb and paste code paths.
struct ClaudeOAuthFlow {
    var authorizeURL: URL
    var state: String
    var verifier: String
    var redirectURI: String
}

/// Kept for source compatibility — paste panel still references this name.
typealias ClaudePasteFlow = ClaudeOAuthFlow

struct ClaudeTokenSet: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - Keychain token store

/// Manages Keychain persistence for Claude OAuth tokens.
///
/// Tokens are stored under service "com.skim.native.claude-oauth" with
/// distinct account names for access token, refresh token, and expiry.
/// On first launch after migration, tokens previously stored in
/// AISettings.apiKey (via the settings database) are moved into Keychain
/// and the old value is cleared.
enum ClaudeKeychainStore {
    private static let service = "com.skim.native.claude-oauth"
    private static let accountAccess = "access_token"
    private static let accountRefresh = "refresh_token"
    private static let accountExpiry = "expires_at"

    // MARK: Save

    static func save(_ tokenSet: ClaudeTokenSet) {
        NativeKeychain.set(tokenSet.accessToken, service: service, account: accountAccess)
        if let refresh = tokenSet.refreshToken {
            NativeKeychain.set(refresh, service: service, account: accountRefresh)
        }
        if let expiresIn = tokenSet.expiresIn {
            let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            let iso = ISO8601DateFormatter().string(from: expiresAt)
            NativeKeychain.set(iso, service: service, account: accountExpiry)
        }
    }

    // MARK: Load

    static func loadAccessToken() -> String? {
        NativeKeychain.get(service: service, account: accountAccess)
    }

    static func loadRefreshToken() -> String? {
        NativeKeychain.get(service: service, account: accountRefresh)
    }

    static func loadExpiresAt() -> Date? {
        guard let iso = NativeKeychain.get(service: service, account: accountExpiry) else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }

    // MARK: Clear

    static func clear() {
        NativeKeychain.delete(service: service, account: accountAccess)
        NativeKeychain.delete(service: service, account: accountRefresh)
        NativeKeychain.delete(service: service, account: accountExpiry)
    }

    // MARK: Migration

    /// Migrates a bare access token from the legacy storage location
    /// (AISettings.apiKey in the settings database) to Keychain.
    ///
    /// - Parameter legacyToken: The raw token string from the old location.
    ///   After calling this, callers should nil out their old reference so the
    ///   bearer token is no longer stored in the settings database.
    static func migrateIfNeeded(legacyToken: String) {
        // Only migrate if Keychain is empty to avoid overwriting a newer token.
        guard NativeKeychain.get(service: service, account: accountAccess) == nil else { return }
        let tokenSet = ClaudeTokenSet(accessToken: legacyToken, refreshToken: nil, expiresIn: nil)
        save(tokenSet)
    }
}

// MARK: - OAuth engine

enum NativeClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let scope = "user:profile user:inference"

    /// Redirect URI for the paste flow — the Anthropic success page where the user copies
    /// the code string manually.
    static let pasteRedirectURI = "https://console.anthropic.com/oauth/code/callback"

    // MARK: Flow builders

    static func beginPasteFlow() throws -> ClaudeOAuthFlow {
        try buildFlow(redirectURI: pasteRedirectURI)
    }

    private static func buildFlow(redirectURI: String) throws -> ClaudeOAuthFlow {
        let verifier = randomURLSafeString(byteCount: 32)
        let challenge = codeChallenge(for: verifier)
        let state = randomURLSafeString(byteCount: 32)
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else {
            throw ClaudeOAuthError.invalidAuthorizeURL
        }
        return ClaudeOAuthFlow(authorizeURL: url, state: state, verifier: verifier, redirectURI: redirectURI)
    }

    // MARK: Paste-flow exchange

    /// Exchanges a manually pasted `code#state` string for a token set.
    static func exchange(pastedCode: String, flow: ClaudeOAuthFlow) async throws -> ClaudeTokenSet {
        let trimmed = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClaudeOAuthError.missingCode }

        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts[0]
        let receivedState = parts.count > 1 ? parts[1] : flow.state
        guard receivedState == flow.state else {
            throw ClaudeOAuthError.stateMismatch
        }
        return try await exchangeCode(code, flow: flow)
    }

    // MARK: Token refresh

    /// Attempts to refresh the stored access token using the stored refresh token.
    ///
    /// On success, saves the new token set to Keychain and returns the new access token.
    /// On failure (e.g. refresh token invalid / revoked), clears all Keychain entries
    /// and throws `ClaudeOAuthError.refreshFailed` so callers can prompt re-authentication.
    @discardableResult
    static func refreshStoredTokens() async throws -> String {
        guard let refreshToken = ClaudeKeychainStore.loadRefreshToken() else {
            ClaudeKeychainStore.clear()
            throw ClaudeOAuthError.refreshFailed("No refresh token stored. Sign in again.")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeOAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // Refresh token is invalid or revoked — clear everything.
            ClaudeKeychainStore.clear()
            let text = String(data: data, encoding: .utf8) ?? "empty response"
            throw ClaudeOAuthError.refreshFailed("Claude token refresh \(http.statusCode): \(text). Sign in again.")
        }

        let tokenSet = try JSONDecoder().decode(ClaudeTokenSet.self, from: data)
        ClaudeKeychainStore.save(tokenSet)
        return tokenSet.accessToken
    }

    // MARK: Shared token exchange

    private static func exchangeCode(_ code: String, flow: ClaudeOAuthFlow) async throws -> ClaudeTokenSet {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": flow.state,
            "client_id": clientID,
            "redirect_uri": flow.redirectURI,
            "code_verifier": flow.verifier
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeOAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "empty response"
            throw ClaudeOAuthError.tokenEndpoint("Claude token endpoint \(http.statusCode): \(text)")
        }
        return try JSONDecoder().decode(ClaudeTokenSet.self, from: data)
    }

    // MARK: URL helpers

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        return Data(bytes).base64URLEncodedString()
    }
}

// MARK: - Errors

enum ClaudeOAuthError: LocalizedError {
    case invalidAuthorizeURL
    case missingCode
    case stateMismatch
    case invalidResponse
    case userCancelled
    case tokenEndpoint(String)
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizeURL:
            return "Could not build the Claude sign-in URL."
        case .missingCode:
            return "Paste the code shown after Claude sign-in."
        case .stateMismatch:
            return "Claude sign-in state mismatch. Start sign-in again."
        case .invalidResponse:
            return "Claude returned an invalid token response."
        case .userCancelled:
            return nil // user dismissed — no toast needed
        case .tokenEndpoint(let message):
            return message
        case .refreshFailed(let message):
            return message
        }
    }
}

// MARK: - Data extension

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
