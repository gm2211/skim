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
