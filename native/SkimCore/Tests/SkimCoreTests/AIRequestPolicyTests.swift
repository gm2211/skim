import Foundation
import Testing
@testable import SkimCore

@Test func chatOverridesMatchDesktopAndKeepOtherSettings() {
    let base = AISettings(provider: "openai", apiKey: "test-main", model: "main", localModelPath: "old/local-model", endpoint: "https://main.test", chatProvider: "mlx", chatModel: "chat", chatApiKey: "test-chat", chatEndpoint: "https://chat.test", localChatWebSearch: true)
    let resolved = AIRequestPolicy.chatSettings(base)
    #expect(resolved.provider == "mlx")
    #expect(resolved.model == "chat")
    #expect(resolved.localModelPath == nil)
    #expect(resolved.apiKey == "test-chat")
    #expect(resolved.endpoint == "https://chat.test")
    #expect(resolved.localChatWebSearch == true)
    var same = base
    same.chatProvider = "same"
    #expect(AIRequestPolicy.chatSettings(same).apiKey == "test-main")
    #expect(AIRequestPolicy.chatSettings(same).endpoint == "https://main.test")
    #expect(AIRequestPolicy.chatSettings(same).model == "chat")
    same.chatProvider = "anthropic"
    same.chatApiKey = nil
    same.chatEndpoint = nil
    #expect(AIRequestPolicy.chatSettings(same).apiKey == "test-main")
    #expect(AIRequestPolicy.chatSettings(same).endpoint == "https://main.test")
    #expect(base.provider == "openai")
}

@Test func summaryPresetsIgnoreStaleCustomCount() {
    for (length, expected) in [("short",30),("medium",150),("long",300),("custom",87),("unknown",30)] {
        #expect(AIRequestPolicy.summaryWordCount(AISettings(summaryLength: length, summaryCustomWordCount: 87)) == expected)
    }
    #expect(AIRequestPolicy.summaryWordCount(AISettings(summaryLength: "custom", summaryCustomWordCount: -1)) == 30)
}

@Test func generatedSummaryIsSeparateBoundedUntrustedContext() {
    #expect(AIRequestPolicy.generatedSummaryContext(nil).isEmpty)
    #expect(AIRequestPolicy.generatedSummaryContext(" \n ").isEmpty)
    let context = AIRequestPolicy.generatedSummaryContext(String(repeating: "é", count: 4000))
    #expect(context.contains("untrusted model output, not source evidence"))
    #expect(context.contains("verify its claims against the article"))
    #expect(context.filter { $0 == "é" }.count == 3000)
}

@Test func summaryEvidenceFingerprintChangesWithFullReaderBodyAndEvictsOnlyArticleVariants() {
    let teaser = AIRequestPolicy.summarySourceFingerprint("Laptop review\nShort teaser")
    let full = AIRequestPolicy.summarySourceFingerprint("Laptop review\nBattery lasted nine hours in testing.")
    #expect(teaser != full)
    #expect(full == AIRequestPolicy.summarySourceFingerprint("Laptop review\nBattery lasted nine hours in testing."))
    let keys = ["a|summary-v2|" + teaser, "a|summary-v2|" + full, "a|legacy-model", "ab|summary-v2|" + full, "b|summary-v2|" + teaser]
    let removed = AIRequestPolicy.summaryCacheKeys(for: "a", among: keys)
    #expect(removed == Array(keys.prefix(3)))
    #expect(keys.filter { !removed.contains($0) } == Array(keys.suffix(2)))
}

@Test func summaryStyleMatchesSharedCorpusIncludingAliasesAndDefaults() throws {
    struct Fixture: Decodable {
        struct Entry: Decodable { var tone: String?; var style: String }
        var common: String
        var cases: [Entry]
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(
        contentsOf: root.appendingPathComponent("shared/fixtures/summary-style.json")))
    for entry in fixture.cases {
        #expect(AIRequestPolicy.summaryInstructions(AISettings(summaryTone: entry.tone)) == entry.style + " " + fixture.common)
    }
    #expect(AIRequestPolicy.summaryInstructions(AISettings(summaryTone: "descriptive")) == AIRequestPolicy.summaryInstructions(AISettings(summaryTone: "detailed")))
    #expect(AIRequestPolicy.summaryInstructions(AISettings(summaryTone: "unknown")) == AIRequestPolicy.summaryInstructions(AISettings(summaryTone: "concise")))
}

