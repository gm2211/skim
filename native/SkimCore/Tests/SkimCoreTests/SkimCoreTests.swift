import Foundation
import Testing
@testable import SkimCore

@Test func parsesOPMLFeeds() throws {
    let opml = """
    <?xml version="1.0"?>
    <opml version="2.0">
      <body>
        <outline text="Tech">
          <outline text="Example Feed" title="Example Feed" type="rss" xmlUrl="https://example.com/feed.xml" htmlUrl="https://example.com"/>
        </outline>
      </body>
    </opml>
    """

    let feeds = try OPMLImportService().parseOPML(data: Data(opml.utf8))

    #expect(feeds.count == 1)
    #expect(feeds[0].title == "Example Feed")
    #expect(feeds[0].xmlURL.absoluteString == "https://example.com/feed.xml")
}

@Test func upgradesHTTPFeedURLsFromOPML() throws {
    let opml = """
    <opml version="2.0">
      <body>
        <outline text="Old Feed" xmlUrl="http://example.com/feed.xml" htmlUrl="http://example.com"/>
      </body>
    </opml>
    """

    let feed = try #require(OPMLImportService().parseOPML(data: Data(opml.utf8)).first)

    #expect(feed.xmlURL.absoluteString == "https://example.com/feed.xml")
    #expect(feed.htmlURL?.absoluteString == "https://example.com")
}

@Test func persistsAndFiltersArticles() async throws {
    let store = try temporaryStore()
    let feed = Feed(id: "feed-1", title: "A Feed", url: URL(string: "https://example.com/rss")!)
    let article = Article(
        id: "article-1",
        feedID: feed.id,
        feedTitle: feed.title,
        title: "Important story",
        url: URL(string: "https://example.com/story"),
        contentText: "Body",
        publishedAt: Date(timeIntervalSince1970: 100),
        aggregatorKind: .hackerNews,
        externalURL: URL(string: "https://example.com/original"),
        commentsURL: URL(string: "https://news.ycombinator.com/item?id=1")
    )

    try await store.upsert(feed: feed, articles: [article])

    let unread = try await store.listArticles(filter: ArticleFilter(readState: .unread))
    #expect(unread.map(\.id) == ["article-1"])
    #expect(unread.first?.aggregatorKind == .hackerNews)
    #expect(unread.first?.externalURL?.absoluteString == "https://example.com/original")
    #expect(unread.first?.commentsURL?.absoluteString == "https://news.ycombinator.com/item?id=1")
    #expect(try await store.countUnread(feedID: nil) == 1)

    try await store.setArticleRead(id: "article-1", isRead: true)
    #expect(try await store.countUnread(feedID: nil) == 0)

    try await store.toggleStar(id: "article-1")
    let starred = try await store.listArticles(filter: ArticleFilter(starredOnly: true))
    #expect(starred.first?.isStarred == true)
}

@Test func persistsReaderCache() async throws {
    let store = try temporaryStore()
    let feed = Feed(id: "feed-1", title: "A Feed", url: URL(string: "https://example.com/rss")!)
    let article = Article(
        id: "article-1",
        feedID: feed.id,
        feedTitle: feed.title,
        title: "Important story",
        url: URL(string: "https://example.com/story"),
        contentText: "Preview"
    )

    try await store.upsert(feed: feed, articles: [article])

    #expect(try await store.cachedReaderText(articleID: article.id) == nil)
    #expect(try await store.countCachedReaderTexts() == 0)

    try await store.cacheReaderText(
        articleID: article.id,
        url: URL(string: "https://example.com/story"),
        text: "Extracted article body"
    )

    #expect(try await store.cachedReaderText(articleID: article.id) == "Extracted article body")
    #expect(try await store.countCachedReaderTexts() == 1)

    try await store.cacheReaderText(
        articleID: article.id,
        url: URL(string: "https://example.com/story?updated=1"),
        text: "Updated article body"
    )

    #expect(try await store.cachedReaderText(articleID: article.id) == "Updated article body")
    #expect(try await store.countCachedReaderTexts() == 1)
}

