import CryptoKit
import Foundation
import Network
import SkimCore

// Sign in with ChatGPT: OpenAI's official way for an open-source app to run on a
// reader's ChatGPT Plus/Pro plan instead of an API key ("ChatGPT plan usage",
// https://developers.openai.com/siwc/token-sharing-open-source). The first sign-in
// registers Skim as the reader's own agent (`client_id=dynamic_agent_client`), which
// issues a per-account client id. Inference goes to the public Responses API at
// api.openai.com with `store: false` and `stream: true`. The desktop app does the same
// in `src-tauri/src/ai/chatgpt_oauth.rs`.

// MARK: - Data models

struct ChatGPTTokenSet: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresIn: Int
    var scope: String?
}

/// A started sign-in: the page to open and what the callback is checked against.
struct ChatGPTSignInFlow: Equatable, Sendable {
    var authorizeURL: URL
    var state: String
    var nonce: String
    var verifier: String
    var redirectURI: String
    /// The saved issued client id for a returning account; nil registers anew.
    var savedClientID: String?
}

// MARK: - Keychain store

/// Keychain persistence for the ChatGPT sign-in, apart from Claude's and Grok's.
/// The host id and the issued client id outlive sign-out, as OpenAI asks: the
/// registration is the reader's, and signing in again reuses it.
enum ChatGPTKeychainStore {
    private static let service = "com.skim.native.chatgpt-oauth"
    private static let accountAccess = "access_token"
    private static let accountRefresh = "refresh_token"
    private static let accountIDToken = "id_token"
    private static let accountExpiry = "expires_at"
    private static let accountEmail = "email"
    private static let accountClientID = "client_id"
    private static let accountHostID = "host_id"

    static func save(_ tokens: ChatGPTTokenSet, clientID: String) {
        NativeKeychain.set(tokens.accessToken, service: service, account: accountAccess)
        if let refresh = tokens.refreshToken?.nilIfEmpty {
            NativeKeychain.set(refresh, service: service, account: accountRefresh)
        }
        if let idToken = tokens.idToken?.nilIfEmpty {
            NativeKeychain.set(idToken, service: service, account: accountIDToken)
            if let email = NativeChatGPTOAuth.claims(ofJWT: idToken)?["email"] as? String {
                NativeKeychain.set(email, service: service, account: accountEmail)
            }
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        NativeKeychain.set(ISO8601DateFormatter().string(from: expiresAt), service: service, account: accountExpiry)
        NativeKeychain.set(clientID, service: service, account: accountClientID)
    }

    static func loadAccessToken() -> String? { NativeKeychain.get(service: service, account: accountAccess) }
    static func loadRefreshToken() -> String? { NativeKeychain.get(service: service, account: accountRefresh) }
    static func loadIDToken() -> String? { NativeKeychain.get(service: service, account: accountIDToken) }
    static func loadEmail() -> String? { NativeKeychain.get(service: service, account: accountEmail) }
    static func loadClientID() -> String? { NativeKeychain.get(service: service, account: accountClientID) }

    static func loadExpiresAt() -> Date? {
        guard let iso = NativeKeychain.get(service: service, account: accountExpiry) else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }

    static var isSignedIn: Bool { loadAccessToken() != nil }

    /// This install's `ext_agent_host_id`: a random UUID URN made once and kept.
    static func hostID() -> String {
        if let saved = NativeKeychain.get(service: service, account: accountHostID) { return saved }
        let made = "urn:uuid:" + UUID().uuidString.lowercased()
        NativeKeychain.set(made, service: service, account: accountHostID)
        return made
    }

    static func forgetClientID() {
        NativeKeychain.delete(service: service, account: accountClientID)
    }

    /// Signs out: drops the tokens, keeps the host id and the issued client id.
    static func clear() {
        for account in [accountAccess, accountRefresh, accountIDToken, accountExpiry, accountEmail] {
            NativeKeychain.delete(service: service, account: account)
        }
    }
}

// MARK: - OAuth engine

enum NativeChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let authorizeURL = "https://auth.openai.com/api/accounts/authorize"
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let resource = "https://api.openai.com/v1"
    static let registrationClientID = "dynamic_agent_client"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let planUsageScope = "chatgpt.tokens.use.direct"
    static let agentName = "Skim"
    /// OpenAI only accepts a `127.0.0.1` loopback callback; `localhost` is refused.
    static let callbackPorts: [UInt16] = [1455, 54321]
    static let callbackPath = "/auth/callback"

