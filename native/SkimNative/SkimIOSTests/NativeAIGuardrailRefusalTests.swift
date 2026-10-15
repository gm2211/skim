import Testing
import Foundation
@testable import Skim

// MARK: - NativeAI.isGuardrailRefusal Tests
//
// Apple's on-device safety filter (Foundation Models) occasionally refuses
// ordinary tech-news content as a false positive, and the raw refusal
// ("Detected content likely to be unsafe") used to leak straight into the UI
// with no actionable next step. `isGuardrailRefusal` detects that refusal so
// callers can retry once with neutralizing instructions before surfacing a
// friendly error.
//
// The typed `LanguageModelSession.GenerationError.guardrailViolation` branch
// requires FoundationModels/iOS 26+ to construct, so it isn't exercised here.
// These tests cover the string-fallback branch, which matches any error whose
// `localizedDescription` mentions "unsafe" or "guardrail" — this is also the
// shape Foundation Models' raw NSError actually takes in practice.
@Suite("NativeAI.isGuardrailRefusal")
struct NativeAIGuardrailRefusalTests {

    @Test func matchesUnsafeInDescription() {
        let error = NSError(
            domain: "FoundationModelsErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Detected content likely to be unsafe."]
        )
        #expect(NativeAI.isGuardrailRefusal(error) == true)
    }

    @Test func matchesUnsafeCaseInsensitively() {
        let error = NSError(
            domain: "FoundationModelsErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "DETECTED CONTENT LIKELY TO BE UNSAFE"]
        )
        #expect(NativeAI.isGuardrailRefusal(error) == true)
    }

    @Test func matchesGuardrailInDescription() {
        let error = NSError(
            domain: "FoundationModelsErrorDomain",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The request was blocked by a guardrail."]
        )
        #expect(NativeAI.isGuardrailRefusal(error) == true)
    }

    @Test func unrelatedErrorDoesNotMatch() {
        let error = NSError(
            domain: "FoundationModelsErrorDomain",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "The context window was exceeded."]
        )
        #expect(NativeAI.isGuardrailRefusal(error) == false)
    }

    @Test func genericNativeAIErrorDoesNotMatch() {
        let error = NativeAIError.unavailable("Apple Intelligence is not available: this device is not eligible.")
        #expect(NativeAI.isGuardrailRefusal(error) == false)
    }

    @Test func nativeAIErrorWithUnsafeMessageMatches() {
        // Guards the case where the raw refusal text has already been wrapped
        // in a NativeAIError somewhere upstream — the string fallback should
        // still recognize it regardless of the concrete error type.
        let error = NativeAIError.unavailable("Detected content likely to be unsafe")
        #expect(NativeAI.isGuardrailRefusal(error) == true)
    }
}

// MARK: - AI Inbox ratings

// A ratings response cut off by max_tokens used to fail the whole batch with
// "The AI model didn't return usable ratings". The entries the model finished
// are still good ratings.
@Suite("NativeAI.parseInboxRatings")
struct NativeAIInboxRatingsParseTests {
    @Test func truncatedResponseKeepsTheFinishedEntries() {
        let raw = #"{"triage":[{"id":1,"importance":4,"relevance":3,"reason":"Rate cut {surprise}"},{"id":2,"importance":2,"relevance":5,"reason":"Matches \"AI\" interest"},{"id":3,"importance":5,"rel"#
        let ratings = NativeAI.parseInboxRatings(raw, count: 3)
        #expect(ratings.keys.sorted() == [1, 2])
        #expect(ratings[1] == NativeAI.InboxRating(importance: 4, relevance: 3, reason: "Rate cut {surprise}"))
        #expect(ratings[2]?.relevance == 5)
    }

    @Test func fencedTruncatedResponseIsSalvaged() {
        let raw = "```json\n{\"triage\":[{\"id\":\"1\",\"priority\":4,\"reason\":\"x\"},{\"id\":2"
        #expect(NativeAI.parseInboxRatings(raw, count: 2).keys.sorted() == [1])
    }

    @Test func completeResponseStillParses() {
        let raw = #"{"triage":[{"id":1,"importance":3,"relevance":3,"reason":"ok"}]}"#
        #expect(NativeAI.parseInboxRatings(raw, count: 1).count == 1)
    }

    @Test func proseWithoutJSONHasNoRatings() {
        #expect(NativeAI.parseInboxRatings("I can't rate these.", count: 2).isEmpty)
    }

    @Test func budgetLeavesRoomForReasons() {
        #expect(NativeAI.inboxRatingsMaxTokens(count: 20) == 1900)
    }
}