@Test func persistsStoryEditionDataWithoutChangingRawArticles() async throws {
    let databaseURL = temporaryStoreURL()
    let store = try SkimStore(databaseURL: databaseURL)
    let feed = Feed(id: "feed-1", title: "A Feed", url: URL(string: "https://example.com/rss")!)
    let newer = Article(
        id: "article-newer",
        feedID: feed.id,
        feedTitle: feed.title,
        title: "Newer coverage",
        publishedAt: Date(timeIntervalSince1970: 200),
        isRead: false,
        isStarred: true
    )
    let older = Article(
        id: "article-older",
        feedID: feed.id,
        feedTitle: feed.title,
        title: "Older coverage",
        publishedAt: Date(timeIntervalSince1970: 100),
        isRead: true,
        isStarred: false
    )
    try await store.upsert(feed: feed, articles: [older, newer])
    let articlesBefore = try await store.listArticles(filter: ArticleFilter())

    let story = Story(
        id: "story-stable-1",
        title: "A durable story",
        summary: "Two sources cover one event.",
        representativeArticleID: newer.id,
        firstSeenAt: Date(timeIntervalSince1970: 100),
        lastActivityAt: Date(timeIntervalSince1970: 200),
        createdAt: Date(timeIntervalSince1970: 210),
        updatedAt: Date(timeIntervalSince1970: 220)
    )
    try await store.upsertStory(story)
    try await store.upsertStoryMembership(StoryArticleMembership(
        storyID: story.id,
        articleID: older.id,
        membershipType: .coverage,
        confidence: 0.87,
        addedAt: Date(timeIntervalSince1970: 215)
    ))

    let revision = StoryRevision(
        storyID: story.id,
        revisionNumber: 1,
        title: story.title,
        summary: "The edition snapshot summary.",
        deltaSummary: "A second source confirmed the event.",
        representativeArticleID: newer.id,
        sourceCount: 2,
        contentFingerprint: "sha256:fixture",
        isMaterialChange: true,
        createdAt: Date(timeIntervalSince1970: 225)
    )
    try await store.insertStoryRevision(revision)
    try await store.upsertStoryUserState(StoryUserState(
        storyID: story.id,
        lastSeenRevision: 1,
        isFollowed: true,
        updatedAt: Date(timeIntervalSince1970: 230)
    ))

    let edition = Edition(
        id: "edition-2026-07-24",
        title: "Today",
        scope: "all",
        storyLimit: 10,
        status: .ready,
        startsAt: Date(timeIntervalSince1970: 0),
        endsAt: Date(timeIntervalSince1970: 86_400),
        generatedAt: Date(timeIntervalSince1970: 240),
        totalSourceCount: 2
    )
    let item = EditionItem(
        editionID: edition.id,
        storyID: story.id,
        storyRevisionNumber: revision.revisionNumber,
        position: 0,
        section: "Top Stories",
        snapshotTitle: revision.title,
        snapshotSummary: revision.summary,
        snapshotDeltaSummary: revision.deltaSummary,
        snapshotSourceCount: revision.sourceCount,
        snapshotReason: "Two independent sources",
        isUniqueFind: false
    )
    try await store.persistEdition(edition, items: [item])

    #expect(try await store.story(id: story.id) == story)
    #expect(try await store.listStoryMemberships(storyID: story.id) == [
        StoryArticleMembership(
            storyID: story.id,
            articleID: older.id,
            membershipType: .coverage,
            confidence: 0.87,
            addedAt: Date(timeIntervalSince1970: 215)
        )
    ])
    #expect(try await store.latestStoryRevision(storyID: story.id) == revision)
    #expect(try await store.hasUnseenStoryRevision(storyID: story.id) == false)

    try await store.markStoryCaughtUp(
        storyID: story.id,
        throughRevision: revision.revisionNumber,
        at: Date(timeIntervalSince1970: 250)
    )
    let caughtUp = try #require(try await store.storyUserState(storyID: story.id))
    #expect(caughtUp.lastSeenRevision == 1)
    #expect(caughtUp.lastReadRevision == 1)
    #expect(caughtUp.isFollowed == true)

    try await store.setEditionItemConsumed(
        editionID: edition.id,
        storyID: story.id,
        isConsumed: true,
        at: Date(timeIntervalSince1970: 260)
    )
    try await store.updateEditionProgress(
        id: edition.id,
        status: .completed,
        completedAt: Date(timeIntervalSince1970: 270),
        totalSourceCount: 2
    )

    let persistedItem = try #require(try await store.listEditionItems(editionID: edition.id).first)
    #expect(persistedItem.snapshotTitle == item.snapshotTitle)
    #expect(persistedItem.snapshotSummary == item.snapshotSummary)
    #expect(persistedItem.isConsumed == true)
    #expect(persistedItem.consumedAt == Date(timeIntervalSince1970: 260))

    let persistedEdition = try #require(try await store.edition(id: edition.id))
    #expect(persistedEdition.status == .completed)
    #expect(persistedEdition.completedAt == Date(timeIntervalSince1970: 270))

    let articlesAfter = try await store.listArticles(filter: ArticleFilter())
    #expect(articlesAfter == articlesBefore)
    #expect(try await store.countUnread(feedID: nil) == 1)

    // Reopening runs every CREATE TABLE/INDEX migration again.
    let reopened = try SkimStore(databaseURL: databaseURL)
    #expect(try await reopened.story(id: story.id) == story)
    #expect(try await reopened.listArticles(filter: ArticleFilter()) == articlesBefore)
}

