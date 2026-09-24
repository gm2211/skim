import Foundation
import Testing
@testable import SkimCore

private func evidenceArticle(_ id: String, _ body: String = "Feed excerpt") -> Article {
    Article(id: id, feedID: "feed", feedTitle: "Feed", title: id, contentText: body)
}

@Test func todayEvidenceKeepsFullestTextSourceOrderAndReportLimit() async throws {
    actor Requests {
        var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
    }
    let requests = Requests()
    let articles = [evidenceArticle("cached"), evidenceArticle("feed", String(repeating: "Substantial feed body.", count: 30)), evidenceArticle("fetch"), evidenceArticle("failure"), evidenceArticle("outside")]
    let result = try await TodayReaderEvidence.resolve(articles: articles, limit: 99, cached: { article in
        article.id == "cached" ? String(repeating: "Complete cached article.", count: 30) : article.id == "feed" ? "Short cache" : nil
    }, fetch: { article in
        await requests.add(article.id)
        if article.id == "failure" { throw URLError(.notConnectedToInternet) }
        return "A fetched complete article with facts missing from the feed"
    })
    #expect(result.map(\.id) == ["cached", "feed", "fetch", "failure"])
    #expect(result[0].contentText == String(repeating: "Complete cached article.", count: 30))
    #expect(result[1].contentText == articles[1].contentText)
    #expect(result[2].contentText == "A fetched complete article with facts missing from the feed")
    #expect(result[3].contentText == "Feed excerpt")
    #expect(Set(await requests.ids) == ["fetch", "failure"])
    #expect(articles[2].contentText == "Feed excerpt")
}

@Test func todayEvidenceTimeoutKeepsFeedDespiteUncooperativeLateFetch() async throws {
    let started = ContinuousClock.now
    let result = try await TodayReaderEvidence.resolve(articles: [evidenceArticle("slow")], timeout: .milliseconds(10), cached: { _ in nil }, fetch: { _ in
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.resume(returning: "Late text") }
        }
    })
    #expect(started.duration(to: .now) < .milliseconds(800))
    #expect(result[0].contentText == "Feed excerpt")
}

@Test func todayEvidenceCancellationNeverReturnsFallbackAsSuccess() async throws {
    let task = Task {
        try await TodayReaderEvidence.resolve(articles: [evidenceArticle("cancel")], cached: { _ in nil }, fetch: { _ in
            try await Task.sleep(for: .seconds(5))
            return "Never publish"
        })
    }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Cancelled evidence request unexpectedly succeeded")
    } catch is CancellationError {
    }
}

@Test func todayEvidenceFetchesThinCacheButKeepsSubstantialFeedAtBoundary() async throws {
    actor Requests {
        var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
    }
    let requests = Requests()
    let articles = [evidenceArticle("thin-cache"), evidenceArticle("399", String(repeating: "a", count: 399)), evidenceArticle("400", String(repeating: "b", count: 400)), evidenceArticle("long-feed", String(repeating: "c", count: 10_000))]
    let result = try await TodayReaderEvidence.resolve(articles: articles, cached: { _ in "Thin cache" }, fetch: { article in
        await requests.add(article.id)
        return String(repeating: "Fetched body. ", count: 50)
    })
    #expect(Set(await requests.ids) == ["thin-cache", "399"])
    #expect(result[0].contentText?.hasPrefix("Fetched body.") == true)
    #expect(result[1].contentText?.count ?? 0 > 399)
    #expect(result[2].contentText == articles[2].contentText)
    #expect(result[3].contentText == articles[3].contentText)
}

@Test func readerEvidenceHydrationPreservesIdentityAndCanonicalOrAggregatorURLs() async throws {
    let canonical = URL(string: "https://publisher.example/report")!
    let comments = URL(string: "https://news.ycombinator.com/item?id=42")!
    let ordinary = Article(id: "rss", feedID: "feed", feedTitle: "Publisher", title: "Original headline",
                           url: canonical, author: "Reporter", contentText: "Feed snippet",
                           contentHTML: "<p>Feed snippet</p>", publishedAt: Date(timeIntervalSince1970: 123),
                           isRead: true, isStarred: true)
    var aggregator = ordinary
    aggregator.id = "aggregator"
    aggregator.url = comments
    aggregator.externalURL = canonical
    aggregator.commentsURL = comments
    let fetched = String(repeating: "Full reader evidence. ", count: 30)
    let result = try await TodayReaderEvidence.resolve(articles: [ordinary, aggregator], cached: { _ in nil }, fetch: { article in
        // The loader receives both original URLs, so ordinary RSS and external-link routing
        // can use the same reader loader without replacing stored provenance.
        #expect(article.externalURL ?? article.url == canonical)
        return fetched
    })
    var expectedOrdinary = ordinary
    expectedOrdinary.contentText = fetched.trimmingCharacters(in: .whitespacesAndNewlines)
    var expectedAggregator = aggregator
    expectedAggregator.contentText = expectedOrdinary.contentText
    #expect(result == [expectedOrdinary, expectedAggregator])
}

@Test func readerEvidenceOfflineRetainsFullerThinCacheAndAllMetadata() async throws {
    let original = evidenceArticle("offline", "Feed stub")
    let cached = "Cached reader evidence is fuller than this feed stub."
    let resolved = try await TodayReaderEvidence.resolve(articles: [original], limit: 1,
        cached: { _ in cached }, fetch: { _ in throw URLError(.notConnectedToInternet) })
    var expected = original
    expected.contentText = cached
    #expect(resolved == [expected])
}

@Test func readerEvidencePersistedExtractionSurvivesReopenWithoutRefetch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("reader.sqlite")
    let store = try SkimStore(databaseURL: url)
    let feed = Feed(id: "feed", title: "Feed", url: URL(string: "https://example.com/feed")!)
    let article = evidenceArticle("persisted")
    try await store.upsert(feed: feed, articles: [article])
    let body = String(repeating: "Extracted reader facts. ", count: 30).trimmingCharacters(in: .whitespacesAndNewlines)
    let first = try await TodayReaderEvidence.resolve(articles: [article], limit: 1,
        cached: { _ in nil }, fetch: { _ in body })
    try await store.cacheReaderText(articleID: article.id, url: article.url, text: first[0].contentText!)
    let reopened = try SkimStore(databaseURL: url)
    let offline = try await TodayReaderEvidence.resolve(articles: [article], limit: 1,
        cached: { try? await reopened.cachedReaderText(articleID: $0.id) },
        fetch: { _ in
            Issue.record("Full persisted reader extraction should not refetch")
            throw URLError(.notConnectedToInternet)
        })
    #expect(offline == first)
}
