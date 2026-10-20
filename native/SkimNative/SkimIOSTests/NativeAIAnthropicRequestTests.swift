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

    // claude-sonnet-5-5 thinks before answering by default, and that thinking counts
    // against max_tokens. Ask Skim's 850-token budget could go entirely on thinking,
    // which came back as "The Claude response was empty." on iPhone.
    @Test(arguments: ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-sonnet-5", "claude-fable-5-1"])
    func modelsThatThinkByDefaultGetLowEffortAndRoomToAnswer(model: String) throws {
        let body = try payload(model: model)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(body["max_tokens"] as? Int == NativeAI.anthropicThinkingMaxTokensFloor)
    }

    @Test(arguments: ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5", "claude-3-5-sonnet-20241022", "claude-some-future-model"])
    func olderModelsGetNoEffortAndKeepTheirBudget(model: String) throws {
        let body = try payload(model: model)
        #expect(body["output_config"] == nil)
        #expect(body["max_tokens"] as? Int == 100)
    }

    @Test func emptyAnswerSaysWhyWhenItCan() {
        #expect(NativeAI.anthropicEmptyResponseMessage(stopReason: "max_tokens").hasPrefix("Claude ran out of room"))
        #expect(NativeAI.anthropicEmptyResponseMessage(stopReason: "refusal").hasPrefix("Claude declined"))
        #expect(NativeAI.anthropicEmptyResponseMessage(stopReason: "end_turn") == "The Claude response was empty.")
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

    // Chat answers stream: the events are rebuilt into the message a
    // non-streaming request returns, so the tool loop reads them unchanged.
    @Test func streamRebuildsTextThinkingAndToolCalls() throws {
        let lines = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"stop_reason":null}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Need the web."}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me "}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"check."}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu_1","name":"web_search","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"sk"}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"im\"}"}}"#,
            #"data: {"type":"content_block_stop","index":2}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#,
            #"data: {"type":"message_stop"}"#
        ]
        var stream = NativeAI.AnthropicMessageStream()
        var shown = ""
        for line in lines {
            if let delta = try stream.consume(line) { shown += delta }
        }
        #expect(shown == "Let me check.")
        #expect(stream.isComplete)

        let finished = try stream.finish()
        let message = try #require(JSONSerialization.jsonObject(with: finished) as? [String: Any])
        #expect(message["stop_reason"] as? String == "tool_use")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["thinking", "text", "tool_use"])
        #expect(content[0]["thinking"] as? String == "Need the web.")
        #expect(content[0]["signature"] as? String == "sig")
        #expect(content[1]["text"] as? String == "Let me check.")
        #expect((content[2]["input"] as? [String: Any])?["query"] as? String == "skim")
    }

    @Test func streamCutOffOrErroredThrows() throws {
        var cut = NativeAI.AnthropicMessageStream()
        _ = try cut.consume(#"data: {"type":"message_start","message":{"content":[]}}"#)
        #expect(throws: NativeAIError.self) { try cut.finish() }

        var failed = NativeAI.AnthropicMessageStream()
        #expect(throws: NativeAIError.self) {
            try failed.consume(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    @Test func openAIStreamCollectsContentDeltas() throws {
        var stream = NativeAI.OpenAIChatStream(provider: "OpenAI")
        var shown = ""
        for line in [
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            "",
            #"data: {"choices":[{"delta":{"content":" there"}}]}"#
        ] {
            let (delta, done) = try stream.consume(line)
            shown += delta ?? ""
            #expect(!done)
        }
        let end = try stream.consume("data: [DONE]")
        #expect(end.done)
        #expect(shown == "Hello there")
        let finished = try stream.finish()
        #expect(finished == "Hello there")
    }

    @Test func openAIRequestAsksToStreamOnlyWhenStreaming() throws {
        let settings = AISettings(provider: "openai", apiKey: "k", model: "gpt-test")
        func body(_ stream: Bool) throws -> [String: Any] {
            let request = try NativeAI.buildOpenAICompatibleRequest(
                settings: settings, instructions: "s", prompt: "p", maxTokens: 10, stream: stream)
            let data = try #require(request.httpBody)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let streaming = try body(true)
        let plain = try body(false)
        #expect(streaming["stream"] as? Bool == true)
        #expect(plain["stream"] == nil)
    }
}