@Test func storyUpsertPreservesActivityBounds() async throws {
    let store = try temporaryStore()
    let initial = Story(
        id: "story-bounds",
        title: "Initial",
        firstSeenAt: Date(timeIntervalSince1970: 100),
        lastActivityAt: Date(timeIntervalSince1970: 200),
        createdAt: Date(timeIntervalSince1970: 210),
        updatedAt: Date(timeIntervalSince1970: 220)
    )
    try await store.upsertStory(initial)

    var update = initial
    update.title = "Updated"
    update.firstSeenAt = Date(timeIntervalSince1970: 150)
    update.lastActivityAt = Date(timeIntervalSince1970: 190)
    update.updatedAt = Date(timeIntervalSince1970: 230)
    try await store.upsertStory(update)

    var stored = try #require(try await store.story(id: initial.id))
    #expect(stored.firstSeenAt == initial.firstSeenAt)
    #expect(stored.lastActivityAt == initial.lastActivityAt)
    #expect(stored.createdAt == initial.createdAt)

    update.firstSeenAt = Date(timeIntervalSince1970: 50)
    update.lastActivityAt = Date(timeIntervalSince1970: 300)
    try await store.upsertStory(update)

    stored = try #require(try await store.story(id: initial.id))
    #expect(stored.firstSeenAt == Date(timeIntervalSince1970: 50))
    #expect(stored.lastActivityAt == Date(timeIntervalSince1970: 300))
}

@Test func immutablePersistenceRetriesRequireIdenticalContent() async throws {
    let store = try temporaryStore()
    let feed = Feed(id: "feed-immutable", title: "Feed", url: URL(string: "https://example.com/feed")!)
    let article = Article(
        id: "article-immutable",
        feedID: feed.id,
        feedTitle: feed.title,
        title: "Article"
    )
    try await store.upsert(feed: feed, articles: [article])

    let story = Story(
        id: "story-immutable",
        title: "Story",
        representativeArticleID: article.id,
        firstSeenAt: Date(timeIntervalSince1970: 100),
        lastActivityAt: Date(timeIntervalSince1970: 100)
    )
    try await store.upsertStory(story)
    let revision = StoryRevision(
        storyID: story.id,
        revisionNumber: 1,
        title: "Revision",
        summary: "Frozen revision",
        representativeArticleID: article.id,
        sourceCount: 1,
        createdAt: Date(timeIntervalSince1970: 110)
    )
    try await store.insertStoryRevision(revision)
    try await store.insertStoryRevision(revision)

    let edition = Edition(
        id: "edition-immutable",
        title: "Today",
        scope: "all",
        storyLimit: 5,
        status: .ready,
        startsAt: Date(timeIntervalSince1970: 1_000),
        endsAt: Date(timeIntervalSince1970: 2_000),
        generatedAt: Date(timeIntervalSince1970: 1_100),
        totalSourceCount: 1
    )
    let item = EditionItem(
        editionID: edition.id,
        storyID: story.id,
        storyRevisionNumber: revision.revisionNumber,
        position: 0,
        section: "top_stories",
        snapshotTitle: revision.title,
        snapshotSummary: revision.summary,
        snapshotSourceCount: 1
    )
    try await store.persistEdition(edition, items: [item])
    try await store.persistEdition(edition, items: [item])

    var conflictingRevision = revision
    conflictingRevision.summary = "Rewritten revision"
    #expect(await operationThrows {
        try await store.insertStoryRevision(conflictingRevision)
    })

    var conflictingEdition = edition
    conflictingEdition.title = "Rewritten edition"
    #expect(await operationThrows {
        try await store.persistEdition(conflictingEdition, items: [item])
    })

    var conflictingItem = item
    conflictingItem.snapshotSummary = "Rewritten snapshot"
    #expect(await operationThrows {
        try await store.persistEdition(edition, items: [conflictingItem])
    })

    #expect(try await store.storyRevision(storyID: story.id, revisionNumber: 1) == revision)
    #expect(try await store.edition(id: edition.id) == edition)
    #expect(try await store.listEditionItems(editionID: edition.id) == [item])
}