    static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(callbackPath)"
    }

    static func beginFlow(port: UInt16, savedClientID: String? = ChatGPTKeychainStore.loadClientID(), hostID: String = ChatGPTKeychainStore.hostID()) -> ChatGPTSignInFlow {
        let verifier = randomURLSafeString(byteCount: 32)
        let state = randomURLSafeString(byteCount: 24)
        let nonce = randomURLSafeString(byteCount: 24)
        let redirect = redirectURI(port: port)
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: savedClientID ?? registrationClientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if savedClientID == nil {
            items.append(URLQueryItem(name: "agent_name_hint", value: agentName))
            items.append(URLQueryItem(name: "ext_agent_host_id", value: hostID))
        }
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = items
        // URLComponents leaves "+" and ":" bare; OpenAI reads a "+" as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return ChatGPTSignInFlow(
            authorizeURL: components.url!,
            state: state,
            nonce: nonce,
            verifier: verifier,
            redirectURI: redirect,
            savedClientID: savedClientID
        )
    }

    /// The code and client id from the loopback callback, after checking `state`.
    static func parseCallback(_ components: URLComponents, flow: ChatGPTSignInFlow) throws -> (code: String, clientID: String) {
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value?.nilIfEmpty }
        guard value("state") == flow.state else { throw ChatGPTOAuthError.stateMismatch }
        if let error = value("error") {
            if error == "access_denied" { throw ChatGPTOAuthError.declined }
            throw ChatGPTOAuthError.server(value("error_description") ?? error)
        }
        guard let code = value("code") else { throw ChatGPTOAuthError.missingCode }
        // A new registration returns the issued client id; a returning account keeps its own.
        guard let clientID = value("client_id") ?? flow.savedClientID, clientID != registrationClientID else {
            throw ChatGPTOAuthError.server("ChatGPT didn't return a client id. Sign in again.")
        }
        return (code, clientID)
    }

    /// The whole sign-in: listen on the loopback port, let `present` show the
    /// page in-app, and finish when ChatGPT redirects back.
    @MainActor
    static func signIn(present: @escaping @MainActor (URL) -> Void) async throws -> String? {
        var listener: LoopbackCallbackListener?
        var lastError: Error?
        for port in callbackPorts {
            do {
                listener = try await LoopbackCallbackListener.start(port: port, path: callbackPath)
                break
            } catch {
                lastError = error
            }
        }
        guard let listener else {
            throw ChatGPTOAuthError.server("Couldn't start sign-in: \(lastError?.localizedDescription ?? "the sign-in port is busy").")
        }
        defer { listener.stop() }
        let flow = beginFlow(port: listener.port)
        present(flow.authorizeURL)
        let callback = try await listener.waitForCallback(timeout: 600)
        let (code, clientID) = try parseCallback(callback, flow: flow)
        let tokens: ChatGPTTokenSet
        do {
            tokens = try await exchange(code: code, clientID: clientID, flow: flow)
        } catch ChatGPTOAuthError.invalidClient {
            // The saved registration is gone; the next sign-in registers again.
            ChatGPTKeychainStore.forgetClientID()
            throw ChatGPTOAuthError.server("Your ChatGPT connection was reset. Sign in again.")
        }
        ChatGPTKeychainStore.save(tokens, clientID: clientID)
        return ChatGPTKeychainStore.loadEmail()
    }

    static func exchange(code: String, clientID: String, flow: ChatGPTSignInFlow, urlSession: URLSession = .shared) async throws -> ChatGPTTokenSet {
        let data = try await postForm([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": flow.verifier,
            "redirect_uri": flow.redirectURI,
            "resource": resource
        ], urlSession: urlSession)
        let tokens = try parseTokens(data, previousRefresh: nil)
        try validate(tokens, clientID: clientID, nonce: flow.nonce)
        return tokens
    }

    static func parseTokens(_ data: Data, previousRefresh: String?) throws -> ChatGPTTokenSet {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = (json["access_token"] as? String)?.nilIfEmpty else {
            throw ChatGPTOAuthError.server("ChatGPT returned an unexpected sign-in response.")
        }
        let expiresIn = (json["expires_in"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? 3600
        return ChatGPTTokenSet(
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String)?.nilIfEmpty ?? previousRefresh,
            idToken: (json["id_token"] as? String)?.nilIfEmpty,
            expiresIn: expiresIn,
            scope: json["scope"] as? String
        )
    }

    /// Checks the ID token's issuer, audience, nonce, and expiry, and that the reader
    /// granted plan usage. The token comes straight from OpenAI's token endpoint over
    /// TLS, which OpenID Connect Core 3.1.3.7 accepts in place of a signature check.
    static func validate(_ tokens: ChatGPTTokenSet, clientID: String, nonce: String, now: Date = Date()) throws {
        guard let idToken = tokens.idToken, let claims = claims(ofJWT: idToken) else {
            throw ChatGPTOAuthError.server("ChatGPT didn't confirm who signed in. Sign in again.")
        }
        let audience = (claims["aud"] as? String).map { [$0] } ?? (claims["aud"] as? [String]) ?? []
        let expiry = (claims["exp"] as? Double) ?? (claims["exp"] as? Int).map(Double.init) ?? 0
        guard (claims["iss"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == issuer,
              audience.contains(clientID),
              claims["nonce"] as? String == nonce,
              expiry > now.timeIntervalSince1970 - 60 else {
            throw ChatGPTOAuthError.server("ChatGPT's sign-in didn't check out. Sign in again.")
        }
        let granted = tokens.scope ?? (claims(ofJWT: tokens.accessToken)?["scope"] as? String) ?? ""
        guard granted.split(whereSeparator: { $0 == " " || $0 == "+" }).contains(Substring(planUsageScope)) else {
            throw ChatGPTOAuthError.planUsageNotGranted
        }
    }

    // MARK: Refresh

    /// Refreshes the stored tokens. Refresh tokens rotate, so concurrent callers
    /// share one request rather than spend the same token twice.
    @discardableResult
    static func refreshStoredTokens() async throws -> String {
        try await ChatGPTRefreshGate.shared.refresh()
    }

    fileprivate static func performRefresh(urlSession: URLSession = .shared) async throws -> String {
        guard let refresh = ChatGPTKeychainStore.loadRefreshToken(), let clientID = ChatGPTKeychainStore.loadClientID() else {
            ChatGPTKeychainStore.clear()
            throw ChatGPTOAuthError.signInExpired
        }
        let data: Data
        do {
            data = try await postForm([
                "grant_type": "refresh_token",
                "client_id": clientID,
                "refresh_token": refresh,
                "resource": resource
            ], urlSession: urlSession)
        } catch ChatGPTOAuthError.rejected {
            ChatGPTKeychainStore.clear()
            throw ChatGPTOAuthError.signInExpired
        } catch ChatGPTOAuthError.invalidClient {
            ChatGPTKeychainStore.clear()
            ChatGPTKeychainStore.forgetClientID()
            throw ChatGPTOAuthError.signInExpired
        }
        let tokens = try parseTokens(data, previousRefresh: refresh)
        ChatGPTKeychainStore.save(tokens, clientID: clientID)
        return tokens.accessToken
    }

    /// The stored access token, refreshed first when it expires within two minutes.
    static func validAccessToken() async -> String? {
        guard let token = ChatGPTKeychainStore.loadAccessToken() else { return nil }
        guard let expiresAt = ChatGPTKeychainStore.loadExpiresAt(), expiresAt.timeIntervalSinceNow <= 120 else { return token }
        return (try? await refreshStoredTokens()) ?? ChatGPTKeychainStore.loadAccessToken()
    }

    // MARK: Helpers

    private static func postForm(_ fields: [String: String], urlSession: URLSession) async throws -> Data {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncode(fields).utf8)
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = (json?["error"] as? String) ?? ""
            if error == "invalid_client" { throw ChatGPTOAuthError.invalidClient }
            let dead: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
            if dead.contains(error) { throw ChatGPTOAuthError.rejected }
            let detail = (json?["error_description"] as? String) ?? error.nilIfEmpty ?? "HTTP \(status)"
            throw ChatGPTOAuthError.server("ChatGPT sign-in failed: \(detail)")
        }
        return data
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    /// The payload of a JWT, without checking its signature.
    static func claims(ofJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).chatGPTBase64URL()
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).chatGPTBase64URL()
    }
}

