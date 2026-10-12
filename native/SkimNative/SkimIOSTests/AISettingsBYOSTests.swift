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
