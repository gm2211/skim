import Foundation
import Testing
@testable import SkimCore

@Test func storyTextDropsMarkdownLinkReferenceDefinitions() {
    let raw = "[Comments][1]\n\n  [1]: https://news.ycombinator.com/item?id=44123456"
    #expect(StoryText.excerpt(raw) == "Comments")
}

@Test func storyTextKeepsLinkTextAndDropsTheTarget() {
    #expect(
        StoryText.excerpt("See [the release notes](https://example.com/notes) for details.")
            == "See the release notes for details."
    )
}

@Test func storyTextDropsImagesEntirely() {
    #expect(
        StoryText.excerpt("![a chart](https://example.com/c.png) Revenue doubled.")
            == "Revenue doubled."
    )
}

@Test func storyTextStripsHTMLAndDecodesEntities() {
    #expect(
        StoryText.excerpt("<p>Rust &amp; C++ <em>both</em> shipped.</p>") == "Rust & C++ both shipped."
    )
}

@Test func storyTextDropsBareURLsAndCodeBlocks() {
    let raw = "Install it:\n```\ncargo add skim\n```\nDocs at https://example.com today."
    #expect(StoryText.excerpt(raw) == "Install it: Docs at today.")
}

@Test func storyTextReturnsNothingForABodyThatIsOnlyALink() {
    #expect(StoryText.excerpt("https://example.com/story") == "")
    #expect(StoryText.excerpt("  [1]: https://example.com/story  ") == "")
    #expect(StoryText.excerpt("") == "")
}

@Test func storyTextStripsLeadingMarkers() {
    #expect(StoryText.excerpt("> ## The Fed held rates") == "The Fed held rates")
    #expect(StoryText.excerpt("- First point here") == "First point here")
}

@Test func storyTextCutsOnASentenceInsideTheLimit() {
    let first = String(repeating: "A", count: 100)
    let raw = "\(first). \(String(repeating: "B", count: 250)) more text past the limit"
    #expect(StoryText.excerpt(raw) == "\(first).")
}

@Test func storyTextFallsBackToAWordBoundaryWhenNoSentenceFits() {
    let raw = String(repeating: "word ", count: 120) + "tail"
    let cut = StoryText.excerpt(raw)
    #expect(cut.hasSuffix("…"))
    #expect(cut.count <= StoryText.maxLength + 1)
}