private actor ChatGPTRefreshGate {
    static let shared = ChatGPTRefreshGate()
    private var inFlight: Task<String, Error>?

    func refresh() async throws -> String {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await NativeChatGPTOAuth.performRefresh() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

enum ChatGPTOAuthError: LocalizedError, Equatable {
    case stateMismatch
    case declined
    case missingCode
    case planUsageNotGranted
    case signInExpired
    case invalidClient
    case rejected
    case timedOut
    case server(String)

    var errorDescription: String? {
        switch self {
        case .stateMismatch: "ChatGPT sign-in didn't match. Start again."
        case .declined: "ChatGPT sign-in was cancelled."
        case .missingCode: "ChatGPT didn't finish signing in. Start again."
        case .planUsageNotGranted: "ChatGPT signed you in but didn't allow Skim to use your plan. Sign in again and allow plan usage."
        case .signInExpired, .rejected, .invalidClient: "ChatGPT sign-in expired. Sign in again in Settings."
        case .timedOut: "ChatGPT sign-in timed out. Start again."
        case .server(let message): message
        }
    }
}

// MARK: - Loopback callback

/// Accepts the one redirect ChatGPT sends to `http://127.0.0.1:<port>/auth/callback`.
/// The sign-in page runs in an in-app Safari sheet, so Skim stays in front and
/// its listener stays up until the redirect lands.
final class LoopbackCallbackListener: @unchecked Sendable {
    let port: UInt16
    private let path: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.skim.chatgpt-callback")
    private var waiter: CheckedContinuation<URLComponents, Error>?
    private var result: Result<URLComponents, Error>?

    private init(port: UInt16, path: String, listener: NWListener) {
        self.port = port
        self.path = path
        self.listener = listener
    }

    static func start(port: UInt16, path: String) async throws -> LoopbackCallbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        let callback = LoopbackCallbackListener(port: port, path: path, listener: listener)
        listener.newConnectionHandler = { [weak callback] connection in callback?.handle(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Runs on `callback.queue` only, so the flag needs no lock.
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    once.run {
                        listener.cancel()
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    once.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: callback.queue)
        }
        return callback
    }

    func waitForCallback(timeout: TimeInterval) async throws -> URLComponents {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(ChatGPTOAuthError.timedOut)) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result)
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func stop() {
        listener.cancel()
    }

    private func finish(_ outcome: Result<URLComponents, Error>) {
        queue.async {
            guard self.result == nil else { return }
            self.result = outcome
            self.waiter?.resume(with: outcome)
            self.waiter = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) == nil, !isComplete, error == nil, buffer.count < 65_536 {
                self.receive(connection, buffer: buffer)
                return
            }
            self.respond(to: buffer, on: connection)
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let firstLine = String(decoding: request.prefix(4096), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : ""
        let components = URLComponents(string: "http://127.0.0.1:\(port)\(target)")
        let isCallback = components?.path == path
        let body = isCallback
            ? "<!doctype html><meta name=viewport content=\"width=device-width\"><body style=\"font:17px -apple-system;padding:40px;text-align:center\"><h2>Signed in to ChatGPT</h2><p>You can return to Skim.</p></body>"
            : "Not found"
        let head = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
        if isCallback, let components { finish(.success(components)) }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private var done = false

    func run(_ body: () -> Void) {
        guard !done else { return }
        done = true
        body()
    }
}

// MARK: - Inference

/// The Responses API on a ChatGPT plan: instructions plus the conversation as input,
/// streamed until `response.completed`. Sampling and length parameters are refused
/// on plan usage, so none are sent.
enum NativeChatGPT {
    static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    static let modelsURL = URL(string: "https://api.openai.com/v1/models")!
    static let usageSettingsURL = URL(string: "https://chatgpt.com/settings/usage")!

    static func complete(
        settings: AISettings,
        instructions: String,
        prompt: String,
        messages: [[String: String]]? = nil,
        urlSession: URLSession = .shared
    ) async throws -> String {
        guard var token = await NativeChatGPTOAuth.validAccessToken() else {
            throw NativeAIError.unavailable("Sign in with ChatGPT in Settings.")
        }
        let model = try await resolvedModel(settings, token: token, urlSession: urlSession)
        let system = messages?.first(where: { $0["role"] == "system" })?["content"]?.nilIfEmpty ?? instructions
        let input = responsesInput(prompt: prompt, messages: messages)
        for attempt in 0..<2 {
            let request = try buildResponsesRequest(model: model, instructions: system, input: input, token: token)
            let (bytes, response) = try await urlSession.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 401, attempt == 0 {
                guard let refreshed = try? await NativeChatGPTOAuth.refreshStoredTokens() else {
                    throw NativeAIError.unavailable(ChatGPTOAuthError.signInExpired.errorDescription!)
                }
                token = refreshed
                continue
            }
            guard (200..<300).contains(status) else {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                print("[NativeAI] ChatGPT request failed (\(status)): \(String(decoding: body.prefix(2000), as: UTF8.self))")
                throw NativeAIError.unavailable(friendlyHTTPError(status: status, data: body))
            }
            var stream = ResponsesStream()
            for try await line in bytes.lines {
                if try stream.consume(line) { break }
            }
            return try stream.finish()
        }
        throw NativeAIError.unavailable(ChatGPTOAuthError.signInExpired.errorDescription!)
    }

    static func responsesInput(prompt: String, messages: [[String: String]]?) -> [[String: Any]] {
        let turns = messages?.filter { $0["role"] != "system" } ?? [["role": "user", "content": prompt]]
        return turns.map { turn in
            let isAssistant = turn["role"] == "assistant"
            return [
                "role": isAssistant ? "assistant" : "user",
                "content": [["type": isAssistant ? "output_text" : "input_text", "text": turn["content"] ?? ""]]
            ]
        }
    }

    static func buildResponsesRequest(model: String, instructions: String, input: [[String: Any]], token: String) throws -> URLRequest {
        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "store": false,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Accumulates a Responses event stream; done at `response.completed`.
    struct ResponsesStream {
        private(set) var text = ""
        private(set) var completed = false

        /// Takes one SSE line; returns true when the response is complete.
        mutating func consume(_ line: String) throws -> Bool {
            guard line.hasPrefix("data:") else { return false }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            let response = event["response"] as? [String: Any]
            switch event["type"] as? String {
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
            case "response.completed":
                if text.isEmpty, let response { text = NativeChatGPT.outputText(of: response) }
                completed = true
                return true
            case "response.incomplete":
                if text.isEmpty, let response { text = NativeChatGPT.outputText(of: response) }
                guard !text.isEmpty else {
                    let reason = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String
                    throw NativeAIError.unavailable("ChatGPT stopped before answering\(reason.map { " (\($0))" } ?? "").")
                }
                completed = true
                return true
            case "response.failed":
                let error = response?["error"] as? [String: Any]
                throw NativeAIError.unavailable(NativeChatGPT.friendlyError(code: error?["code"] as? String, message: error?["message"] as? String))
            case "error":
                let error = (event["error"] as? [String: Any]) ?? event
                throw NativeAIError.unavailable(NativeChatGPT.friendlyError(code: error["code"] as? String, message: error["message"] as? String))
            default:
                break
            }
            return false
        }

        func finish() throws -> String {
            guard completed else { throw NativeAIError.unavailable("ChatGPT's answer was cut off. Try again.") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw NativeAIError.unavailable("The ChatGPT response was empty.") }
            return trimmed
        }
    }

    static func outputText(of response: [String: Any]) -> String {
        let output = response["output"] as? [[String: Any]] ?? []
        return output
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    static func friendlyError(code: String?, message: String?) -> String {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return "Your ChatGPT plan's limit for Skim is used up. Raise it in ChatGPT's usage settings or wait for it to reset."
        case "subscription_sharing_user_not_eligible":
            return "This ChatGPT account's plan can't be used in other apps. Plus and Pro plans can."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return "ChatGPT plan usage is unavailable right now. Try again shortly."
        case "subscription_sharing_invalid_user", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return "ChatGPT needs you to sign in again. Open Settings to reconnect."
        default:
            if let message = message?.nilIfEmpty {
                let reason = message.count > 240 ? String(message.prefix(240)) + "…" : message
                return "ChatGPT couldn't run this request: \(reason)"
            }
            return "ChatGPT couldn't run this request. Try again."
        }
    }

    static func friendlyHTTPError(status: Int, data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let code = error?["code"] as? String
        let message = (error?["message"] as? String) ?? (json?["detail"] as? String)
        if code != nil { return friendlyError(code: code, message: message) }
        switch status {
        case 401: return ChatGPTOAuthError.signInExpired.errorDescription!
        case 429: return friendlyError(code: "subscription_sharing_usage_limit_exceeded", message: nil)
        case 500...599: return "ChatGPT is temporarily unavailable. Try again shortly."
        default: return friendlyError(code: nil, message: message)
        }
    }

    // MARK: Models

    static func fetchModels(urlSession: URLSession = .shared) async throws -> [AIModelInfo] {
        guard var token = await NativeChatGPTOAuth.validAccessToken() else {
            throw NativeAIError.unavailable("Sign in with ChatGPT in Settings.")
        }
        for attempt in 0..<2 {
            var request = URLRequest(url: modelsURL)
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 401, attempt == 0, let refreshed = try? await NativeChatGPTOAuth.refreshStoredTokens() {
                token = refreshed
                continue
            }
            guard (200..<300).contains(status) else {
                throw NativeAIError.unavailable(friendlyHTTPError(status: status, data: data))
            }
            return parseModels(data)
        }
        throw NativeAIError.unavailable(ChatGPTOAuthError.signInExpired.errorDescription!)
    }

    /// Plan-usage model lists come as `{"models":[{slug, display_name, visibility}]}`;
    /// only `visibility == "list"` belongs in a picker. A plain `{"data":[{id}]}` list
    /// is read too.
    static func parseModels(_ data: Data) -> [AIModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let models = json["models"] as? [[String: Any]] {
            return models.compactMap { model in
                guard let slug = (model["slug"] as? String)?.nilIfEmpty else { return nil }
                if let visibility = model["visibility"] as? String, visibility != "list" { return nil }
                return AIModelInfo(id: slug, displayName: (model["display_name"] as? String)?.nilIfEmpty ?? slug)
            }
        }
        return (json["data"] as? [[String: Any]] ?? []).compactMap { model in
            (model["id"] as? String)?.nilIfEmpty.map { AIModelInfo(id: $0, displayName: $0) }
        }
    }

    /// The picked model, or the first one the reader's plan lists.
    private static func resolvedModel(_ settings: AISettings, token: String, urlSession: URLSession) async throws -> String {
        if let model = settings.model?.nilIfEmpty, isChatGPTModel(model) { return model }
        if let first = try await fetchModels(urlSession: urlSession).first?.id { return first }
        throw NativeAIError.unavailable("Your ChatGPT plan lists no models Skim can use.")
    }

    /// Whether a stored model id could be a ChatGPT plan model rather than one left
    /// behind by another provider.
    static func isChatGPTModel(_ model: String) -> Bool {
        !model.hasPrefix("claude") && !model.hasPrefix("grok") && !model.contains("/")
    }
}

private extension Data {
    func chatGPTBase64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
