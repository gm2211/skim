import Foundation
import Testing
@testable import SkimCore

@Test func publicationNameKeepsARealName() {
    #expect(PublicationName.of(feedTitle: "Hacker News") == "Hacker News")
}

@Test func publicationNameFallsBackToTheHostForFormatTitles() {
    #expect(
        PublicationName.of(feedTitle: "RSS 2.0", url: URL(string: "https://www.theverge.com/2026/1/1/post"))
            == "theverge.com"
    )
    #expect(PublicationName.of(feedTitle: "Atom", url: URL(string: "http://lwn.net/Articles/1")) == "lwn.net")
}

@Test func publicationNameKeepsTheFormatTitleWithoutAUsableURL() {
    #expect(PublicationName.of(feedTitle: "RSS 2.0") == "RSS 2.0")
}

@Test func publicationNameNamesAnUntitledFeed() {
    #expect(PublicationName.of(feedTitle: "   ") == "Unknown source")
}

@Test func publicationNameDropsTheDescriptionAfterASeparator() {
    #expect(
        PublicationName.of(feedTitle: "Java News/Tech/Discussion/etc. No programming help, no learning Java")
            == "Java News/Tech/Discussion/etc"
    )
    #expect(
        PublicationName.of(feedTitle: "Simon Willison's Weblog - Blog entries") == "Simon Willison's Weblog"
    )
}

@Test func publicationNameIgnoresASeparatorThatLeavesNothingBehind() {
    #expect(PublicationName.of(feedTitle: "A - Journal of Nothing") == "A - Journal of Nothing")
}

@Test func publicationNameTruncatesOnAWordBoundary() {
    #expect(
        PublicationName.of(feedTitle: "The Exceedingly Long Quarterly Review of Things")
            == "The Exceedingly Long Quarterly…"
    )
}

@Test func publicationNamePrefersTheArticlesOwnLink() {
    let article = Article(
        id: "a", feedID: "f", feedTitle: "RSS 2.0", title: "T",
        url: URL(string: "https://news.ycombinator.com/item?id=1"),
        fetchedAt: Date()
    )
    #expect(PublicationName.of(article: article) == "news.ycombinator.com")
}
