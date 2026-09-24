import Foundation
import SkimStoryPolicy
import Testing
@testable import SkimCore

@Test func libraryChatRankingMatchesSharedFixture() throws {
    struct Case: Decodable {
        var name: String
        var title_terms: UInt32
        var url_terms: UInt32
        var source_terms: UInt32
        var body_terms: UInt32
        var rank: Int32
    }
    let fixture = try JSONDecoder().decode([Case].self, from: Data(contentsOf: chatFixtureURL()))
    for item in fixture {
        #expect(LibraryChatPolicy.rank(
            titleTerms: item.title_terms,
            urlTerms: item.url_terms,
            sourceTerms: item.source_terms,
            bodyTerms: item.body_terms
        ) == item.rank, "\(item.name)")
    }
}

@Test func libraryChatFollowupsReusePriorTopicAndRecognizeSourceNamedSubject() {
    let prior = "Why is the Cedar bridge delayed?"
    let followup = LibraryChatPolicy.retrievalTopic(
        query: "How does it compare?",
        priorUserQueries: [prior]
    )
    #expect(followup.terms == LibraryChatPolicy.topicKeywords(prior))
    #expect(!followup.allowRecentFallback)
    #expect(LibraryChatPolicy.isContextualFollowup(
        "What does that ruling require by October 12?",
        referenceTexts: ["Title: County ruling on the Cedar bridge project"]
    ))
    #expect(!LibraryChatPolicy.isContextualFollowup(
        "What does that quasar mean?",
        referenceTexts: ["Title: County ruling on the Cedar bridge project"]
    ))
    #expect(!LibraryChatPolicy.isContextualFollowup(
        "Find what does that ruling require?",
        referenceTexts: ["Title: County ruling on the Cedar bridge project"]
    ))
    #expect(LibraryChatPolicy.topicKeywords("How does that compare with solar power?") == ["solar", "power"])
}

