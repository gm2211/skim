import Testing
import Foundation
import SkimCore
@testable import Skim
import UIKit

/// The offline fallback's decisions and the picture cache's budget. Which
/// on-device model is ready depends on the device, so the reroute is injected.
@Suite("Offline support")
struct OfflineSupportTests {
    private static func localModel(_ ai: AISettings) -> AISettings? {
        var local = ai
        local.provider = "foundation-models"
        local.model = nil
        local.apiKey = nil
        return local
    }

    @Test func cloudProvidersNeedAConnectionAndLocalOnesDoNot() {
        for provider in ["anthropic", "claude-subscription", "chatgpt-subscription", "openai", "xai", "openrouter"] {
            #expect(OfflineAIFallback.needsConnection(AISettings(provider: provider)), "\(provider)")
        }
        for provider in ["foundation-models", "mlx", "none"] {
            #expect(!OfflineAIFallback.needsConnection(AISettings(provider: provider)), "\(provider)")
        }
    }

    @Test func customEndpointsOnTheLocalNetworkNeedNoConnection() {
        #expect(!OfflineAIFallback.needsConnection(AISettings(provider: "custom", endpoint: "http://192.168.1.20:8080/v1")))
        #expect(!OfflineAIFallback.needsConnection(AISettings(provider: "custom", endpoint: "http://studio.local:1234")))
        #expect(OfflineAIFallback.needsConnection(AISettings(provider: "custom", endpoint: "https://llm.example.com/v1")))
        #expect(!OfflineAIFallback.isLocalNetworkHost("172.32.0.1"))
        #expect(OfflineAIFallback.isLocalNetworkHost("172.20.0.1"))
    }

    @Test func connectivityErrorsAreRecognisedButOthersAreNot() {
        #expect(OfflineAIFallback.isConnectivityError(URLError(.notConnectedToInternet)))
        #expect(OfflineAIFallback.isConnectivityError(URLError(.timedOut)))
        let wrapped = NSError(domain: "Skim", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.cannotFindHost)])
        #expect(OfflineAIFallback.isConnectivityError(wrapped))
        #expect(!OfflineAIFallback.isConnectivityError(URLError(.badServerResponse)))
        #expect(!OfflineAIFallback.isConnectivityError(NativeAIError.unavailable("rate limited")))
    }

    @Test func offlineRequestsGoStraightToTheOnDeviceModel() async throws {
        let settings = AppSettings(ai: AISettings(provider: "claude-subscription", model: "claude-sonnet-5-5"))
        let provider = try await OfflineAIFallback.run(settings, offline: true, local: Self.localModel) { $0.ai.provider }
        #expect(provider == "foundation-models")
        let online = try await OfflineAIFallback.run(settings, offline: false, local: Self.localModel) { $0.ai.provider }
        #expect(online == "claude-subscription")
    }

    @Test func aRequestThatCannotReachTheProviderIsRetriedOnDevice() async throws {
        let settings = AppSettings(ai: AISettings(provider: "openai", apiKey: "sk", model: "gpt-5"))
        var tried: [String] = []
        let answer = try await OfflineAIFallback.run(settings, offline: false, local: Self.localModel) { attempt in
            tried.append(attempt.ai.provider)
            if attempt.ai.provider == "openai" { throw URLError(.notConnectedToInternet) }
            return "local answer"
        }
        #expect(answer == "local answer")
        #expect(tried == ["openai", "foundation-models"])
    }

    @Test func otherFailuresAreNotRetried() async {
        let settings = AppSettings(ai: AISettings(provider: "openai", apiKey: "sk"))
        var attempts = 0
        do {
            _ = try await OfflineAIFallback.run(settings, offline: false, local: Self.localModel) { _ -> String in
                attempts += 1
                throw NativeAIError.unavailable("Bad key")
            }
            Issue.record("expected the provider's error")
        } catch {
            #expect(error is NativeAIError)
        }
        #expect(attempts == 1)
    }

    @Test func pictureCacheKeepsRecentlyUsedWithinBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = OfflineImageCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = URL(string: "https://example.com/old.jpg")!
        let recent = URL(string: "https://example.com/recent.jpg")!
        cache.store(Data(repeating: 1, count: 1_000), for: old)
        cache.store(Data(repeating: 2, count: 1_000), for: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: cache.fileURL(for: old).path)

        cache.trim(toBytes: 1_500)

        #expect(!cache.contains(old))
        #expect(cache.data(for: recent)?.count == 1_000)
        #expect(cache.totalBytes() == 1_000)
    }
}
