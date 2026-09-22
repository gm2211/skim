import Testing
import Foundation
@testable import SkimCore

// MARK: - CatchUpRange
//
// Quick Catch-up used to run on whatever the list happened to hold, with no way
// to say "just today". The range picker narrows the pool before the first pass
// sees it; these tests pin what it keeps.
@Suite("CatchUpRange")
struct CatchUpRangeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func article(id: String, hoursAgo: Double?) -> Article {
        Article(
            id: id,
            feedID: "feed",
            feedTitle: "Feed",
            title: "Title \(id)",
            publishedAt: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) }
        )
    }

    @Test func anythingKeepsEverything() {
        let articles = [article(id: "a", hoursAgo: 1), article(id: "b", hoursAgo: 500)]
        #expect(CatchUpRange.anything.filter(articles, now: now).map(\.id) == ["a", "b"])
        #expect(CatchUpRange.anything.cutoff(now: now) == nil)
    }

    @Test func aRangeDropsWhatFallsOutsideIt() {
        let articles = [
            article(id: "fresh", hoursAgo: 2),
            article(id: "yesterday", hoursAgo: 20),
            article(id: "old", hoursAgo: 200),
        ]

        #expect(CatchUpRange.sixHours.filter(articles, now: now).map(\.id) == ["fresh"])
        #expect(CatchUpRange.day.filter(articles, now: now).map(\.id) == ["fresh", "yesterday"])
        #expect(
            CatchUpRange.week.filter(articles, now: now).map(\.id)
                == ["fresh", "yesterday", "old"]
        )
    }

    @Test func anArticleWithNoPublicationDateIsKept() {
        // Plenty of feeds omit the field; dropping those would quietly hide
        // whole publications from every range but "Anything unread".
        let articles = [article(id: "undated", hoursAgo: nil), article(id: "old", hoursAgo: 200)]
        #expect(CatchUpRange.day.filter(articles, now: now).map(\.id) == ["undated"])
    }
}