@Test func nativeSummaryCompositionPreservesPlainTextWordCountAndAppendedCustomInstructions() {
    let settings = AISettings(summaryTone: "technical", summaryCustomPrompt: "  Focus on dates.\n  ")
    let style = AIRequestPolicy.summaryInstructions(AISettings(summaryTone: "technical"))
    #expect(AIRequestPolicy.summaryInstructions(settings, wordCount: 87) == style
        + " Write approximately 87 words. Output only the summary — no preamble, no restating the title, no metadata."
        + "\n\nUser summary instructions:\nFocus on dates.")
    #expect(AIRequestPolicy.summaryInstructions(settings) == style + "\n\nUser summary instructions:\nFocus on dates.")
    #expect(AIRequestPolicy.summaryInstructions(AISettings(summaryTone: "technical", summaryCustomPrompt: " \n ")) == style)
}

@Test func summaryPlanMatchesSharedCorpusAndBounds() throws {
    struct Entry: Decodable {
        struct Plan: Decodable {
            var word_count: Int; var bullet_min: Int; var bullet_max: Int
            var bullet_max_tokens: Int; var full_max_tokens: Int
        }
        var length: String?; var custom_words: Int; var valid_custom: Bool; var plan: Plan
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let entries = try JSONDecoder().decode([Entry].self, from: Data(
        contentsOf: root.appendingPathComponent("shared/fixtures/summary-plan.json")))
    #expect(AIRequestPolicy.summaryWordRange == 20...1000)
    for entry in entries {
        let actual = AIRequestPolicy.summaryPlan(AISettings(summaryLength: entry.length, summaryCustomWordCount: entry.custom_words))
        #expect(actual.wordCount == entry.plan.word_count)
        #expect(actual.bulletMin == entry.plan.bullet_min)
        #expect(actual.bulletMax == entry.plan.bullet_max)
        #expect(actual.bulletMaxTokens == entry.plan.bullet_max_tokens)
        #expect(actual.fullMaxTokens == entry.plan.full_max_tokens)
        #expect(AIRequestPolicy.validSummaryWordCount(entry.custom_words) == entry.valid_custom)
    }
}

@Test func explicitSummaryCountEditControlsPromptAndBudgetWithoutChangingOtherSettings() {
    let base = AISettings(provider: "mlx", model: "test/model", summaryLength: "short", summaryTone: "technical", summaryCustomWordCount: 30, mlxMaxTokens: 99)
    for (count, length, budget) in [(30,"short",256),(150,"medium",1200),(300,"long",2400),(600,"custom",1328),(20,"custom",168),(1000,"custom",2128)] {
        let edited = AIRequestPolicy.summarySettings(base, wordCount: count)
        #expect(edited.summaryLength == length)
        #expect(edited.summaryCustomWordCount == count)
        #expect(edited.provider == base.provider && edited.model == base.model && edited.mlxMaxTokens == 99)
        let plan = AIRequestPolicy.summaryPlan(edited)
        #expect(plan.wordCount == count && plan.fullMaxTokens == budget)
        #expect(AIRequestPolicy.summaryInstructions(edited, wordCount: plan.wordCount).contains("Write approximately \(count) words."))
    }
    #expect(base.summaryLength == "short" && base.summaryCustomWordCount == 30)
}

@Test func invalidStoredSummaryCountsAreBoundedWithoutMutationAndHaveDistinctBudgetIdentity() {
    let short = AIRequestPolicy.summaryPlan(AISettings(summaryLength: "short"))
    let custom30 = AIRequestPolicy.summaryPlan(AISettings(summaryLength: "custom", summaryCustomWordCount: 30))
    #expect(short.wordCount == custom30.wordCount)
    #expect(short.fullMaxTokens == 256 && custom30.fullMaxTokens == 188)
    #expect(short.cacheIdentity != custom30.cacheIdentity)
    for invalid in [Int.min, -1, 0, 1, 19, 1001, Int.max] {
        let stored = AISettings(summaryLength: "custom", summaryCustomWordCount: invalid)
        #expect(AIRequestPolicy.summaryPlan(stored) == short)
        #expect(AIRequestPolicy.summaryPlan(stored).cacheIdentity == short.cacheIdentity)
        #expect(stored.summaryCustomWordCount == invalid && stored.summaryLength == "custom")
        let edited = AIRequestPolicy.summarySettings(stored, wordCount: invalid)
        #expect(edited.summaryLength == "short" && edited.summaryCustomWordCount == 30)
    }
}

@Test func publicationContextUsesUTCAndKeepsUnknownExplicit() throws {
    let date = try #require(ISO8601DateFormatter().date(from: "2026-09-24T00:30:00Z"))
    #expect(AIRequestPolicy.publicationContext(date) == "Publication time (UTC): 2026-09-24T00:30:00Z (article metadata, not the event time)")
    #expect(AIRequestPolicy.publicationContext(nil).contains("unknown"))
    #expect(AIRequestPolicy.publicationContext(Date(timeIntervalSince1970: .nan)).contains("unknown"))
}
