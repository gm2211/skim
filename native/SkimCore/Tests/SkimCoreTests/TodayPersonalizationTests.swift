import Foundation
import Testing
@testable import SkimCore

@Test func updateMarkersUseUnfilteredTitleInsteadOfLead() {
    let clusterer = StoryClusterer()
    let date = Date(timeIntervalSince1970: 1_000)
    let earlier = Article(id: "earlier", feedID: "feed", feedTitle: "Feed", title: "alpha beta gamma delta epsilon", fetchedAt: date)
    let current = Article(id: "current", feedID: "feed", feedTitle: "Feed", title: "alpha beta gamma zeta", fetchedAt: date.addingTimeInterval(1))
    // Keep lexical novelty below threshold; a lead marker must not classify an update.
    let tokens = ["alpha", "beta", "gamma", "delta", "epsilon", "now"]
    func feature(id: String, title: String) -> StoryArticleFeature {
        StoryArticleFeature(articleID: id, canonicalURL: nil, normalizedTitle: title,
            normalizedLead: "now", tokens: tokens, entities: [], contentFingerprint: id, computedAt: date)
    }
    let candidate = StoryClusterCandidate(storyID: "story", article: earlier,
        feature: feature(id: earlier.id, title: earlier.title))
    let coverage = clusterer.decide(article: current,
        feature: feature(id: current.id, title: current.title), candidates: [candidate])
    #expect(coverage.match?.membershipType == .coverage)
    // 'after' is a stop word, but must still count as a title update marker.
    let update = clusterer.decide(article: current,
        feature: feature(id: current.id, title: current.title + " after"), candidates: [candidate])
    #expect(update.match?.membershipType == .update)
}

@Test func todayPreferencesUseCappedStarsPinsAndDistinctFeedTaste() {
    let articles = (0..<3).map {
        Article(id: "article-\($0)", feedID: "feed", feedTitle: "Feed", title: "Title", isStarred: true)
    }
    let preferences = TodayRankingPreferences(feedWeights: ["feed": 0.5], pinnedArticleIDs: ["article-1"])
    #expect(preferences.signal(for: articles) == 2.75)
    #expect(TodayRankingPreferences(feedWeights: ["feed": .nan]).signal(for: articles) == 1)
}

@Test func todayRankingUsesStarsAndTasteWithoutChangingFrozenSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SkimStore(databaseURL: directory.appendingPathComponent("skim.sqlite"))
    let date = Date(timeIntervalSince1970: 10_000)
    for index in 0..<3 {
        let id = "\(index)"
        let feed = Feed(id: "feed-\(id)", title: "Feed \(id)", url: URL(string: "https://example.com/\(id)")!)
        let article = Article(id: "article-\(id)", feedID: feed.id, feedTitle: feed.title,
            title: "Report \(id)", publishedAt: date, fetchedAt: date)
        try await store.upsert(feed: feed, articles: [article])
        let story = Story(id: "story-\(id)", title: article.title, representativeArticleID: article.id,
            firstSeenAt: date, lastActivityAt: date, createdAt: date, updatedAt: date)
        try await store.upsertStory(story)
        try await store.upsertStoryMembership(StoryArticleMembership(storyID: story.id,
            articleID: article.id, membershipType: .coverage, addedAt: date))
        try await store.insertStoryRevision(StoryRevision(storyID: story.id, revisionNumber: 1,
            title: article.title, summary: "Frozen", representativeArticleID: article.id,
            sourceCount: 1, contentFingerprint: id, isMaterialChange: true, createdAt: date))
    }
    try await store.toggleStar(id: "article-2")
    let start = Date(timeIntervalSince1970: 0)
    let end = Date(timeIntervalSince1970: 86_400)
    let first = try await store.getOrGenerateTodayEdition(startsAt: start, endsAt: end, storyLimit: 5, generatedAt: date)
    #expect(first.items.map(\.snapshot.storyID) == ["story-2", "story-0"])
    let preferences = TodayRankingPreferences(feedWeights: ["feed-1": 1],
        pinnedArticleIDs: ["article-1"])
    let reused = try await store.getOrGenerateTodayEdition(startsAt: start, endsAt: end,
        storyLimit: 5, generatedAt: date, preferences: preferences)
    #expect(reused.items.map(\.snapshot) == first.items.map(\.snapshot))
    let fresh = try await store.getOrGenerateTodayEdition(startsAt: start, endsAt: end,
        storyLimit: 10, generatedAt: date, preferences: preferences)
    #expect(fresh.items.map(\.snapshot.storyID) == ["story-1", "story-2"])
}

