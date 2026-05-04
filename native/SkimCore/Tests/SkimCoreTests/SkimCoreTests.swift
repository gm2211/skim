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

private func temporaryStore() throws -> SkimStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = dir.appendingPathComponent("skim.sqlite")
    return try SkimStore(databaseURL: url)
}
