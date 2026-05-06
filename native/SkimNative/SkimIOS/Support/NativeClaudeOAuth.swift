import AuthenticationServices
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

// MARK: - OAuth engine

enum NativeClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let scope = "user:profile user:inference"

    /// Redirect URI used with ASWebAuthenticationSession (custom URL scheme).
    /// Anthropic's OAuth server must allow this redirect_uri.  If they reject it
    /// the ASWeb path will fail with a token-endpoint error and the UI falls back
    /// to the paste flow automatically.
    static let customSchemeRedirectURI = "skim://oauth/claude/callback"

    /// Fallback redirect URI — the Anthropic success page where the user copies
    /// the code string manually.
    static let pasteRedirectURI = "https://console.anthropic.com/oauth/code/callback"

    // MARK: Flow builders

    static func beginASWebFlow() throws -> ClaudeOAuthFlow {
        try buildFlow(redirectURI: customSchemeRedirectURI)
    }

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

    // MARK: ASWebAuthenticationSession path

    /// Presents an in-app browser via ASWebAuthenticationSession.
    /// Returns a token set on success.
    /// Throws `ClaudeOAuthError.userCancelled` (silent) if the user dismisses.
    /// Throws `ClaudeOAuthError.customSchemeRejected` if the server refuses the
    /// custom redirect_uri — callers should then fall back to the paste path.
    @MainActor
    static func signInWithASWeb(
        from contextProvider: ASWebAuthenticationPresentationContextProviding
    ) async throws -> ClaudeTokenSet {
        let flow = try beginASWebFlow()

        // Wrap ASWebAuthenticationSession in a helper class so Swift 6 strict
        // concurrency is satisfied: the session object itself is not Sendable,
        // but all access happens on the MainActor and the completion handler only
        // calls continuation.resume which is thread-safe.
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: flow.authorizeURL,
                callbackURLScheme: "skim"
            ) { url, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: ClaudeOAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let url else {
                    continuation.resume(throwing: ClaudeOAuthError.missingCallbackURL)
                    return
                }
                continuation.resume(returning: url)
            }
            session.presentationContextProvider = contextProvider
            // Keep any existing Claude session cookies so users who are already
            // signed in to claude.ai don't need to re-enter credentials.
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        let (code, returnedState) = try extractCodeAndState(from: callbackURL)
        guard returnedState == flow.state else {
            throw ClaudeOAuthError.stateMismatch
        }
        return try await exchangeCode(code, flow: flow)
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

    private static func extractCodeAndState(from url: URL) throws -> (code: String, state: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let codeValue = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !codeValue.isEmpty else {
            throw ClaudeOAuthError.missingCode
        }
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        return (codeValue, state)
    }

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
    case missingCallbackURL
    case stateMismatch
    case invalidResponse
    case userCancelled
    case tokenEndpoint(String)

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizeURL:
            return "Could not build the Claude sign-in URL."
        case .missingCode:
            return "Paste the code shown after Claude sign-in."
        case .missingCallbackURL:
            return "No callback URL was returned after sign-in."
        case .stateMismatch:
            return "Claude sign-in state mismatch. Start sign-in again."
        case .invalidResponse:
            return "Claude returned an invalid token response."
        case .userCancelled:
            return nil // user dismissed — no toast needed
        case .tokenEndpoint(let message):
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
