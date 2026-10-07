import Testing
@testable import SkimChatEvalCore

private let necroprintingCase = ChatEvalCase(
    name: "necroprinting",
    title: "Engineers Turn a Dead Mosquito Into the World's Finest 3D-Printing Nozzle",
    feed: "Synthetic Science Wire",
    body: "synthetic test article body",
    question: "Making nozzles out of dead things?",
    mustContainAny: [["mosquito", "proboscis"], ["nozzle"]],
    mustNotContain: ["here's my response", "**Summary", "Summary:", "feedstock"],
    firstSentenceMustContainAny: ["mosquito", "proboscis", "yes"]
)

// MARK: - The real bd skim-p9ol bad reply must fail

@Test func scorerFailsRealBuggyNecroprintingReply() {
    // Verbatim from ChatAnswerCleanupTests.chatAnswerCleanupStripsRealBuggyReply:
    // preamble + bold "Summary:" header in front of a vague,
    // question-ignoring answer that never actually says "mosquito",
    // "proboscis", or "nozzle" and instead uses the word this fixture
    // treats as a smell ("feedstock").
    let text = "Okay, here's my response:\n\n**Summary:**\n\n3D-printed materials are increasingly being explored utilizing biological components as the primary feedstock."
    let result = ChatAnswerScorer.score(answer: text, testCase: necroprintingCase)
    #expect(!result.passed)
    let rules = Set(result.failures.map(\.rule))
    #expect(rules.contains("mustContainAny"), "should flag the missing mosquito/proboscis/nozzle vocabulary")
    #expect(rules.contains("mustNotContain"), "should flag the preamble, the Summary header, and 'feedstock'")
    #expect(rules.contains("firstSentenceMustContainAny"), "first sentence is the preamble, not the answer")
}

@Test func scorerPassesGoodNecroprintingReply() {
    let text = "Yes — researchers mounted a dead mosquito's proboscis in a steel collar and used it as an ultra-fine 3D-printing nozzle, extruding lines as narrow as 400 nanometers."
    let result = ChatAnswerScorer.score(answer: text, testCase: necroprintingCase)
    #expect(result.passed)
    #expect(result.failures.isEmpty)
}

// MARK: - mustContainAny: every synonym group required

@Test func mustContainAnyRequiresEveryGroupToMatch() {
    let testCase = ChatEvalCase(
        name: "x", title: "t", feed: "f", body: "b", question: "q",
        mustContainAny: [["alpha", "beta"], ["gamma"]],
        mustNotContain: []
    )
    #expect(!ChatAnswerScorer.score(answer: "This mentions alpha only.", testCase: testCase).passed)
    #expect(ChatAnswerScorer.score(answer: "This mentions BETA and gamma.", testCase: testCase).passed)
}

@Test func mustContainAnyMatchesCaseInsensitively() {
    let testCase = ChatEvalCase(
        name: "x", title: "t", feed: "f", body: "b", question: "q",
        mustContainAny: [["Mosquito"]],
        mustNotContain: []
    )
    #expect(ChatAnswerScorer.score(answer: "the MOSQUITO's proboscis", testCase: testCase).passed)
}

// MARK: - mustNotContain

@Test func mustNotContainIsCaseInsensitive() {
    let testCase = ChatEvalCase(
        name: "x", title: "t", feed: "f", body: "b", question: "q",
        mustContainAny: [], mustNotContain: ["forbidden"]
    )
    #expect(!ChatAnswerScorer.score(answer: "This is FORBIDDEN content.", testCase: testCase).passed)
    #expect(ChatAnswerScorer.score(answer: "This is fine.", testCase: testCase).passed)
}

@Test func mustNotContainReportsEveryBannedPhraseFound() {
    let testCase = ChatEvalCase(
        name: "x", title: "t", feed: "f", body: "b", question: "q",
        mustContainAny: [], mustNotContain: ["one", "two"]
    )
    let result = ChatAnswerScorer.score(answer: "Contains one and two.", testCase: testCase)
    #expect(result.failures.filter { $0.rule == "mustNotContain" }.count == 2)
}

// MARK: - firstSentenceMustContainAny

