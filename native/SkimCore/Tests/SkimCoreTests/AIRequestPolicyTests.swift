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
