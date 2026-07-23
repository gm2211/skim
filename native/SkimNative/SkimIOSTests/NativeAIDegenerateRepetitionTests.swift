import Testing
import Foundation
@testable import Skim

// MARK: - NativeAI.degenerateRepetitionTrim Tests
//
// Guards Foundation Models (on-device) output against the degenerate
// repetition loops small models occasionally produce — e.g. before the
// stochastic sampling fix (PR #70), Foundation Models once emitted
// "The protest was held in the 21st century." dozens of times in a single
// summary. Stochastic sampling reduces this but doesn't eliminate it, so
// this guard trims degenerate output defensively before it reaches the UI.
@Suite("NativeAI.degenerateRepetitionTrim")
struct NativeAIDegenerateRepetitionTests {

    @Test func cleanTextIsUntouched() {
        let text = "The city council approved the new park budget. Residents welcomed the plan. Construction begins in spring."
        let (result, wasDegenerate) = NativeAI.degenerateRepetitionTrim(text)
        #expect(wasDegenerate == false)
        #expect(result == text)
    }

    @Test func sentenceLoopIsTrimmed() {
        let intro = "Protesters gathered downtown to voice their concerns. Organizers say turnout exceeded expectations."
        let repeated = String(repeating: "The protest was held in the 21st century. ", count: 12)
        let text = intro + " " + repeated
        let (result, wasDegenerate) = NativeAI.degenerateRepetitionTrim(text)
        #expect(wasDegenerate == true)
        #expect(result.contains(intro))
        #expect(!result.contains("The protest was held in the 21st century. The protest was held in the 21st century. The protest was held in the 21st century."))
    }

    @Test func alternatingSentenceLoopIsTrimmed() {
        // Not 3-in-a-row identical, but the tail collapses to <= 2 unique
        // sentences across a window of >= 5.
        let intro = "The summit covered several policy areas. Delegates discussed trade first."
        let a = "Talks will continue tomorrow."
        let b = "No agreement was reached today."
        let tail = Array(repeating: [a, b], count: 4).flatMap { $0 }.joined(separator: " ")
        let text = intro + " " + tail
        let (result, wasDegenerate) = NativeAI.degenerateRepetitionTrim(text)
        #expect(wasDegenerate == true)
        #expect(result.contains(intro))
    }

    @Test func substringLoopIsTrimmed() {
        // No sentence delimiters at all — a raw repeating token loop.
        let intro = "Summary begins here with real content worth keeping"
        let unit = "looplooploop" // 12 chars
        let text = intro + String(repeating: unit, count: 6)
        let (result, wasDegenerate) = NativeAI.degenerateRepetitionTrim(text)
        #expect(wasDegenerate == true)
        #expect(result.contains(intro))
        #expect(result.hasSuffix(unit))
        #expect(!result.hasSuffix(unit + unit))
    }

    @Test func allRepetitionInputKeepsOneOccurrence() {
        let sentence = "The protest was held in the 21st century."
        let text = Array(repeating: sentence, count: 10).joined(separator: " ")
        let (result, wasDegenerate) = NativeAI.degenerateRepetitionTrim(text)
        #expect(wasDegenerate == true)
        #expect(!result.isEmpty)
        #expect(result.contains(sentence))
    }

    @Test func emptyInputStaysEmpty() {
        let (result, wasDegenerate) = NativeAI.degenerateRepetitionTrim("")
        #expect(wasDegenerate == false)
        #expect(result.isEmpty)
    }

    @Test func shortCleanTextIsUnaffected() {
        // Fewer than 3 sentence chunks — should never trigger the sentence-based
        // rules and should be returned unchanged.
        let text = "Just one short sentence."
        let (result, wasDegenerate) = NativeAI.degenerateRepetitionTrim(text)
        #expect(wasDegenerate == false)
        #expect(result == text)
    }
}
