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
}