@Test func todayUpdateSectionUsesMembershipRatherThanSummaryText() {
    let date = Date(timeIntervalSince1970: 1_000)
    let article = Article(id: "article", feedID: "feed", feedTitle: "Feed", title: "Report", fetchedAt: date)
    let story = Story(id: "story", title: "Report", firstSeenAt: date, lastActivityAt: date, createdAt: date, updatedAt: date)
    let revision = StoryRevision(storyID: story.id, revisionNumber: 2, title: "Report", summary: "Summary",
        deltaSummary: "A meaningful update in prose", representativeArticleID: article.id,
        sourceCount: 1, contentFingerprint: "fixture", isMaterialChange: true, createdAt: date)
    let source = TodayEditionCandidateSource(article: article,
        membership: StoryArticleMembership(storyID: story.id, articleID: article.id, membershipType: .update, addedAt: date))
    let candidate = TodayEditionCandidate(ranking: StoryRankingCandidate(story: story, representativeFeedID: "feed",
        distinctFeedCount: 1, articleCount: 1), revision: revision, sourceArticles: [source])
    let items = TodayEditionBuilder.buildItems(editionID: "edition", candidates: [candidate], storyLimit: 5, generatedAt: date)
    #expect(items.first?.item.section == EditionSectionRole.updates.rawValue)
}

@Test func todayEditionWithRealFractionalTimestampsPersistsAndReopens() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SkimStore(databaseURL: directory.appendingPathComponent("skim.sqlite"))
    // Find a current clock value whose epoch conversion loses one floating-point bit.
    // This is normal for Date(), but integer-epoch fixtures cannot expose it.
    var reference = Date().timeIntervalSinceReferenceDate
    var now = Date(timeIntervalSinceReferenceDate: reference)
    for _ in 0..<16 {
        now = Date(timeIntervalSinceReferenceDate: reference)
        if Date(timeIntervalSince1970: now.timeIntervalSince1970) != now { break }
        reference = reference.nextUp
    }
    #expect(Date(timeIntervalSince1970: now.timeIntervalSince1970) != now)
    for index in 0..<3 {
        let feed = Feed(id: "feed-\(index)", title: "Feed \(index)", url: URL(string: "https://example.com/feed-\(index)")!, fetchedAt: now)
        let article = Article(id: "article-\(index)", feedID: feed.id, feedTitle: feed.title,
            title: index < 2 ? "New telescope reveals distant galaxy in unprecedented detail" : "Community solar brings clean energy to city neighborhoods",
            url: URL(string: index < 2 ? "https://example.com/telescope" : "https://example.com/solar"),
            contentText: "Detailed reporting from this source.", publishedAt: now, fetchedAt: now)
        try await store.upsert(feed: feed, articles: [article])
    }
    let start = Calendar.current.startOfDay(for: now)
    let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
    let edition = try await store.getOrGenerateTodayEdition(startsAt: start, endsAt: end,
        storyLimit: 10, generatedAt: now)
    #expect(edition.items.count == 2)
    let reopened = try await store.getOrGenerateTodayEdition(startsAt: start, endsAt: end,
        storyLimit: 10, generatedAt: now.addingTimeInterval(1))
    #expect(reopened == edition)
    #expect(edition.edition.generatedAt == normalizedTimestamp(now))

    let consumed = try await store.setTodayEditionItemConsumed(editionID: edition.id,
        storyID: edition.items[0].snapshot.storyID, isConsumed: true, at: now)
    var originalPrecisionItem = consumed.items[0].snapshot
    originalPrecisionItem.consumedAt = now
    try await store.persistEdition(consumed.edition, items: [originalPrecisionItem])

    let emptyStore = try SkimStore(databaseURL: directory.appendingPathComponent("empty.sqlite"))
    let empty = try await emptyStore.getOrGenerateTodayEdition(startsAt: start, endsAt: end,
        storyLimit: 10, generatedAt: now)
    #expect(empty.edition.completedAt == normalizedTimestamp(now))
    #expect(empty.items.isEmpty)
}

