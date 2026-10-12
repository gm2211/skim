import Foundation

// MARK: - Data models

/// A started xAI device-code sign-in: the code the reader confirms on xAI's
/// page, and what Skim polls with until they approve.
struct XAIDeviceStart: Equatable, Sendable {
    var deviceCode: String
    var userCode: String
    var verificationURI: URL
    var verificationURIComplete: URL
    var interval: Int
    var expiresIn: Int
}

struct XAITokenSet: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int
}

// MARK: - Keychain token store

/// Keychain persistence for the SuperGrok sign-in, kept apart from Claude's
/// so signing out of one never touches the other.
enum XAIKeychainStore {
    private static let service = "com.skim.native.xai-oauth"
    private static let accountAccess = "access_token"
    private static let accountRefresh = "refresh_token"
    private static let accountExpiry = "expires_at"

    static func save(_ tokens: XAITokenSet) {
        NativeKeychain.set(tokens.accessToken, service: service, account: accountAccess)
        if let refresh = tokens.refreshToken {
            NativeKeychain.set(refresh, service: service, account: accountRefresh)
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        NativeKeychain.set(ISO8601DateFormatter().string(from: expiresAt), service: service, account: accountExpiry)
    }

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

    static var isSignedIn: Bool { loadAccessToken() != nil }

    static func clear() {
        NativeKeychain.delete(service: service, account: accountAccess)
        NativeKeychain.delete(service: service, account: accountRefresh)
        NativeKeychain.delete(service: service, account: accountExpiry)
    }
}

// MARK: - OAuth engine

/// SuperGrok sign-in: the OAuth 2.0 device-code flow (RFC 8628) against
/// auth.x.ai, the same flow BYOS's `grok()` provider and the desktop app use
/// (`src-tauri/src/ai/xai_oauth.rs`). xAI has no public OAuth client for
/// third-party apps, so this uses the public Grok CLI client id. xAI may answer
/// 403 for some SuperGrok tiers; an xAI API key stays available and wins.
enum NativeXAIOAuth {
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let deviceCodeURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    static let scope = "openid profile email offline_access grok-cli:access api:access"
    private static let deviceCodeGrant = "urn:ietf:params:oauth:grant-type:device_code"

    static func beginDevice(urlSession: URLSession = .shared) async throws -> XAIDeviceStart {
        let request = formRequest(tokenURL: deviceCodeURL, fields: [
            ("client_id", clientID),
            ("scope", scope)
        ])
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw XAIOAuthError.failed("xAI sign-in failed to start (\(status)).")
        }
        return try parseDeviceStart(data)
    }

    static func parseDeviceStart(_ data: Data) throws -> XAIDeviceStart {
        struct Response: Decodable {
            var device_code: String
            var user_code: String
            var verification_uri: String
            var verification_uri_complete: String?
            var interval: Int?
            var expires_in: Int?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let uri = URL(string: decoded.verification_uri)
        else {
            throw XAIOAuthError.failed("xAI returned an unexpected sign-in response.")
        }
        return XAIDeviceStart(
            deviceCode: decoded.device_code,
            userCode: decoded.user_code,
            verificationURI: uri,
            verificationURIComplete: decoded.verification_uri_complete.flatMap(URL.init(string:)) ?? uri,
            interval: max(1, decoded.interval ?? 5),
            expiresIn: decoded.expires_in ?? 300
        )
    }

    /// Polls until the reader approves, declines, or the code expires, then
    /// stores the tokens in the Keychain.
    @discardableResult
    static func completeDevice(_ start: XAIDeviceStart, urlSession: URLSession = .shared) async throws -> XAITokenSet {
        let deadline = Date().addingTimeInterval(TimeInterval(min(start.expiresIn, 900)))
        var wait = start.interval
        while Date() < deadline {
            try await Task.sleep(for: .seconds(wait))
            let request = formRequest(tokenURL: tokenURL, fields: [
                ("grant_type", deviceCodeGrant),
                ("client_id", clientID),
                ("device_code", start.deviceCode)
            ])
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(status) {
                let tokens = try parseTokens(data, previousRefresh: nil)
                XAIKeychainStore.save(tokens)
                return tokens
            }
            let error = oauthError(data)
            switch error.code {
            case "authorization_pending":
                continue
            case "slow_down":
                wait += 5
            case "access_denied", "authorization_denied":
                throw XAIOAuthError.failed("xAI sign-in was declined.")
            case "expired_token":
                throw XAIOAuthError.failed("The xAI sign-in code expired. Start again.")
            default:
                throw XAIOAuthError.failed("xAI sign-in failed (\(status)). \(error.description ?? "")".trimmingCharacters(in: .whitespaces))
            }
        }
        throw XAIOAuthError.failed("Timed out waiting for xAI sign-in.")
    }

    /// Refreshes the stored token. A definitive rejection (400/401) clears the
    /// Keychain so the reader is asked to sign in again.
    @discardableResult
    static func refreshStoredTokens(urlSession: URLSession = .shared) async throws -> String {
        guard let refresh = XAIKeychainStore.loadRefreshToken() else {
            XAIKeychainStore.clear()
            throw XAIOAuthError.failed("SuperGrok sign-in expired. Sign in again.")
        }
        let request = formRequest(tokenURL: tokenURL, fields: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh),
            ("client_id", clientID)
        ])
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            if status == 400 || status == 401 { XAIKeychainStore.clear() }
            throw XAIOAuthError.failed("SuperGrok token refresh failed (\(status)).")
        }
        let tokens = try parseTokens(data, previousRefresh: refresh)
        XAIKeychainStore.save(tokens)
        return tokens.accessToken
    }

    /// A usable access token, refreshed first when it expires within a minute.
    static func validAccessToken() async -> String? {
        guard let token = XAIKeychainStore.loadAccessToken() else { return nil }
        guard let expiresAt = XAIKeychainStore.loadExpiresAt(), expiresAt.timeIntervalSinceNow <= 60 else { return token }
        if let refreshed = try? await refreshStoredTokens() { return refreshed }
        return XAIKeychainStore.loadAccessToken()
    }

    static func parseTokens(_ data: Data, previousRefresh: String?) throws -> XAITokenSet {
        struct Response: Decodable {
            var access_token: String
            var refresh_token: String?
            var expires_in: Int?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw XAIOAuthError.failed("xAI token response was malformed.")
        }
        guard !decoded.access_token.isEmpty else {
            throw XAIOAuthError.failed("xAI token response missing access_token.")
        }
        let refresh = decoded.refresh_token.flatMap { $0.isEmpty ? nil : $0 } ?? previousRefresh
        let expiresIn = decoded.expires_in.flatMap { $0 > 0 ? $0 : nil } ?? 3600
        return XAITokenSet(accessToken: decoded.access_token, refreshToken: refresh, expiresIn: expiresIn)
    }

    private static func oauthError(_ data: Data) -> (code: String?, description: String?) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (object?["error"] as? String, object?["error_description"] as? String)
    }

    private static func formRequest(tokenURL: URL, fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }
}

enum XAIOAuthError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}