@Test func firstSentenceRuleOnlyLooksAtTheFirstSentence() {
    let testCase = ChatEvalCase(
        name: "x", title: "t", feed: "f", body: "b", question: "q",
        mustContainAny: [], mustNotContain: [], firstSentenceMustContainAny: ["yes"]
    )
    let failing = ChatAnswerScorer.score(answer: "The nozzle works well. Yes, it does.", testCase: testCase)
    #expect(!failing.passed)
    #expect(failing.failures.contains { $0.rule == "firstSentenceMustContainAny" })

    let passing = ChatAnswerScorer.score(answer: "Yes, the nozzle works well.", testCase: testCase)
    #expect(passing.passed)
}

@Test func firstSentenceHelperStripsLeadingListMarker() {
    #expect(ChatAnswerScorer.firstSentence(of: "- Yes, it works.") == "Yes, it works.")
    #expect(ChatAnswerScorer.firstSentence(of: "1. First step done.") == "First step done.")
    #expect(ChatAnswerScorer.firstSentence(of: "No terminator") == "No terminator")
}

// MARK: - sentence counting / maxSentences

@Test func sentenceCountingCountsTerminatorsFollowedByWhitespaceOrEnd() {
    #expect(ChatAnswerScorer.sentenceCount("One. Two! Three?") == 3)
    #expect(ChatAnswerScorer.sentenceCount("No terminator here") == 1)
    #expect(ChatAnswerScorer.sentenceCount("") == 0)
}

@Test func sentenceCountingTreatsMarkdownListItemsAsUnits() {
    let list = "- Step one\n- Step two\n- Step three"
    #expect(ChatAnswerScorer.sentenceCount(list) == 3)

    let numbered = "1. First\n2. Second\n3. Third\n4. Fourth"
    #expect(ChatAnswerScorer.sentenceCount(numbered) == 4)
}

@Test func maxSentencesRuleFailsOnlyWhenExceeded() {
    let testCase = ChatEvalCase(
        name: "x", title: "t", feed: "f", body: "b", question: "q",
        mustContainAny: [], mustNotContain: [], maxSentences: 2
    )
    #expect(!ChatAnswerScorer.score(answer: "One. Two. Three.", testCase: testCase).passed)
    #expect(ChatAnswerScorer.score(answer: "One. Two.", testCase: testCase).passed)
}

// MARK: - Summary faithfulness

private let bridgeSummaryCase = SummaryEvalCase(
    name: "bridge_medium",
    article: "bridge_late_numeric_fact",
    length: "medium",
    mustContainAny: [["42.7"], ["eleven weeks", "11 weeks"]],
    mustNotContain: ["behind schedule"]
)

private let bridgeBody = "The rehabilitation took fourteen months, cost $42.7 million, replaced roughly 14,000 rivets, and finished eleven weeks ahead of the revised schedule."

@Test func summaryScorerPassesFaithfulSummary() {
    let summary = "The bridge reopened after a 14-month, $42.7 million rehabilitation that replaced 14,000 rivets and finished 11 weeks ahead of the revised schedule."
    let result = SummaryScorer.score(summary: summary, testCase: bridgeSummaryCase, articleBody: bridgeBody, wordCount: 150)
    #expect(result.passed, "\(result.failures)")
}

@Test func summaryScorerFlagsInventedNumber() {
    let summary = "The $42.7 million project finished eleven weeks early and added 300 parking spaces."
    let result = SummaryScorer.score(summary: summary, testCase: bridgeSummaryCase, articleBody: bridgeBody, wordCount: 150)
    #expect(!result.passed)
    #expect(result.failures.map(\.rule) == ["unsupportedNumber"])
}

@Test func summaryScorerFlagsOverlongSummary() {
    let summary = Array(repeating: "The $42.7 million bridge finished eleven weeks early.", count: 10).joined(separator: " ")
    let result = SummaryScorer.score(summary: summary, testCase: bridgeSummaryCase, articleBody: bridgeBody, wordCount: 30)
    #expect(result.failures.map(\.rule) == ["tooLong"])
}

@Test func summaryNumbersReadDigitsAndWords() {
    #expect(SummaryScorer.numbers(in: "$42.7 million, 14,000 rivets, eleven weeks, the 1920s, one of them") == ["42.7", "14000", "11", "1920"])
}
