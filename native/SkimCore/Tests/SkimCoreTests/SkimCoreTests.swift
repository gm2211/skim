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
        publishedAt: Date(timeIntervalSince1970: 100)
    )

    try await store.upsert(feed: feed, articles: [article])

    let unread = try await store.listArticles(filter: ArticleFilter(readState: .unread))
    #expect(unread.map(\.id) == ["article-1"])
    #expect(try await store.countUnread(feedID: nil) == 1)

    try await store.setArticleRead(id: "article-1", isRead: true)
    #expect(try await store.countUnread(feedID: nil) == 0)

    try await store.toggleStar(id: "article-1")
    let starred = try await store.listArticles(filter: ArticleFilter(starredOnly: true))
    #expect(starred.first?.isStarred == true)
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
      </channel>
    </rss>
    """

    let feed = try FeedParser().parse(data: Data(rss.utf8), fallbackTitle: "fallback")

    #expect(feed.articles.map(\.imageURL?.absoluteString) == [
        "https://example.com/media.jpg",
        "https://example.com/html.jpg"
    ])
}

private func temporaryStore() throws -> SkimStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = dir.appendingPathComponent("skim.sqlite")
    return try SkimStore(databaseURL: url)
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
