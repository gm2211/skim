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

    // Retrying generation with changed snapshot text cannot rewrite history.
    var changedItem = item
    changedItem.snapshotTitle = "A rewritten title"
    changedItem.snapshotSummary = "A rewritten summary"
    try await store.persistEdition(edition, items: [changedItem])
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

@Test func storyAndEditionModelsRoundTripCodableContract() throws {
    let revision = StoryRevision(
        storyID: "story-1",
        revisionNumber: 3,
        title: "Title",
        summary: "Summary",
        deltaSummary: "Delta",
        sourceCount: 4,
        contentFingerprint: "sha256:contract",
        isMaterialChange: true,
        createdAt: Date(timeIntervalSince1970: 1_234)
    )
    let edition = Edition(
        id: "edition-1",
        title: "Today",
        scope: "folder:technology",
        storyLimit: 5,
        status: .completed,
        startsAt: Date(timeIntervalSince1970: 1_000),
        endsAt: Date(timeIntervalSince1970: 2_000),
        generatedAt: Date(timeIntervalSince1970: 1_100),
        completedAt: Date(timeIntervalSince1970: 1_200),
        totalSourceCount: 9
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    #expect(try decoder.decode(StoryRevision.self, from: encoder.encode(revision)) == revision)
    #expect(try decoder.decode(Edition.self, from: encoder.encode(edition)) == edition)
    #expect(StoryMembershipType.allCases.map(\.rawValue) == ["duplicate", "coverage", "update"])
    #expect(EditionStatus.allCases.map(\.rawValue) == ["draft", "ready", "completed", "failed"])
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
