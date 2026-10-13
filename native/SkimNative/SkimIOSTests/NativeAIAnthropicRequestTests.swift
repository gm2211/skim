import Testing
import Foundation
import SkimCore
@testable import Skim

// Claude 4.7+ and 5-series models answer a `temperature` field with a 400, which
// surfaced as "Claude request failed (400). Try again." on Catch-up with
// claude-sonnet-5-5. These tests pin which models get the field and that a 400
// shows the API's reason.
@Suite("NativeAI Anthropic request")
struct NativeAIAnthropicRequestTests {

    private func payload(model: String, temperature: Double? = 0) throws -> [String: Any] {
        let request = try NativeAI.buildAnthropicRequestFull(
            settings: AISettings(provider: "anthropic", model: model),
            accessToken: "test-token",
            isSubscription: false,
            instructions: "system",
            messages: [["role": "user", "content": "hi"]],
            maxTokens: 100,
            temperature: temperature
        )
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test(arguments: [
        "claude-sonnet-5-5", "claude-opus-5-5", "claude-sonnet-5", "claude-opus-5",
        "claude-fable-5-1", "claude-haiku-5-5", "claude-opus-4-7", "claude-opus-4-8",
        "claude-some-future-model"
    ])
    func newerModelsGetNoTemperature(model: String) throws {
        let body = try payload(model: model)
        #expect(body["model"] as? String == model)
        #expect(body["temperature"] == nil)
    }

    @Test(arguments: [
        "claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5", "claude-sonnet-4-20250514",
        "claude-3-5-sonnet-20241022", "claude-3-haiku-20240307"
    ])
    func olderModelsKeepTheirTemperature(model: String) throws {
        let body = try payload(model: model, temperature: 0.3)
        #expect(body["temperature"] as? Double == 0.3)
    }

    @Test func badRequestShowsTheAPIReason() {
        let data = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"temperature is not supported for this model"}}"#.utf8)
        let message = NativeAI.friendlyErrorMessage(status: 400, data: data, provider: "Claude subscription")
        #expect(message == "Claude couldn't run this request: temperature is not supported for this model")
    }

    @Test func badRequestWithoutAReasonKeepsTheStatus() {
        let message = NativeAI.friendlyErrorMessage(status: 400, data: Data("oops".utf8), provider: "Claude API")
        #expect(message == "Claude request failed (400). Try again.")
    }

    // A subscription token whose system prompt doesn't open with the Claude Code identity
    // gets a 429 "Error" on Sonnet and Opus, shown as "Claude is rate-limited" to someone
    // with no limits hit (Ask about this story on claude-sonnet-5-5).
    @Test func subscriptionRequestsOpenWithTheClaudeCodeIdentity() throws {
        let request = try NativeAI.buildAnthropicRequestFull(
            settings: AISettings(provider: "claude-subscription", model: "claude-sonnet-5-5"),
            accessToken: "oauth-token",
            isSubscription: true,
            instructions: "Answer about this story.",
            messages: [["role": "user", "content": "Can it?"]],
            maxTokens: 100
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token")
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try #require(payload["system"] as? [[String: Any]])
        #expect(system.compactMap { $0["text"] as? String } == [
            "You are Claude Code, Anthropic's official CLI for Claude.",
            "Answer about this story."
        ])
    }

    @Test func apiKeyRequestsKeepAPlainSystemString() throws {
        let body = try payload(model: "claude-sonnet-5-5")
        #expect(body["system"] as? String == "system")
    }

    @Test func bare429IsNotCalledARateLimit() {
        let data = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"Error"}}"#.utf8)
        let message = NativeAI.friendlyErrorMessage(status: 429, data: data, provider: "Claude subscription")
        #expect(!message.contains("rate-limited"))
        #expect(message.hasPrefix("Claude turned down this request"))
    }

    @Test func real429WithRetryAfterSaysWhenToRetry() {
        let data = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"Error"}}"#.utf8)
        let message = NativeAI.friendlyErrorMessage(status: 429, data: data, provider: "Claude subscription", retryAfter: "150")
        #expect(message == "Claude is rate-limited right now. Try again in 3 minutes.")
    }

    @Test func real429WithAReasonShowsIt() {
        let data = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed your account's rate limit."}}"#.utf8)
        let message = NativeAI.friendlyErrorMessage(status: 429, data: data, provider: "Claude subscription")
        #expect(message == "Claude is rate-limited right now. Wait a bit and try again. (This request would exceed your account's rate limit.)")
    }
}
