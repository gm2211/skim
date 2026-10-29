import Testing
import Foundation
import SkimCore
@testable import Skim

/// Smart sort works through the whole unread backlog, newest first, and says
/// truthfully how much is left (it used to stop at 60 per visit).
@Suite("Inbox rating queue")
struct InboxRatingQueueTests {
    private static func article(_ id: String, hoursAgo: Double) -> Article {
        Article(id: id, feedID: "feed", feedTitle: "Feed", title: "Story \(id)",
                publishedAt: Date(timeIntervalSinceNow: -hoursAgo * 3600))
    }

    @Test func pendingIsEveryUnratedArticleNewestFirst() {
        // 300 articles, more than the old 60-per-visit cap, in a ranked (not dated) order.
        let articles = (0..<300).map { Self.article("a\($0)", hoursAgo: Double(($0 * 37) % 300)) }
        let rated: Set<String> = ["a0", "a1", "a2"]
        let pending = InboxRatingQueue.pending(articles) { rated.contains($0) }
        #expect(pending.count == 297)
        #expect(!pending.contains { rated.contains($0.id) })
        let dates = pending.map { $0.publishedAt! }
        #expect(dates == dates.sorted(by: >))
    }

    @Test func rerateAllKeepsRatedArticles() {
        let articles = [Self.article("old", hoursAgo: 5), Self.article("new", hoursAgo: 1)]
        let pending = InboxRatingQueue.pending(articles, rerateAll: true) { _ in true }
        #expect(pending.map(\.id) == ["new", "old"])
    }

    @Test func statusCountsTheWholeBacklog() {
        #expect(InboxRatingQueue.status(done: 20, batch: 20, unrated: 940)
            == "Rating \(21.formatted())–\(40.formatted()) of \(940.formatted()) unrated…")
    }

    @Test func reRanksEarlyThenEveryFifthBatch() {
        let reRanked = (0..<12).filter { InboxRatingQueue.shouldReRank(afterBatch: $0) }
        #expect(reRanked == [0, 1, 4, 9])
    }

    @Test func windowNoteOnlyWhenTheListIsShorterThanUnread() {
        #expect(InboxRatingQueue.windowNote(loaded: 1_000, unread: 1_000) == nil)
        #expect(InboxRatingQueue.windowNote(loaded: 0, unread: 6_024) == nil)
        #expect(InboxRatingQueue.windowNote(loaded: 1_000, unread: 6_024)
            == "Smart sort ranks your \(1_000.formatted()) newest unread articles. Turn it off to see all \(6_024.formatted()).")
    }

    @Test func windowMatchesDesktopsPerRunCap() {
        #expect(InboxRatingQueue.window == 1_000)
    }
}
