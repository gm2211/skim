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