@Test func libraryChatQueryExcerptFindsLaterWholeWordOccurrenceAndPreservesText() {
    let source = "daily " + String(repeating: "filler ", count: 36) + "AI evidence appears here."
    let excerpt = LibraryChatPolicy.queryExcerpt(text: source, query: "AI", maxCharacters: 100)
    #expect(excerpt.contains("AI evidence appears here."))
    #expect(excerpt.unicodeScalars.count <= 100)
    for passage in excerpt.components(separatedBy: "\n…\n") { #expect(source.contains(passage)) }
}

@Test func libraryChatSearchScansPastFiveHundredRowsAndRanksFullCoverageFirst() async throws {
    let store = try temporaryChatStore()
    let feed = Feed(id: "feed", title: "Harbor Desk", url: URL(string: "https://harbor.example/rss")!)
    var articles: [Article] = []
    for index in 0..<520 {
        articles.append(Article(
            id: "partial-\(index)",
            feedID: feed.id,
            feedTitle: feed.title,
            title: "Cedar bulletin \(index)",
            contentText: "A routine update with no bridge reference.",
            publishedAt: Date(timeIntervalSince1970: TimeInterval(10_000 + index))
        ))
    }
    articles.append(Article(
        id: "old-full-match",
        feedID: feed.id,
        feedTitle: feed.title,
        title: "Cedar Valley bridge project updated",
        contentText: "The old report concerns the Cedar Valley bridge schedule.",
        publishedAt: Date(timeIntervalSince1970: 1)
    ))
    try await store.upsert(feed: feed, articles: articles)

    let oldPrefix = try await store.listArticles(filter: ArticleFilter(limit: 500))
    #expect(oldPrefix.count == 500)
    #expect(!oldPrefix.contains(where: { $0.id == "old-full-match" }))

    let matches = try await store.searchArticlesForChat(
        filter: ArticleFilter(limit: 500),
        feedIDs: nil,
        terms: ["cedar", "bridge"],
        allowRecentFallback: false,
        limit: 15
    )
    #expect(matches.count == 15)
    #expect(matches.first?.id == "old-full-match")
    #expect(matches.contains(where: { $0.id == "old-full-match" }))
}

@Test func libraryChatSearchPreservesRSSAndReaderCacheMatchesAndHydratesBestEvidence() async throws {
    let store = try temporaryChatStore()
    let feed = Feed(id: "feed", title: "Reader Desk", url: URL(string: "https://reader.example/rss")!)
    let cached = Article(
        id: "cached",
        feedID: feed.id,
        feedTitle: feed.title,
        title: "General report",
        url: URL(string: "https://reader.example/report"),
        contentText: "RSS body has the distinct rssneedle term.",
        publishedAt: Date(timeIntervalSince1970: 10)
    )
    let html = Article(
        id: "html",
        feedID: feed.id,
        feedTitle: feed.title,
        title: "Markup report",
        contentHTML: "<p>Only markup contains <strong>htmlneedle</strong>.</p>",
        publishedAt: Date(timeIntervalSince1970: 9)
    )
    let escapedMarkup = Article(
        id: "escaped-markup",
        feedID: feed.id,
        feedTitle: feed.title,
        title: "Literal markup report",
        contentHTML: "<p>Use &lt;vector&gt; for the index.</p>",
        publishedAt: Date(timeIntervalSince1970: 8)
    )
    try await store.upsert(feed: feed, articles: [cached, html, escapedMarkup])
    try await store.cacheReaderText(
        articleID: cached.id,
        url: cached.url,
        text: "Full reader article with the unique cacheneedle phrase and substantial supporting detail."
    )

    let cacheMatch = try await store.searchArticlesForChat(
        filter: ArticleFilter(), feedIDs: nil, terms: ["cacheneedle"], allowRecentFallback: false
    )
    #expect(cacheMatch.map(\.id) == ["cached"])
    #expect(cacheMatch[0].contentText?.contains("cacheneedle") == true)

    let rssMatch = try await store.searchArticlesForChat(
        filter: ArticleFilter(), feedIDs: nil, terms: ["rssneedle"], allowRecentFallback: false
    )
    #expect(rssMatch.map(\.id) == ["cached"])
    #expect(rssMatch[0].contentText?.contains("rssneedle") == true)

    let htmlMatch = try await store.searchArticlesForChat(
        filter: ArticleFilter(), feedIDs: nil, terms: ["htmlneedle"], allowRecentFallback: false
    )
    #expect(htmlMatch.map(\.id) == ["html"])
    #expect(htmlMatch[0].contentText?.contains("<strong>") == false)
    #expect(htmlMatch[0].contentText?.contains("htmlneedle") == true)

    let escapedMarkupMatch = try await store.searchArticlesForChat(
        filter: ArticleFilter(), feedIDs: nil, terms: ["vector"], allowRecentFallback: false
    )
    #expect(escapedMarkupMatch.map(\.id) == [escapedMarkup.id])
    #expect(escapedMarkupMatch[0].contentText?.contains("Use <vector> for the index.") == true)

    let fallback = try await store.searchArticlesForChat(
        filter: ArticleFilter(), feedIDs: [feed.id], terms: [], allowRecentFallback: true
    )
    let fallbackMarkup = try #require(fallback.first(where: { $0.id == escapedMarkup.id }))
    #expect(fallbackMarkup.contentText?.contains("Use <vector> for the index.") == true)
}

@Test func libraryChatSearchHonorsEmptyStarredFeedFolderAndReadScopes() async throws {
    let store = try temporaryChatStore()
    let feedA = Feed(id: "feed-a", title: "A", url: URL(string: "https://a.example/rss")!)
    let feedB = Feed(id: "feed-b", title: "B", url: URL(string: "https://b.example/rss")!)
    let articleA = Article(
        id: "a-unread", feedID: feedA.id, feedTitle: feedA.title,
        title: "Scope marker A", author: "ScopeMarker", contentText: "scopeword exact match",
        publishedAt: Date(timeIntervalSince1970: 2), isRead: false, isStarred: false
    )
    let articleB = Article(
        id: "b-read-starred", feedID: feedB.id, feedTitle: feedB.title,
        title: "Scope marker B", contentText: "scopeword exact match",
        publishedAt: Date(timeIntervalSince1970: 1), isRead: true, isStarred: true
    )
    try await store.upsert(feed: feedA, articles: [articleA])
    try await store.upsert(feed: feedB, articles: [articleB])

    let emptyStarred = try await store.searchArticlesForChat(
        filter: ArticleFilter(starredOnly: true), feedIDs: [feedA.id], terms: ["scopeword"], allowRecentFallback: false
    )
    #expect(emptyStarred.isEmpty)
    let explicitlyEmpty = try await store.searchArticlesForChat(
        filter: ArticleFilter(), feedIDs: [], terms: ["scopeword"], allowRecentFallback: true
    )
    #expect(explicitlyEmpty.isEmpty)
    let wrongReadState = try await store.searchArticlesForChat(
        filter: ArticleFilter(readState: .unread), feedIDs: [feedB.id], terms: ["scopeword"], allowRecentFallback: false
    )
    #expect(wrongReadState.isEmpty)
    let folderLikeScope = try await store.searchArticlesForChat(
        filter: ArticleFilter(), feedIDs: [feedA.id], terms: ["scopeword"], allowRecentFallback: false
    )
    #expect(folderLikeScope.map(\.id) == [articleA.id])
    let readScoped = try await store.searchArticlesForChat(
        filter: ArticleFilter(readState: .read, starredOnly: true), feedIDs: [feedB.id], terms: ["scopeword"], allowRecentFallback: false
    )
    #expect(readScoped.map(\.id) == [articleB.id])
    let preservedSearch = try await store.searchArticlesForChat(
        filter: ArticleFilter(searchQuery: "not-a-metadata-match"), feedIDs: [feedA.id], terms: ["scopeword"], allowRecentFallback: false
    )
    #expect(preservedSearch.isEmpty)
    let authorSearch = try await store.searchArticlesForChat(
        filter: ArticleFilter(searchQuery: "ScopeMarker"), feedIDs: [feedA.id], terms: ["scopeword"], allowRecentFallback: false
    )
    #expect(authorSearch.map(\.id) == [articleA.id])
}

private func chatFixtureURL() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("shared/fixtures/chat-ranking.json")
}

private func temporaryChatStore() throws -> SkimStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return try SkimStore(databaseURL: directory.appendingPathComponent("skim.sqlite"))
}