@Test func consumedStoryDoesNotReturnForNextDayDuplicateButMaterialUpdateDoes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SkimStore(databaseURL: directory.appendingPathComponent("skim.sqlite"))
    let day: TimeInterval = 86_400
    let firstTitle = "Acme launches solar battery for homes"
    func ingest(_ id: String, title: String, at: TimeInterval) async throws {
        let feed = Feed(id: "feed-\(id)", title: "Source \(id)", url: URL(string: "https://example.com/feed-\(id)")!)
        let article = Article(id: id, feedID: feed.id, feedTitle: feed.title, title: title,
            url: URL(string: "https://example.com/\(id)"),
            contentText: "The product starts shipping this month in cities.",
            publishedAt: Date(timeIntervalSince1970: at), fetchedAt: Date(timeIntervalSince1970: at))
        try await store.upsert(feed: feed, articles: [article])
    }
    try await ingest("original", title: firstTitle, at: day / 2)
    let first = try await store.getOrGenerateTodayEdition(startsAt: Date(timeIntervalSince1970: 0),
        endsAt: Date(timeIntervalSince1970: day), storyLimit: 5, generatedAt: Date(timeIntervalSince1970: day / 2 + 1))
    let storyID = try #require(first.items.first?.snapshot.storyID)
    try await ingest("copy", title: firstTitle, at: day + 100)
    let unconsumed = try await store.getOrGenerateTodayEdition(startsAt: Date(timeIntervalSince1970: day),
        endsAt: Date(timeIntervalSince1970: day * 2), storyLimit: 20, generatedAt: Date(timeIntervalSince1970: day + 101))
    #expect(unconsumed.items.map(\.snapshot.storyID) == [storyID])
    let consumed = try await store.setTodayEditionItemConsumed(editionID: first.id, storyID: storyID,
        isConsumed: true, at: Date(timeIntervalSince1970: day + 102))
    let second = try await store.getOrGenerateTodayEdition(startsAt: Date(timeIntervalSince1970: day),
        endsAt: Date(timeIntervalSince1970: day * 2), storyLimit: 5, generatedAt: Date(timeIntervalSince1970: day + 101))
    #expect(second.items.isEmpty)
    let preserved = try #require(try await store.todayEdition(id: first.id))
    #expect(preserved.items.map(\.snapshot) == consumed.items.map(\.snapshot))
    #expect(preserved.items[0].memberArticleIDs == ["original"])

    let updateTitle = "Acme launches solar battery update for homes after recall"
    try await ingest("update", title: updateTitle, at: day + 200)
    // A later duplicate must not mask the unseen material revision beneath it.
    try await ingest("update-copy", title: updateTitle, at: day + 201)
    let fresh = try await store.getOrGenerateTodayEdition(startsAt: Date(timeIntervalSince1970: day),
        endsAt: Date(timeIntervalSince1970: day * 2), storyLimit: 10, generatedAt: Date(timeIntervalSince1970: day + 202))
    #expect(fresh.items.map(\.snapshot.storyID) == [storyID])
    #expect(fresh.items[0].snapshot.section == EditionSectionRole.updates.rawValue)
    let frozen = try await store.getOrGenerateTodayEdition(startsAt: Date(timeIntervalSince1970: day),
        endsAt: Date(timeIntervalSince1970: day * 2), storyLimit: 5, generatedAt: Date(timeIntervalSince1970: day + 202))
    #expect(frozen.id == second.id)
    #expect(frozen.items.map(\.snapshot.storyID) == [storyID])

    // Once the update is consumed, its historical material revision must not
    // make the next day's copy look new again.
    _ = try await store.setTodayEditionItemConsumed(editionID: fresh.id, storyID: storyID,
        isConsumed: true, at: Date(timeIntervalSince1970: day + 203))
    try await ingest("third-day-copy", title: updateTitle, at: day * 2 + 100)
    let third = try await store.getOrGenerateTodayEdition(startsAt: Date(timeIntervalSince1970: day * 2),
        endsAt: Date(timeIntervalSince1970: day * 3), storyLimit: 5, generatedAt: Date(timeIntervalSince1970: day * 2 + 101))
    #expect(third.items.isEmpty)
}


@Test func emptyTodayRecoversAfterFeedRefreshThenFreezesPopulatedEdition() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SkimStore(databaseURL: directory.appendingPathComponent("skim.sqlite"))
    let start = Date(timeIntervalSince1970: 0)
    let end = Date(timeIntervalSince1970: 86_400)
    let empty = try await store.getOrGenerateTodayEdition(startsAt: start, endsAt: end,
        storyLimit: 5, generatedAt: Date(timeIntervalSince1970: 1_000))
    let stillEmpty = try await store.getOrGenerateTodayEdition(startsAt: start, endsAt: end,
        storyLimit: 5, generatedAt: Date(timeIntervalSince1970: 2_000))
    #expect(stillEmpty == empty)
    let feed = Feed(id: "feed", title: "Feed", url: URL(string: "https://example.com/feed")!)
    let first = Article(id: "first", feedID: feed.id, feedTitle: feed.title,
        title: "Telescope discovers distant galaxy", publishedAt: Date(timeIntervalSince1970: 3_000))
    try await store.upsert(feed: feed, articles: [first])
    let populated = try await store.getOrGenerateTodayEdition(startsAt: start, endsAt: end,
        storyLimit: 5, generatedAt: Date(timeIntervalSince1970: 4_000))
    #expect(populated.id == empty.id)
    #expect(populated.items.count == 1)
    #expect(populated.edition.status == .ready)
    #expect(populated.edition.completedAt == nil)
    #expect(populated.edition.generatedAt == Date(timeIntervalSince1970: 4_000))
    let later = Article(id: "later", feedID: feed.id, feedTitle: feed.title,
        title: "Community orchestra starts summer concert series", publishedAt: Date(timeIntervalSince1970: 5_000))
    try await store.upsert(feed: feed, articles: [later])
    let frozen = try await store.getOrGenerateTodayEdition(startsAt: start, endsAt: end,
        storyLimit: 5, generatedAt: Date(timeIntervalSince1970: 6_000))
    #expect(frozen == populated)
}