@Test func storyAndEditionModelsMatchSnakeCaseJSONContract() throws {
    let goldenJSON = """
    {
      "story": {
        "id": "story-1",
        "title": "Story",
        "summary": "Story summary",
        "representative_article_id": "article-1",
        "first_seen_at": 100,
        "last_activity_at": 200,
        "created_at": 210,
        "updated_at": 220
      },
      "membership": {
        "story_id": "story-1",
        "article_id": "article-2",
        "membership_type": "coverage",
        "confidence": 0.85,
        "added_at": 230
      },
      "revision": {
        "story_id": "story-1",
        "revision_number": 3,
        "title": "Revision",
        "summary": "Revision summary",
        "delta_summary": "New facts",
        "representative_article_id": "article-1",
        "source_count": 4,
        "content_fingerprint": "sha256:contract",
        "is_material_change": true,
        "created_at": 240
      },
      "user_state": {
        "story_id": "story-1",
        "last_seen_revision": 3,
        "last_read_revision": 2,
        "is_followed": true,
        "is_hidden": false,
        "caught_up_at": 250,
        "updated_at": 260
      },
      "edition": {
        "id": "edition-1",
        "title": "Today",
        "scope": "folder:technology",
        "story_limit": 5,
        "status": "completed",
        "starts_at": 1000,
        "ends_at": 2000,
        "generated_at": 1100,
        "completed_at": 1200,
        "total_source_count": 9
      },
      "item": {
        "edition_id": "edition-1",
        "story_id": "story-1",
        "story_revision_number": 3,
        "position": 0,
        "section": "top_stories",
        "snapshot_title": "Frozen title",
        "snapshot_summary": "Frozen summary",
        "snapshot_delta_summary": "Frozen delta",
        "snapshot_source_count": 4,
        "snapshot_reason": "Widely covered",
        "is_unique_find": false,
        "is_consumed": true,
        "consumed_at": 1300
      }
    }
    """

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    let goldenData = Data(goldenJSON.utf8)
    let fixture = try decoder.decode(StoryContractFixture.self, from: goldenData)
    #expect(fixture.membership.membershipType == .coverage)
    #expect(fixture.revision.createdAt == Date(timeIntervalSince1970: 240))
    #expect(fixture.edition.status == .completed)
    #expect(fixture.item.isConsumed == true)

    let encodedObject = try JSONSerialization.jsonObject(with: encoder.encode(fixture)) as? NSDictionary
    let goldenObject = try JSONSerialization.jsonObject(with: goldenData) as? NSDictionary
    #expect(encodedObject == goldenObject)
    #expect(StoryMembershipType.allCases.map(\.rawValue) == ["duplicate", "coverage", "update"])
    #expect(EditionStatus.allCases.map(\.rawValue) == ["draft", "ready", "completed", "failed"])
}

@Test func clusteringNormalizationAndStableIDMatchGoldenContract() throws {
    let article = Article(
        id: "article-golden",
        feedID: "feed-golden",
        feedTitle: "Golden",
        title: "Acme launches solar battery | Example News",
        url: URL(string: "https://Example.com:443/news/?b=2&utm_source=mail&a=1&source=rss#fragment"),
        contentText: "Battery storage arrives today.",
        publishedAt: Date(timeIntervalSince1970: 100),
        fetchedAt: Date(timeIntervalSince1970: 200)
    )
    let clusterer = StoryClusterer()
    let feature = clusterer.feature(for: article)

    #expect(feature.canonicalURL == "https://example.com/news?a=1&b=2")
    #expect(feature.normalizedTitle == "acme launches solar battery")
    #expect(feature.normalizedLead == "battery storage arrives today")
    #expect(feature.contentFingerprint == "58c49b19daae04bfbb6c0c09feb86ddc7dfaf7e798692cd4f092f442422257eb")
    #expect(clusterer.stableStoryID(for: article, feature: feature) == "story-492ee725ea8735b8")
    #expect(StoryClusterer.fnv1a64("https://example.com/news?a=1&b=2\n0") == "492ee725ea8735b8")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let object = try #require(
        JSONSerialization.jsonObject(with: encoder.encode(feature)) as? [String: Any]
    )
    #expect(object["article_id"] as? String == article.id)
    #expect(object["canonical_url"] as? String == feature.canonicalURL)
    #expect(object["normalized_title"] as? String == feature.normalizedTitle)
    #expect(object["content_fingerprint"] as? String == feature.contentFingerprint)
    #expect(object["feature_version"] as? Int == StoryArticleFeature.currentVersion)
    #expect(object["computed_at"] as? Double == 200)

    let configurationObject = try #require(
        JSONSerialization.jsonObject(
            with: encoder.encode(StoryClusteringConfiguration())
        ) as? [String: Any]
    )
    #expect(configurationObject["rolling_window"] as? Double == 345_600)
    #expect(configurationObject["duplicate_threshold"] as? Double == 0.88)
    #expect(configurationObject["coverage_threshold"] as? Double == 0.68)
    #expect(configurationObject["borderline_threshold"] as? Double == 0.58)

    let rankedObject = try #require(
        JSONSerialization.jsonObject(with: encoder.encode(RankedStory(
            storyID: "story-golden",
            score: 7.5,
            distinctFeedCount: 3,
            rawArticleCount: 4,
            isUniqueFind: false,
            reason: "3_independent_sources"
        ))) as? [String: Any]
    )
    #expect(rankedObject["story_id"] as? String == "story-golden")
    #expect(rankedObject["distinct_feed_count"] as? Int == 3)
    #expect(rankedObject["raw_article_count"] as? Int == 4)
    #expect(rankedObject["is_unique_find"] as? Bool == false)
}

@Test func aggregatorClusteringPrefersExternalArticleTarget() {
    let article = Article(
        id: "aggregator-article",
        feedID: "feed-hn",
        feedTitle: "Hacker News",
        title: "Acme launches solar battery",
        url: URL(string: "https://news.ycombinator.com/item?id=123"),
        fetchedAt: Date(timeIntervalSince1970: 300),
        aggregatorKind: .hackerNews,
        externalURL: URL(string: "https://acme.example/launch?utm_source=hn"),
        commentsURL: URL(string: "https://news.ycombinator.com/item?id=123")
    )

    let feature = StoryClusterer().feature(for: article)

    #expect(feature.canonicalURL == "https://acme.example/launch")
}

