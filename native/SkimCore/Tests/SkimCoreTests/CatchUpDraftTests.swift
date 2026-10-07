import Foundation
import Testing
@testable import SkimCore

private let body = "The company said on Tuesday that the change would roll out to every customer over the coming weeks."

private func article(_ id: String, _ title: String, _ url: String, _ feed: String, text: String = body, image: String? = nil) -> Article {
    Article(id: id, feedID: feed, feedTitle: feed, title: title, url: URL(string: url),
            contentText: text, imageURL: image.flatMap(URL.init(string:)))
}

@Test func draftGroupsCoverageAndLeadsWithTheMostCarriedStory() {
    let page = CatchUpDraft.frontPage([
        article("a", "Rust 1.94 lands with a faster trait solver", "http://x.com/rust", "Ars Technica"),
        article("b", "EU opens formal probe into cloud egress fees", "http://x.com/eu-1", "Ars Technica", image: "https://cdn.example.com/eu.jpg"),
        article("c", "EU probe targets AWS and Azure cloud egress fees", "http://y.com/eu-2", "The Verge"),
        article("d", "EU opens formal probe into cloud egress fees", "http://x.com/eu-1", "Hacker News", text: ""),
        article("e", "Why I still write Makefiles", "http://z.com/make", "Lobsters"),
    ])
    #expect(page.stories.first?.text == "EU opens formal probe into cloud egress fees")
    #expect(page.stories.first?.articleIndexes == [2, 3, 4])
    #expect(page.stories.map(\.text).count == 3)
    #expect(page.briefs.isEmpty)
}

@Test func draftSpillsPastSixStoriesIntoBriefs() {
    let titles = ["Rust ships a trait solver", "Postgres adds vector indexes", "Apple delays Siri rebuild",
                  "Nvidia faces antitrust probe", "SQLite gains JSONB", "Firefox drops Windows 7",
                  "Kubernetes deprecates Dockershim", "Zig reaches beta", "Linux kernel adopts Rust drivers"]
    let articles = titles.enumerated().map { article("\($0.offset)", $0.element, "http://x.com/\($0.offset)", "Feed \($0.offset)") }
    let page = CatchUpDraft.frontPage(articles)
    #expect(page.stories.count == 6)
    #expect(page.briefs.count == 3)
    #expect(page.briefs.allSatisfy { $0.articleIndexes.count == 1 })
}

@Test func unrelatedHeadlinesSharingVocabularyStayApart() {
    #expect(!CatchUpDraft.sameTopic(
        CatchUpDraft.topicTerms("Apple releases security update for iPhone"),
        CatchUpDraft.topicTerms("Google releases security update for Chrome")))
    #expect(CatchUpDraft.sameTopic(
        CatchUpDraft.topicTerms("OpenAI launches GPT-5 with longer context"),
        CatchUpDraft.topicTerms("GPT-5 launches: OpenAI's new model gets longer context")))
}
