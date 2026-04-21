import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Claude Pro/Max OAuth — Bearer-token flow used by the Claude Code CLI.
/// Reuses the public Claude Code client_id; endpoints and headers are undocumented
/// but stable across Claude Code versions.
actor ClaudeOAuth {
    static let shared = ClaudeOAuth()

    // Public client_id used by Claude Code CLI.
    static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scope = "user:profile user:inference"
    static let betaHeader = "oauth-2025-04-20,claude-code-20250219"
    static let systemPrefix = "You are Claude Code, Anthropic's official CLI for Claude."

    struct PKCE {
        let verifier: String
        let challenge: String
        let state: String
    }

    struct TokenSet: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
        }
    }

    enum OAuthError: LocalizedError {
        case invalidResponse(String)
        case tokenExchangeFailed(String)
        case notAuthenticated

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let m): return m
            case .tokenExchangeFailed(let m): return "Token exchange failed: \(m)"
            case .notAuthenticated: return "Not signed in to Claude"
            }
        }
    }

    private var inFlightPKCE: PKCE?

    // MARK: - Authorize URL

    func beginAuthorization() -> (url: URL, pkce: PKCE) {
        let pkce = Self.generatePKCE()
        inFlightPKCE = pkce

        var comps = URLComponents(string: Self.authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state)
        ]
        return (comps.url!, pkce)
    }

    // MARK: - Paste-code exchange

    /// User pastes the `CODE#STATE` string shown on the console callback page.
    /// We split on `#`, validate state, and POST to the token endpoint.
    func exchange(pastedCode raw: String) async throws -> TokenSet {
        guard let pkce = inFlightPKCE else {
            throw OAuthError.tokenExchangeFailed("No authorization in progress")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code: String
        let state: String
        if parts.count == 2 {
            code = parts[0]
            state = parts[1]
        } else {
            // Some pages hand back only the code; accept that too and skip state verify.
            code = trimmed
            state = pkce.state
        }
        guard state == pkce.state else {
            throw OAuthError.tokenExchangeFailed("State mismatch")
        }
        let tokens = try await postToken(body: [
            "grant_type": "authorization_code",
            "code": code,
            "state": pkce.state,
            "client_id": Self.clientId,
            "redirect_uri": Self.redirectURI,
            "code_verifier": pkce.verifier
        ])
        persist(tokens)
        inFlightPKCE = nil
        return tokens
    }

    // MARK: - Refresh

    func refreshIfNeeded() async throws -> String {
        guard let access = KeychainStore.get(.claudeAccessToken) else {
            throw OAuthError.notAuthenticated
        }
        let expiresAt = KeychainStore.get(.claudeExpiresAt).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        if let expiresAt, expiresAt.timeIntervalSinceNow > 60 {
            return access
        }
        guard let refresh = KeychainStore.get(.claudeRefreshToken) else {
            // No refresh — return existing access; caller will get 401 and re-prompt sign in.
            return access
        }
        let tokens = try await postToken(body: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": Self.clientId
        ])
        persist(tokens)
        return tokens.accessToken
    }

    func signOut() {
        KeychainStore.clearClaudeAuth()
    }

    var isSignedIn: Bool {
        KeychainStore.get(.claudeAccessToken) != nil
    }

    // MARK: - Internals

    private func postToken(body: [String: String]) async throws -> TokenSet {
        var req = URLRequest(url: URL(string: Self.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw OAuthError.tokenExchangeFailed("HTTP \(http.statusCode): \(body)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw OAuthError.invalidResponse("Missing access_token")
        }
        let refreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? Double ?? 3600 * 8
        return TokenSet(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private func persist(_ tokens: TokenSet) {
        KeychainStore.set(tokens.accessToken, for: .claudeAccessToken)
        if let rt = tokens.refreshToken {
            KeychainStore.set(rt, for: .claudeRefreshToken)
        }
        KeychainStore.set(String(tokens.expiresAt.timeIntervalSince1970), for: .claudeExpiresAt)
    }

    // MARK: - PKCE

    private static func generatePKCE() -> PKCE {
        let verifier = randomURLSafe(bytes: 32)
        let challengeBytes = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64url(Data(challengeBytes))
        let state = randomURLSafe(bytes: 32)
        return PKCE(verifier: verifier, challenge: challenge, state: state)
    }

    private static func randomURLSafe(bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, buf.count, &buf)
        return base64url(Data(buf))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