@Test func repeatedCoverageClassifiesWithoutDuplicateCollapse() {
    let clusterer = StoryClusterer()
    let first = clusteringArticle(
        id: "article-first",
        feedID: "feed-a",
        title: "Acme launches solar battery for homes",
        content: "The product starts shipping this month in cities.",
        timestamp: 1_000
    )
    let second = clusteringArticle(
        id: "article-second",
        feedID: "feed-b",
        title: "Acme launches home solar battery nationwide",
        content: "The product begins shipping this month in cities.",
        timestamp: 1_100
    )
    let firstFeature = clusterer.feature(for: first)
    let decision = clusterer.decide(
        article: second,
        feature: clusterer.feature(for: second),
        candidates: [StoryClusterCandidate(
            storyID: "story-acme",
            article: first,
            feature: firstFeature
        )]
    )

    #expect(decision.match?.storyID == "story-acme")
    #expect(decision.match?.membershipType == .coverage)
    #expect((decision.match?.confidence ?? 0) >= 0.68)
    #expect((decision.match?.confidence ?? 1) < 0.88)

    let update = clusteringArticle(
        id: "article-update",
        feedID: "feed-c",
        title: "Acme launches solar battery update for homes after recall",
        content: "The product starts shipping this month in cities.",
        timestamp: 1_200
    )
    let updateDecision = clusterer.decide(
        article: update,
        feature: clusterer.feature(for: update),
        candidates: [StoryClusterCandidate(
            storyID: "story-acme",
            article: first,
            feature: firstFeature
        )]
    )
    #expect(updateDecision.match?.membershipType == .update)
}

@Test func exactDuplicateCollapsesStoryButNeverLeaksFromRawFeed() async throws {
    let store = try temporaryStore()
    let feedA = Feed(id: "feed-a", title: "Feed A", url: URL(string: "https://a.example/rss")!)
    let feedB = Feed(id: "feed-b", title: "Feed B", url: URL(string: "https://b.example/rss")!)
    let first = clusteringArticle(
        id: "article-a",
        feedID: feedA.id,
        feedTitle: feedA.title,
        title: "Acme launches a solar battery",
        url: "https://news.example/acme?utm_source=a",
        timestamp: 2_000,
        isRead: true
    )
    let duplicate = clusteringArticle(
        id: "article-b",
        feedID: feedB.id,
        feedTitle: feedB.title,
        title: "Acme launches a solar battery | Feed B",
        url: "https://NEWS.example:443/acme?fbclid=tracking",
        timestamp: 2_100,
        isStarred: true
    )

    try await store.upsert(feed: feedA, articles: [first])
    try await store.upsert(feed: feedB, articles: [duplicate])

    let rawArticles = try await store.listArticles(filter: ArticleFilter())
    #expect(Set(rawArticles.map(\.id)) == Set([first.id, duplicate.id]))
    #expect(rawArticles.first(where: { $0.id == first.id })?.isRead == true)
    #expect(rawArticles.first(where: { $0.id == duplicate.id })?.isStarred == true)

    let stories = try await store.listStories()
    let story = try #require(stories.first)
    #expect(stories.count == 1)
    let memberships = try await store.listStoryMemberships(storyID: story.id)
    #expect(memberships.map(\.membershipType) == [.coverage, .duplicate])
    #expect(try await store.listStoryRevisions(storyID: story.id).last?.sourceCount == 1)
    let firstCanonicalURL = try await store.storyFeature(articleID: first.id)?.canonicalURL
    let duplicateCanonicalURL = try await store.storyFeature(articleID: duplicate.id)?.canonicalURL
    #expect(firstCanonicalURL == duplicateCanonicalURL)
}

@Test func entityGuardPreventsHighOverlapFalseMerge() {
    let clusterer = StoryClusterer()
    let apple = clusteringArticle(
        id: "apple",
        feedID: "feed-a",
        title: "Quarterly profit rises sharply at Apple",
        timestamp: 3_000
    )
    let microsoft = clusteringArticle(
        id: "microsoft",
        feedID: "feed-b",
        title: "Quarterly profit rises sharply at Microsoft",
        timestamp: 3_100
    )
    let decision = clusterer.decide(
        article: microsoft,
        feature: clusterer.feature(for: microsoft),
        candidates: [StoryClusterCandidate(
            storyID: "story-apple",
            article: apple,
            feature: clusterer.feature(for: apple)
        )]
    )

    #expect(decision.match == nil)
    #expect(decision.borderline == nil)
}

