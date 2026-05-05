import CryptoKit
import Foundation

struct ClaudePasteFlow {
    var authorizeURL: URL
    var state: String
    var verifier: String
    var redirectURI: String
}

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

enum NativeClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let scope = "user:profile user:inference"
    static let pasteRedirectURI = "https://console.anthropic.com/oauth/code/callback"

    static func beginPasteFlow() throws -> ClaudePasteFlow {
        let verifier = randomURLSafeString(byteCount: 32)
        let challenge = codeChallenge(for: verifier)
        let state = randomURLSafeString(byteCount: 32)
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: pasteRedirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else {
            throw ClaudeOAuthError.invalidAuthorizeURL
        }
        return ClaudePasteFlow(authorizeURL: url, state: state, verifier: verifier, redirectURI: pasteRedirectURI)
    }

    static func exchange(pastedCode: String, flow: ClaudePasteFlow) async throws -> ClaudeTokenSet {
        let trimmed = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClaudeOAuthError.missingCode }

        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts[0]
        let receivedState = parts.count > 1 ? parts[1] : flow.state
        guard receivedState == flow.state else {
            throw ClaudeOAuthError.stateMismatch
        }

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

enum ClaudeOAuthError: LocalizedError {
    case invalidAuthorizeURL
    case missingCode
    case stateMismatch
    case invalidResponse
    case tokenEndpoint(String)

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizeURL:
            return "Could not build the Claude sign-in URL."
        case .missingCode:
            return "Paste the code shown after Claude sign-in."
        case .stateMismatch:
            return "Claude sign-in state mismatch. Start sign-in again and paste the new code."
        case .invalidResponse:
            return "Claude returned an invalid token response."
        case .tokenEndpoint(let message):
            return message
        }
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
