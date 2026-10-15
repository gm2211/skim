import Testing
import Foundation
import SkimCore
@testable import Skim

@Suite("SuperGrok device-code sign-in")
struct NativeXAIOAuthTests {

    @Test func deviceStartFallsBackToPlainVerificationURI() throws {
        let data = Data(#"{"device_code":"dc","user_code":"ABCD-1234","verification_uri":"https://accounts.x.ai/device","interval":0}"#.utf8)
        let start = try NativeXAIOAuth.parseDeviceStart(data)
        #expect(start.userCode == "ABCD-1234")
        #expect(start.verificationURIComplete.absoluteString == "https://accounts.x.ai/device")
        #expect(start.interval == 1)
        #expect(start.expiresIn == 300)
    }

    @Test func refreshKeepsPreviousRefreshTokenWhenOmitted() throws {
        let tokens = try NativeXAIOAuth.parseTokens(Data(#"{"access_token":"a","expires_in":60}"#.utf8), previousRefresh: "r1")
        #expect(tokens.accessToken == "a")
        #expect(tokens.refreshToken == "r1")
        #expect(tokens.expiresIn == 60)
    }

    // Approving in Safari suspends Skim, and the poll in flight comes back as
    // "The network connection was lost." The sign-in must keep polling, not fail.
    @Test func pollingSurvivesAConnectionLostWhileInSafari() async throws {
        XAIPollStubURLProtocol.responses = [
            .failure(URLError(.networkConnectionLost)),
            .success(#"{"access_token":"grok-token","refresh_token":"r","expires_in":3600}"#)
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XAIPollStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { XAIKeychainStore.clear() }

        let start = XAIDeviceStart(
            deviceCode: "dc", userCode: "ABCD", verificationURI: URL(string: "https://accounts.x.ai/device")!,
            verificationURIComplete: URL(string: "https://accounts.x.ai/device")!, interval: 1, expiresIn: 60
        )
        let tokens = try await NativeXAIOAuth.completeDevice(start, urlSession: session)
        #expect(tokens.accessToken == "grok-token")
        #expect(XAIPollStubURLProtocol.responses.isEmpty)
    }

    @Test func onlyNetworkBlipsKeepThePollGoing() {
        #expect(NativeXAIOAuth.isTransientWhileAway(URLError(.networkConnectionLost)))
        #expect(NativeXAIOAuth.isTransientWhileAway(URLError(.timedOut)))
        #expect(!NativeXAIOAuth.isTransientWhileAway(URLError(.cancelled)))
        #expect(!NativeXAIOAuth.isTransientWhileAway(URLError(.badServerResponse)))
    }

    @Test func missingAccessTokenIsAnError() {
        #expect(throws: XAIOAuthError.self) {
            try NativeXAIOAuth.parseTokens(Data(#"{"access_token":""}"#.utf8), previousRefresh: nil)
        }
    }

    @Test func grokRequestUsesTheSignInTokenWhenNoKeyIsSet() throws {
        let request = try NativeAI.buildOpenAICompatibleRequest(
            settings: AISettings(provider: "xai", model: "grok-4.3"),
            instructions: "i",
            prompt: "p",
            maxTokens: 10,
            bearerToken: "supergrok-token"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer supergrok-token")
        #expect(request.url?.host == "api.x.ai")
    }

    @Test func grokAPIKeyTakesPriorityOverTheSignIn() throws {
        let request = try NativeAI.buildOpenAICompatibleRequest(
            settings: AISettings(provider: "xai", apiKey: "xai-key", model: "grok-4.3"),
            instructions: "i",
            prompt: "p",
            maxTokens: 10,
            bearerToken: "supergrok-token"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer xai-key")
    }
}

@Suite("AI provider profiles", .serialized)
struct AIProviderProfilesTests {

    private func isolatedDefaults() -> UserDefaults {
        let name = "skim.tests.profiles.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func switchingAwayAndBackRestoresKeyAndModel() {
        let defaults = isolatedDefaults()
        let openAI = AISettings(provider: "openai", apiKey: "sk-openai", model: "gpt-5")

        let onGrok = AIProviderProfiles.switching(openAI, to: "xai", defaults: defaults)
        #expect(onGrok.provider == "xai")
        #expect(onGrok.apiKey != "sk-openai")
        #expect(onGrok.model != "gpt-5")

        let back = AIProviderProfiles.switching(onGrok, to: "openai", defaults: defaults)
        #expect(back.apiKey == "sk-openai")
        #expect(back.model == "gpt-5")
    }

    @Test func onDeviceProvidersDropCloudCredentials() {
        let defaults = isolatedDefaults()
        let custom = AISettings(provider: "custom", apiKey: "k", model: "m", endpoint: "https://example.com")
        let onDevice = AIProviderProfiles.switching(custom, to: "foundation-models", defaults: defaults)
        #expect(onDevice.apiKey == nil)
        #expect(onDevice.endpoint == nil)
        #expect(onDevice.model == nil)

        let back = AIProviderProfiles.switching(onDevice, to: "custom", defaults: defaults)
        #expect(back.endpoint == "https://example.com")
        #expect(back.apiKey == "k")
    }
}

@Suite("Inline model picker providers")
struct ModelCatalogProviderTests {

    @Test func everyListedCloudProviderHasAName() {
        for id in ["claude-subscription", "anthropic", "xai", "openai", "openrouter", "custom", "mlx", "foundation-models"] {
            #expect(NativeAIProviderChoice.name(for: id) != id)
        }
    }
}

/// Serves queued device-token poll results in order: a URLError or a 200 JSON body.
private final class XAIPollStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case failure(URLError), success(String) }
    nonisolated(unsafe) static var responses: [Reply] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard !Self.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        switch Self.responses.removeFirst() {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@Suite("Sign in with ChatGPT")
struct NativeChatGPTTests {
    private func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let body = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(body).sig"
    }

    @Test func firstSignInRegistersSkimAsTheReadersAgent() {
        let flow = NativeChatGPTOAuth.beginFlow(port: 1455, savedClientID: nil, hostID: "urn:uuid:abc")
        let items = URLComponents(url: flow.authorizeURL, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        #expect(flow.authorizeURL.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
        #expect(value("client_id") == "dynamic_agent_client")
        #expect(value("agent_name_hint") == "Skim")
        #expect(value("ext_agent_host_id") == "urn:uuid:abc")
        #expect(value("redirect_uri") == "http://127.0.0.1:1455/auth/callback")
        #expect(value("scope") == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(value("resource") == "https://api.openai.com/v1")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("nonce") == flow.nonce)
    }

    @Test func returningAccountReusesItsClientID() {
        let flow = NativeChatGPTOAuth.beginFlow(port: 1455, savedClientID: "client-1", hostID: "urn:uuid:abc")
        let items = URLComponents(url: flow.authorizeURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first(where: { $0.name == "client_id" })?.value == "client-1")
        #expect(!items.contains(where: { $0.name == "agent_name_hint" }))
        #expect(items.first(where: { $0.name == "ext_agent_host_id" })?.value == "urn:uuid:abc")
    }

    @Test func callbackChecksStateAndTakesTheIssuedClientID() throws {
        let flow = NativeChatGPTOAuth.beginFlow(port: 1455, savedClientID: nil, hostID: "h")
        let good = URLComponents(string: "http://127.0.0.1:1455/auth/callback?code=c1&state=\(flow.state)&client_id=issued")!
        let result = try NativeChatGPTOAuth.parseCallback(good, flow: flow)
        #expect(result.code == "c1")
        #expect(result.clientID == "issued")

        let forged = URLComponents(string: "http://127.0.0.1:1455/auth/callback?code=c1&state=other&client_id=issued")!
        #expect(throws: ChatGPTOAuthError.stateMismatch) { try NativeChatGPTOAuth.parseCallback(forged, flow: flow) }

        let denied = URLComponents(string: "http://127.0.0.1:1455/auth/callback?error=access_denied&state=\(flow.state)")!
        #expect(throws: ChatGPTOAuthError.declined) { try NativeChatGPTOAuth.parseCallback(denied, flow: flow) }
    }

    @Test func signInNeedsPlanUsageNotJustIdentity() throws {
        let id = jwt(["iss": "https://auth.openai.com", "aud": "issued", "nonce": "n1", "exp": Date().timeIntervalSince1970 + 600, "email": "a@b.c"])
        var tokens = ChatGPTTokenSet(accessToken: "a", refreshToken: "r", idToken: id, expiresIn: 3600,
                                     scope: "chatgpt.tokens.use.direct email offline_access openid profile resource.invoke")
        try NativeChatGPTOAuth.validate(tokens, clientID: "issued", nonce: "n1")
        #expect(throws: ChatGPTOAuthError.self) { try NativeChatGPTOAuth.validate(tokens, clientID: "issued", nonce: "other") }
        tokens.scope = "openid profile email"
        #expect(throws: ChatGPTOAuthError.planUsageNotGranted) { try NativeChatGPTOAuth.validate(tokens, clientID: "issued", nonce: "n1") }
    }

    @Test func requestIsStreamedAndUnstored() throws {
        let input = NativeChatGPT.responsesInput(prompt: "", messages: [
            ["role": "system", "content": "be brief"],
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": "hello"]
        ])
        let request = try NativeChatGPT.buildResponsesRequest(model: "gpt-x", instructions: "be brief", input: input, token: "tok")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["temperature"] == nil)
        #expect(body["max_output_tokens"] == nil)
        let turns = body["input"] as! [[String: Any]]
        #expect(turns.count == 2)
        #expect(((turns[1]["content"] as! [[String: Any]])[0]["type"] as? String) == "output_text")
    }

    @Test func streamCollectsTextUntilCompleted() throws {
        var stream = NativeChatGPT.ResponsesStream()
        #expect(try !stream.consume("event: response.output_text.delta"))
        #expect(try !stream.consume(#"data: {"type":"response.output_text.delta","delta":"Hel"}"#))
        #expect(try !stream.consume(#"data: {"type":"response.output_text.delta","delta":"lo"}"#))
        #expect(try stream.consume(#"data: {"type":"response.completed","response":{"output":[]}}"#))
        #expect(try stream.finish() == "Hello")

        var cut = NativeChatGPT.ResponsesStream()
        _ = try cut.consume(#"data: {"type":"response.output_text.delta","delta":"Hel"}"#)
        #expect(throws: NativeAIError.self) { try cut.finish() }
    }

    @Test func usageLimitReadsAsAPlanLimit() {
        var stream = NativeChatGPT.ResponsesStream()
        do {
            _ = try stream.consume(#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"x"}}}"#)
            Issue.record("expected a failure")
        } catch {
            #expect(error.localizedDescription.contains("limit for Skim"))
        }
    }

    @Test func modelPickerKeepsListedModels() {
        let data = Data(#"{"models":[{"slug":"gpt-a","display_name":"GPT A","visibility":"list"},{"slug":"gpt-hidden","visibility":"hide"}]}"#.utf8)
        #expect(NativeChatGPT.parseModels(data) == [AIModelInfo(id: "gpt-a", displayName: "GPT A")])
    }
}