@Test func borderlineMatchesAreDeferredAndPersisted() async throws {
    let store = try temporaryStore()
    let feedA = Feed(id: "feed-a", title: "Feed A", url: URL(string: "https://a.example/rss")!)
    let feedB = Feed(id: "feed-b", title: "Feed B", url: URL(string: "https://b.example/rss")!)
    let first = clusteringArticle(
        id: "borderline-a",
        feedID: feedA.id,
        feedTitle: feedA.title,
        title: "Acme solar battery production begins nevada",
        timestamp: 4_000
    )
    let second = clusteringArticle(
        id: "borderline-b",
        feedID: feedB.id,
        feedTitle: feedB.title,
        title: "Acme solar battery production opens texas",
        timestamp: 4_100
    )

    try await store.upsert(feed: feedA, articles: [first])
    try await store.upsert(feed: feedB, articles: [second])

    let matches = try await store.listStoryBorderlineMatches()
    let match = try #require(matches.first)
    #expect(matches.count == 1)
    #expect(match.articleID == second.id)
    #expect(match.confidence >= 0.58)
    #expect(match.confidence < 0.68)
    #expect(try await store.listStories().count == 2)
}

@Test func rankingUsesDistinctSourcesAndProtectsUniqueFinds() {
    let clusterer = StoryClusterer()
    let now = Date(timeIntervalSince1970: 100_000)
    let repeatedSingleSource = rankingCandidate(
        id: "story-volume",
        feedID: "feed-volume",
        distinctFeedCount: 1,
        articleCount: 100,
        lastActivityAt: now
    )
    let independentlyCovered = rankingCandidate(
        id: "story-sources",
        feedID: "feed-source",
        distinctFeedCount: 2,
        articleCount: 2,
        lastActivityAt: now
    )
    let trueSingleton = rankingCandidate(
        id: "story-singleton",
        feedID: "feed-singleton",
        distinctFeedCount: 1,
        articleCount: 1,
        lastActivityAt: now
    )
    var hidden = rankingCandidate(
        id: "story-hidden",
        feedID: "feed-hidden",
        distinctFeedCount: 10,
        articleCount: 10,
        lastActivityAt: now
    )
    hidden.preferenceSignal = 100
    hidden.isHidden = true

    let result = clusterer.rank(
        [repeatedSingleSource, independentlyCovered, trueSingleton, hidden],
        asOf: now
    )

    #expect(result.topStories.map(\.storyID) == ["story-sources", "story-volume"])
    #expect(result.uniqueFinds.map(\.storyID) == ["story-singleton"])
    #expect(result.uniqueFinds.first?.isUniqueFind == true)
    #expect(result.topStories.first!.score > result.topStories.last!.score)
    #expect(result.topStories.last?.isUniqueFind == false)
    #expect(!result.topStories.map(\.storyID).contains(hidden.story.id))
}

@Test func rankingAppliesRepresentativeFeedDiversityWithStableTies() {
    let clusterer = StoryClusterer()
    let now = Date(timeIntervalSince1970: 200_000)
    let candidates = [
        rankingCandidate(id: "story-a", feedID: "feed-one", distinctFeedCount: 2, articleCount: 2, lastActivityAt: now),
        rankingCandidate(id: "story-b", feedID: "feed-one", distinctFeedCount: 2, articleCount: 2, lastActivityAt: now),
        rankingCandidate(id: "story-c", feedID: "feed-one", distinctFeedCount: 2, articleCount: 2, lastActivityAt: now),
        rankingCandidate(id: "story-d", feedID: "feed-two", distinctFeedCount: 2, articleCount: 2, lastActivityAt: now)
    ]
    let result = clusterer.rank(
        candidates,
        asOf: now,
        configuration: StoryRankingConfiguration(
            topStoryLimit: 4,
            uniqueFindLimit: 1,
            maximumStoriesPerRepresentativeFeed: 2
        )
    )

    #expect(result.topStories.map(\.storyID) == ["story-a", "story-b", "story-d"])
}

@Test func incrementalReprocessingIsDeterministicAndRawFeedInvariant() async throws {
    let store = try temporaryStore()
    let feedA = Feed(id: "feed-a", title: "Feed A", url: URL(string: "https://a.example/rss")!)
    let feedB = Feed(id: "feed-b", title: "Feed B", url: URL(string: "https://b.example/rss")!)
    let first = clusteringArticle(
        id: "deterministic-a",
        feedID: feedA.id,
        feedTitle: feedA.title,
        title: "Acme launches solar battery for homes",
        content: "The product starts shipping this month in cities.",
        timestamp: 5_000
    )
    let second = clusteringArticle(
        id: "deterministic-b",
        feedID: feedB.id,
        feedTitle: feedB.title,
        title: "Acme launches home solar battery nationwide",
        content: "The product begins shipping this month in cities.",
        timestamp: 5_100
    )
    try await store.upsert(feed: feedA, articles: [first])
    try await store.upsert(feed: feedB, articles: [second])

    let rawBefore = try await store.listArticles(filter: ArticleFilter())
    let storiesBefore = try await store.listStories()
    let story = try #require(storiesBefore.first)
    let membershipsBefore = try await store.listStoryMemberships(storyID: story.id)
    let revisionsBefore = try await store.listStoryRevisions(storyID: story.id)

    let borderlines = try await store.clusterArticles([second, first])

    #expect(borderlines.isEmpty)
    #expect(try await store.listArticles(filter: ArticleFilter()) == rawBefore)
    #expect(try await store.listStories() == storiesBefore)
    #expect(try await store.listStoryMemberships(storyID: story.id) == membershipsBefore)
    #expect(try await store.listStoryRevisions(storyID: story.id) == revisionsBefore)
}

