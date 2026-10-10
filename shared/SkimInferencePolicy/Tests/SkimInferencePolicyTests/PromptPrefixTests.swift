import Testing
@testable import SkimInferencePolicy

/// A toy tokenizer: each token id is one character's scalar value.
private func tokens(_ text: String) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
private func decode(_ ids: [Int]) -> String { String(String.UnicodeScalarView(ids.compactMap(Unicode.Scalar.init))) }

@Test func boundaryEndsRightAfterTheMarker() {
    let prompt = "ARTICLE:\nbody\nEND OF ARTICLE\n\nQuestion: why?"
    let ids = tokens(prompt)
    let boundary = PromptPrefix.boundary(in: ids, marker: "END OF ARTICLE", decode: decode)
    #expect(boundary.map { decode(Array(ids[..<$0])) } == "ARTICLE:\nbody\nEND OF ARTICLE")
}

@Test func boundaryIsNilWithoutMarkerOrWithNothingAfterIt() {
    #expect(PromptPrefix.boundary(in: tokens("no marker here"), marker: "END", decode: decode) == nil)
    #expect(PromptPrefix.boundary(in: tokens("body END"), marker: "END", decode: decode) == nil)
    #expect(PromptPrefix.boundary(in: [], marker: "END", decode: decode) == nil)
}

@Test func extendsRequiresAStrictNonEmptyPrefix() {
    #expect(PromptPrefix.extends([1, 2, 3], prefix: [1, 2]))
    #expect(!PromptPrefix.extends([1, 2], prefix: [1, 2]))
    #expect(!PromptPrefix.extends([1, 3, 3], prefix: [1, 2]))
    #expect(!PromptPrefix.extends([1, 2, 3], prefix: []))
}

@Test func groundedChatPromptsShareTheArticlePrefix() {
    let system = GroundedChatPrompt.systemPrompt(question: "Who won?")
    let first = GroundedChatPrompt.build(system: system, articleContext: "The Hawks won 3-1.", question: "Who won?")
    let second = GroundedChatPrompt.build(
        system: system, articleContext: "The Hawks won 3-1.", question: "What was the score?",
        priorExchange: (question: "Who won?", answer: "The Hawks.", label: "A"))
    let a = first[1].content, b = second[1].content
    let end = a.range(of: PromptPrefix.articleMarker)!.upperBound
    #expect(b.hasPrefix(String(a[..<end])))
}

@Test func commonLengthLeavesATokenToPrefill() {
    #expect(PromptPrefix.commonLength([1, 2, 3, 4], [1, 2, 9]) == 2)
    #expect(PromptPrefix.commonLength([1, 2, 3], [1, 2, 3, 4]) == 2)
    #expect(PromptPrefix.commonLength([5], [5]) == 0)
    #expect(PromptPrefix.commonLength([], [1]) == 0)
}
