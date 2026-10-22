import Foundation
import Testing
@testable import SkimCore

private func article(_ id: String, feed: String, url: String, minutesAgo: Double) -> Article {
    Article(id: id, feedID: feed, feedTitle: feed, title: "Title \(id)", url: URL(string: url),
            publishedAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
}

@Test func dispatchPoolTakesFeedsInTurnAndDropsRepostedLinks() {
    var articles = (0..<10).map { article("hn\($0)", feed: "hn", url: "https://x.com/\($0)", minutesAgo: Double($0)) }
    articles.append(article("ars", feed: "ars", url: "https://ars.com/a", minutesAgo: 50))
    articles.append(article("lob", feed: "lobsters", url: "https://www.x.com/0/?utm=1", minutesAgo: 60))
    #expect(Dispatch.pool(articles, cap: 4).map(\.id) == ["hn0", "ars", "hn1", "hn2"])
}

@Test func dispatchPlanRanksByImportanceAndRunsEachArticleOnce() throws {
    let pool = (0..<5).map { article("a\($0)", feed: "f", url: "https://e.com/\($0)", minutesAgo: 0) }
    let answer = """
    Here you go: {"themes":[
      {"kicker":"Databases","headline":"DuckDB 2.0 ships","dek":"A release.","importance":2,"articles":[0]},
      {"kicker":"Security","headline":"Two certificate authorities breached","dek":"Trust at stake.","importance":5,"articles":[1,2,9]},
      {"headline":"Duplicate","articles":[1]}
    ],"briefs":[{"text":"Something small.","articles":[3,0]}]}
    """
    let plan = try Dispatch.plan(answer, pool: pool)
    #expect(plan.themes.map(\.headline) == ["Two certificate authorities breached", "DuckDB 2.0 ships"])
    #expect(plan.themes[0].articleIDs == ["a1", "a2"])
    #expect(plan.briefs.map(\.articleIDs) == [["a3"]])
    #expect(throws: Dispatch.Failure.noThemes) { try Dispatch.plan(#"{"themes":[]}"#, pool: pool) }
}

@Test func dispatchPieceKeepsOnlyCitationsOfItsReports() throws {
    let cleaned = Dispatch.cleanCitations("Breach confirmed [1, 7]. Denied [9].", reports: 3)
    #expect(cleaned.text == "Breach confirmed [1]. Denied.")
    #expect(cleaned.kept == 1)
    let piece = try Dispatch.piece(#"```json {"body":["One [1].","Two [2,3]."],"takeaways":["Patch now [1]."]} ```"#, reports: 3)
    #expect(piece.body == ["One [1].", "Two [2, 3]."])
    #expect(piece.takeaways == ["Patch now [1]."])
    #expect(throws: Dispatch.Failure.uncited) { try Dispatch.piece(#"{"body":["No citations."]}"#, reports: 3) }
    #expect(Dispatch.parts("Breached [1]. Confirmed [2, 3].") == [.text("Breached"), .cites([1]), .text(". Confirmed"), .cites([2, 3]), .text(".")])
}

@Test func dispatchWindowsAreWholeLocalDaysSteppingBackOneEditionPerPage() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 13))!
    let front = Dispatch.window(now: now, page: 1, days: 3, calendar: calendar)
    #expect(front.start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 20)))
    #expect(front.end == calendar.date(from: DateComponents(year: 2026, month: 10, day: 23)))
    let back = Dispatch.window(now: now, page: 2, days: 3, calendar: calendar)
    #expect(back.end == front.start)
    #expect(Dispatch.days(5) == 3)
}

@Test func dispatchEditionsAreKeptAndArticlesAreReadByWindow() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try SkimStore(databaseURL: dir.appendingPathComponent("skim.sqlite"))
    let feed = Feed(id: "feed-1", title: "A Feed", url: URL(string: "https://example.com/rss")!)
    let start = Date(timeIntervalSince1970: 1_000_000), end = start.addingTimeInterval(86_400)
    try await store.upsert(feed: feed, articles: [
        Article(id: "in", feedID: "feed-1", feedTitle: "A Feed", title: "In", publishedAt: start.addingTimeInterval(60), fetchedAt: start.addingTimeInterval(7_200)),
        Article(id: "out", feedID: "feed-1", feedTitle: "A Feed", title: "Out", publishedAt: end.addingTimeInterval(60), fetchedAt: end),
    ])
    #expect(try await store.articles(from: start, to: end, limit: 10).map(\.id) == ["in"])
    #expect(try await store.countArticles(from: start, to: end, fetchedAfter: start.addingTimeInterval(3_600)) == 1)
    var edition = DispatchEdition(id: "dispatch-x", days: 1, startsAt: start, endsAt: end, generatedAt: start)
    edition.themes = [.init(kicker: "K", headline: "H", dek: "D", importance: 3, articleIDs: ["in"], body: ["B [1]."])]
    try await store.saveDispatchEdition(edition)
    #expect(try await store.dispatchEdition(id: "dispatch-x") == edition)
}