@Test func recurringHeadlineOutsideWindowCreatesANewStory() async throws {
    let store = try temporaryStore()
    let feedA = Feed(id: "feed-a", title: "Feed A", url: URL(string: "https://a.example/rss")!)
    let feedB = Feed(id: "feed-b", title: "Feed B", url: URL(string: "https://b.example/rss")!)
    let first = clusteringArticle(
        id: "wrap-one",
        feedID: feedA.id,
        feedTitle: feedA.title,
        title: "Daily market wrap",
        timestamp: 10_000
    )
    let later = clusteringArticle(
        id: "wrap-two",
        feedID: feedB.id,
        feedTitle: feedB.title,
        title: "Daily market wrap",
        timestamp: 10_000 + (10 * 86_400)
    )

    try await store.upsert(feed: feedA, articles: [first])
    try await store.upsert(feed: feedB, articles: [later])

    let stories = try await store.listStories()
    #expect(stories.count == 2)
    #expect(Set(stories.map(\.id)).count == 2)
    #expect(try await store.listArticles(filter: ArticleFilter()).count == 2)
}

@Test func appSettingsDefaultOfflinePreloadLimit() throws {
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))

    #expect(settings.prefersUnreadOnly == true)
    #expect(settings.offlinePreloadLimit == 300)
}

@Test func importsFeedsIntoStore() async throws {
    let store = try temporaryStore()
    try await store.importFeeds([
        ImportedFeed(title: "One", xmlURL: URL(string: "https://example.com/one.xml")!),
        ImportedFeed(title: "Two", xmlURL: URL(string: "https://example.com/two.xml")!)
    ])

    let feeds = try await store.listFeeds()
    #expect(feeds.map(\.title) == ["One", "Two"])
}

@Test func discoversFeedFromHTMLPage() async throws {
    let store = try temporaryStore()
    MockURLProtocol.responses = [
        "https://example.com/": Data("""
        <!doctype html>
        <html>
          <head>
            <link rel="alternate" type="application/rss+xml" href="/feed.xml">
          </head>
        </html>
        """.utf8),
        "https://example.com/feed.xml": Data("""
        <rss version="2.0">
          <channel>
            <title>Example RSS</title>
            <link>https://example.com</link>
            <item>
              <title>First item</title>
              <link>https://example.com/first</link>
              <description>Hello</description>
            </item>
          </channel>
        </rss>
        """.utf8)
    ]

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    let service = FeedRefreshService(session: session)
    let feed = Feed(id: "feed-1", title: "example.com", url: URL(string: "https://example.com/")!)

    try await service.refresh(feed: feed, store: store)

    let feeds = try await store.listFeeds()
    let articles = try await store.listArticles(filter: ArticleFilter())
    #expect(feeds.first?.title == "Example RSS")
    #expect(feeds.first?.url.absoluteString == "https://example.com/feed.xml")
    #expect(articles.map(\.title) == ["First item"])
}

@Test func parsesArticleImagesFromRSS() throws {
    let rss = """
    <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
      <channel>
        <title>Image Feed</title>
        <item>
          <title>With media</title>
          <link>https://example.com/media</link>
          <media:content url="https://example.com/media.jpg" medium="image" />
        </item>
        <item>
          <title>With HTML image</title>
          <link>https://example.com/html</link>
          <description><![CDATA[<p>Hello</p><img src="https://example.com/html.jpg">]]></description>
        </item>
        <item>
          <title>With enclosure image</title>
          <link>https://example.com/enclosure</link>
          <enclosure url="https://example.com/enclosure.jpg" type="image/jpeg" />
        </item>
        <item>
          <title>With thumbnail</title>
          <link>https://example.com/thumb</link>
          <media:thumbnail url="https://example.com/thumb.jpg" />
        </item>
        <item>
          <title>With lazy image</title>
          <link>https://example.com/lazy</link>
          <description><![CDATA[<p>Hello</p><img data-src="/lazy.jpg">]]></description>
        </item>
      </channel>
    </rss>
    """

    let feed = try FeedParser().parse(data: Data(rss.utf8), fallbackTitle: "fallback")

    #expect(feed.articles.map(\.imageURL?.absoluteString) == [
        "https://example.com/media.jpg",
        "https://example.com/html.jpg",
        "https://example.com/enclosure.jpg",
        "https://example.com/thumb.jpg",
        "https://example.com/lazy.jpg"
    ])
}

