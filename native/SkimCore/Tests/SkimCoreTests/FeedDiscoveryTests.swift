import Foundation
import Testing
@testable import SkimCore

@Test func discoveryClassifiesAddressesAndWords() {
    #expect(FeedDiscoveryService.looksLikeURL("theverge.com"))
    #expect(FeedDiscoveryService.looksLikeURL("https://example.com"))
    #expect(FeedDiscoveryService.looksLikeURL("blog.rust-lang.org/feed"))
    #expect(FeedDiscoveryService.looksLikeURL("r/rust"))
    #expect(!FeedDiscoveryService.looksLikeURL("rust programming"))
    #expect(!FeedDiscoveryService.looksLikeURL("rust"))
    #expect(!FeedDiscoveryService.looksLikeURL("v1.2"))
    #expect(FeedDiscoveryService.normalizedInputURL("theverge.com")?.absoluteString == "https://theverge.com")
    #expect(FeedDiscoveryService.normalizedInputURL("r/rust")?.absoluteString == "https://www.reddit.com/r/rust/")
}

@Test func discoveryKnowsSitePatterns() {
    func feeds(_ s: String) -> [String] {
        FeedDiscoveryService.siteSpecificFeeds(for: URL(string: s)!).map(\.absoluteString)
    }
    #expect(feeds("https://www.reddit.com/r/rust/") == ["https://www.reddit.com/r/rust/.rss"])
    #expect(feeds("https://old.reddit.com/u/spez") == ["https://www.reddit.com/user/spez/.rss"])
    #expect(feeds("https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv") == ["https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"])
    #expect(feeds("https://www.youtube.com/playlist?list=PL123") == ["https://www.youtube.com/feeds/videos.xml?playlist_id=PL123"])
    #expect(feeds("https://github.com/rust-lang/rust") == ["https://github.com/rust-lang/rust/releases.atom", "https://github.com/rust-lang/rust/commits.atom"])
    #expect(feeds("https://github.com/gm2211") == ["https://github.com/gm2211.atom"])
    #expect(feeds("https://medium.com/@someone") == ["https://medium.com/feed/@someone"])
    #expect(feeds("https://mastodon.social/@Gargron") == ["https://mastodon.social/@Gargron.rss"])
    #expect(feeds("https://bsky.app/profile/a.bsky.social") == ["https://bsky.app/profile/a.bsky.social/rss"])
    #expect(feeds("https://news.ycombinator.com/").first == "https://news.ycombinator.com/rss")
    #expect(feeds("https://example.com/about").isEmpty)
}

@Test func discoveryReadsAlternateLinks() {
    let html = """
    <html><head>
    <link rel="stylesheet" href="/a.css">
    <link rel="alternate" type="application/rss+xml" title="Posts" href="/feed.xml">
    <link type='application/atom+xml' href='https://cdn.example.com/atom?a=1&amp;b=2' rel='alternate'>
    <link rel="alternate" type="text/html" href="/fr">
    </head></html>
    """
    let links = FeedDiscoveryService.feedLinks(inHTML: html, baseURL: URL(string: "https://example.com/blog/")!)
    #expect(links.map(\.absoluteString) == ["https://example.com/feed.xml", "https://cdn.example.com/atom?a=1&b=2"])

    let youtube = #"<script>{"externalId":"UC1234567890abcdefghijkl"}</script>"#
    let channel = FeedDiscoveryService.feedLinks(inHTML: youtube, baseURL: URL(string: "https://www.youtube.com/@someone")!)
    #expect(channel.map(\.absoluteString) == ["https://www.youtube.com/feeds/videos.xml?channel_id=UC1234567890abcdefghijkl"])
}

@Test func discoveryBuildsPreviewFromFeed() {
    let rss = Data("""
    <?xml version="1.0"?><rss version="2.0"><channel><title>Demo &amp; Co</title><link>https://demo.example</link>
    <item><title>One</title><link>https://demo.example/1</link></item>
    <item><title>Two</title><link>https://demo.example/2</link></item>
    </channel></rss>
    """.utf8)
    let feed = FeedDiscoveryService.discovered(from: rss, feedURL: URL(string: "https://demo.example/feed")!)
    #expect(feed?.title == "Demo & Co")
    #expect(feed?.items.map(\.title) == ["One", "Two"])
    #expect(FeedDiscoveryService.discovered(from: Data("<html><body>hi</body></html>".utf8), feedURL: URL(string: "https://x.org")!) == nil)
}

@Test func discoveryParsesFeedlySearchAndCatalog() throws {
    let json = Data("""
    {"results":[
      {"feedId":"feed/https://www.theverge.com/rss/index.xml","title":"The Verge","website":"https://www.theverge.com","subscribers":1200000,"description":"Tech"},
      {"feedId":"user/123/category/x","title":"not a feed"}
    ]}
    """.utf8)
    let results = FeedDiscoveryService.parseFeedlySearch(json)
    #expect(results.count == 1)
    #expect(results.first?.url.absoluteString == "https://www.theverge.com/rss/index.xml")
    #expect(results.first?.subscribers == 1_200_000)
    #expect(FeedDiscoveryService.parseFeedlySearch(Data("nope".utf8)).isEmpty)

    let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../../shared/feed-catalog.json").standardized
    let catalog = try FeedCatalog(data: Data(contentsOf: catalogURL))
    #expect(catalog.topics.count >= 8)
    #expect(catalog.search("apple").contains { $0.title == "Daring Fireball" })
    #expect(catalog.search("zzzz-nothing").isEmpty)
    #expect(FeedDiscoveryService.sameFeed(URL(string: "http://www.x.org/feed/")!, URL(string: "https://x.org/feed")!))
}
