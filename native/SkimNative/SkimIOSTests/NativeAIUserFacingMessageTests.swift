import Testing
import Foundation
@testable import Skim

// MARK: - NativeAI.userFacingMessage Tests
//
// The Briefing used to print `"\(error)"` for a failed edition, so an Apple
// on-device failure reached the page as a raw dump ("The operation couldn't be
// completed. (FoundationModels.LanguageModelSession.GenerationError error 2.)").
// `userFacingMessage` maps every error to one sentence a reader can act on; the
// typed GenerationError branches need iOS 26+ to construct, so these cover the
// generic paths.
@Suite("NativeAI.userFacingMessage")
struct NativeAIUserFacingMessageTests {

    @Test func keepsAlreadyFriendlyProviderMessages() {
        let error = NativeAIError.unavailable("Claude is busy right now. Try again in a moment.")
        #expect(NativeAI.userFacingMessage(error) == "Claude is busy right now. Try again in a moment.")
    }

    @Test func asksForSignInAgainWhenTheSessionExpired() {
        #expect(NativeAI.userFacingMessage(NativeAIError.requiresReauthentication).contains("Sign in again"))
    }

    @Test func mapsAGuardrailRefusalToItsOwnAdvice() {
        let error = NSError(
            domain: "FoundationModelsErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Detected content likely to be unsafe."]
        )
        #expect(NativeAI.userFacingMessage(error) == NativeAI.guardrailRefusalMessage)
    }

    @Test func replacesARawFoundationModelsDumpWithAdvice() {
        let error = NSError(
            domain: "FoundationModels.LanguageModelSession.GenerationError",
            code: 2,
            userInfo: [:]
        )
        let message = NativeAI.userFacingMessage(error)
        #expect(!message.lowercased().contains("foundationmodels"))
        #expect(!message.contains("error 2"))
        #expect(message.contains("AI Settings"))
    }

    @Test func tellsTheReaderWhenTheDeviceIsOffline() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(NativeAI.userFacingMessage(error).contains("No internet connection"))
    }

    @Test func rejectsDebugTextAsPresentable() {
        #expect(NativeAI.isPresentableErrorText("The AI provider was busy. Try again.") == true)
        #expect(NativeAI.isPresentableErrorText("short") == false)
        #expect(NativeAI.isPresentableErrorText("Error Domain=NSURLErrorDomain Code=-1009") == false)
        #expect(NativeAI.isPresentableErrorText("The operation couldn’t be completed. (x error 2.)") == false)
    }
}
