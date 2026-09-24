import Foundation
import Testing
@testable import SkimCore

@Test func chatEvidencePreservesShortUnicodeSourceAndZeroBudget() {
    let source = "Καλημέρα κόσμε. Café 👩🏽‍💻 keeps its spelling.\n第二段。"
    #expect(ChatEvidencePolicy.excerpt(text: source, query: "café", maxCharacters: 200) == source)
    #expect(ChatEvidencePolicy.excerpt(text: source, query: "café", maxCharacters: 0).isEmpty)
}

@Test func chatEvidenceSelectsLateFactsAtEachIndependentBudget() {
    let fact = "The lawsuit requires filings by October 12, while the hearing is on October 19."
    let source = "Court officials released an update.\n\n" + String(repeating: "Unrelated background describes ordinary office routines.\n\n", count: 500) + fact
    for budget in [800, 2400, 4200, 12000] {
        let selected = ChatEvidencePolicy.excerpt(text: source, query: "What does the lawsuit require by October 12?", maxCharacters: budget)
        #expect(selected.contains(fact))
        #expect(selected.unicodeScalars.count <= budget)
        for passage in selected.components(separatedBy: "\n…\n") { #expect(source.contains(passage)) }
    }
    #expect(LibraryChatPolicy.queryExcerpt(text: source, query: "lawsuit October", maxCharacters: 800)
        == ChatEvidencePolicy.excerpt(text: source, query: "lawsuit October", maxCharacters: 800))
}

@Test func chatEvidenceFollowupUsesOnlyLatestSubstantiveUserTopic() {
    let query = ChatEvidencePolicy.retrievalQuery(query: "Why does it matter?",
        priorUserQueries: ["Find quasar reports", "Find neutrino evidence", "Explain it briefly"],
        referenceText: "Neutrino evidence is discussed here.")
    #expect(query.contains("neutrino"))
    #expect(!query.contains("quasar"))
    #expect(ChatEvidencePolicy.retrievalQuery(query: "Find quasar reports", priorUserQueries: ["Find neutrino"], referenceText: "") == "Find quasar reports")
}

@Test func chatEvidenceKeepsLateAnswerWhenLeadAlreadyNamesQuestion() {
    let fact = "The lawsuit deadline is October 12."
    let source = "The deadline for the lawsuit was announced.\n\n" + String(repeating: "Ordinary background.\n\n", count: 500) + fact
    let result = ChatEvidencePolicy.excerpt(text: source, query: "What is the deadline for the lawsuit?", maxCharacters: 2400)
    #expect(result.contains(fact))
}

@Test func chatEvidenceFindsTermsWrappedInUnicodePunctuation() {
    for fact in ["The “lawsuit” requires filings on October 12.", "The lawsuit—requires filings on October 12."] {
        let source = "Lead background.\n\n" + String(repeating: "Ordinary background.\n\n", count: 100) + fact
        #expect(ChatEvidencePolicy.excerpt(text: source, query: "lawsuit", maxCharacters: 120).contains(fact))
    }
}

@Test func chatEvidenceMatchesSharedCorpus() throws {
    struct Segment: Decodable { let text: String; let `repeat`: Int? }
    struct Case: Decodable {
        let name: String
        let segments: [Segment]
        let query: String
        let max_scalars: Int
        let contains: [String]
        let exact_source: Bool?
        let min_scalars: Int?
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let cases = try JSONDecoder().decode([Case].self,
        from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/chat-evidence.json")))
    for item in cases {
        let source = item.segments.map { String(repeating: $0.text, count: $0.repeat ?? 1) }.joined()
        let result = ChatEvidencePolicy.excerpt(text: source, query: item.query, maxCharacters: item.max_scalars)
        for expected in item.contains { #expect(result.contains(expected), "\(item.name): \(expected)") }
        #expect(result.unicodeScalars.count <= item.max_scalars, "\(item.name)")
        if let minimum = item.min_scalars { #expect(result.unicodeScalars.count >= minimum, "\(item.name)") }
        if item.exact_source == true { #expect(result == source, "\(item.name)") }
        for passage in result.components(separatedBy: "\n…\n") { #expect(source.contains(passage), "\(item.name)") }
    }
}
