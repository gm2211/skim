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