@Test func parsesAtomPreviewImages() throws {
    let atom = """
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Atom Feed</title>
      <entry>
        <title>With enclosure link</title>
        <link rel="alternate" href="https://example.com/entry" />
        <link rel="enclosure" type="image/png" href="https://example.com/entry.png" />
        <summary>Atom summary</summary>
      </entry>
      <entry>
        <title>With content srcset</title>
        <link rel="alternate" href="https://example.com/srcset" />
        <content type="html"><![CDATA[<img srcset="/small.jpg 1x, /large.jpg 2x">]]></content>
      </entry>
    </feed>
    """

    let feed = try FeedParser().parse(data: Data(atom.utf8), fallbackTitle: "fallback")

    #expect(feed.articles.map(\.imageURL?.absoluteString) == [
        "https://example.com/entry.png",
        "https://example.com/small.jpg"
    ])
}

@Test func decodesHTMLEntitiesFromRSS() throws {
    let rss = """
    <rss version="2.0">
      <channel>
        <title>Research &amp; News</title>
        <item>
          <title>Spirit Airlines can&#39;t keep up with oil prices</title>
          <link>https://example.com/spirit</link>
          <description>&amp;#32;submitted by &amp;#32;/u/ControlCAD [link] &amp;amp; [comments]</description>
        </item>
      </channel>
    </rss>
    """

    let feed = try FeedParser().parse(data: Data(rss.utf8), fallbackTitle: "fallback")
    let article = try #require(feed.articles.first)

    #expect(feed.title == "Research & News")
    #expect(article.title == "Spirit Airlines can't keep up with oil prices")
    #expect(article.contentText == "submitted by /u/ControlCAD [link] & [comments]")
}

@Test func extractsRedditExternalArticleFromRSSDescription() throws {
    let commentsURL = "https://www.reddit.com/r/swift/comments/abc123/example_post/"
    let article = ParsedArticle(
        guid: nil,
        title: "Example Reddit Link",
        url: URL(string: commentsURL),
        author: nil,
        contentText: nil,
        contentHTML: """
        &#32; submitted by &#32;<a href="https://www.reddit.com/user/example">/u/example</a><br/>
        <span><a href="https://example.com/story?x=1&amp;y=2">[link]</a></span>
        <span><a href="\(commentsURL)">[comments]</a></span>
        """,
        imageURL: nil,
        publishedAt: nil
    )

    let urls = AggregatorDetector.externalAndCommentsURL(from: article, kind: .reddit)
    #expect(urls.commentsURL?.absoluteString == commentsURL)
    #expect(urls.externalURL?.absoluteString == "https://example.com/story?x=1&y=2")
}

@Test func resolvesRedditExternalArticleFromJSON() throws {
    let postData: [String: Any] = [
        "is_self": false,
        "url_overridden_by_dest": "https://example.com/from-json?one=1&amp;two=2"
    ]

    let externalURL = AggregatorService.redditExternalURL(from: postData)
    #expect(externalURL?.absoluteString == "https://example.com/from-json?one=1&two=2")
}

private struct StoryContractFixture: Codable, Equatable {
    var story: Story
    var membership: StoryArticleMembership
    var revision: StoryRevision
    var userState: StoryUserState
    var edition: Edition
    var item: EditionItem

    enum CodingKeys: String, CodingKey {
        case story
        case membership
        case revision
        case userState = "user_state"
        case edition
        case item
    }
}

private func clusteringArticle(
    id: String,
    feedID: String,
    feedTitle: String = "Feed",
    title: String,
    content: String? = nil,
    url: String? = nil,
    timestamp: TimeInterval,
    isRead: Bool = false,
    isStarred: Bool = false
) -> Article {
    Article(
        id: id,
        feedID: feedID,
        feedTitle: feedTitle,
        title: title,
        url: url.flatMap(URL.init(string:)),
        contentText: content,
        publishedAt: Date(timeIntervalSince1970: timestamp),
        fetchedAt: Date(timeIntervalSince1970: timestamp),
        isRead: isRead,
        isStarred: isStarred
    )
}

private func rankingCandidate(
    id: String,
    feedID: String,
    distinctFeedCount: Int,
    articleCount: Int,
    lastActivityAt: Date
) -> StoryRankingCandidate {
    StoryRankingCandidate(
        story: Story(
            id: id,
            title: id,
            firstSeenAt: lastActivityAt,
            lastActivityAt: lastActivityAt,
            createdAt: lastActivityAt,
            updatedAt: lastActivityAt
        ),
        representativeFeedID: feedID,
        distinctFeedCount: distinctFeedCount,
        articleCount: articleCount
    )
}

private func operationThrows(_ operation: () async throws -> Void) async -> Bool {
    do {
        try await operation()
        return false
    } catch {
        return true
    }
}

private func temporaryStore() throws -> SkimStore {
    try SkimStore(databaseURL: temporaryStoreURL())
}

private func temporaryStoreURL() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return dir.appendingPathComponent("skim.sqlite")
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let data = Self.responses[url.absoluteString],
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": url.pathExtension == "xml" ? "application/rss+xml" : "text/html"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
