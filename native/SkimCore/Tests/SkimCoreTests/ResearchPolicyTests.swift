import Foundation
import Testing
@testable import SkimCore

@Test func researchPlanReadsJSONInProseAndDropsDuplicateSearches() {
    let plan = ResearchPolicy.plan(
        from: "Sure:\n```json\n{\"topic\": \"Fusion power\", \"library_queries\": [\"fusion\", \"ITER\", \"Fusion\", \"\"]}\n```",
        question: "Where is fusion at?")
    #expect(plan == ResearchPolicy.Plan(topic: "Fusion power", libraryQueries: ["fusion", "ITER"]))
}

@Test func researchPlanFallsBackToTheQuestion() {
    let plan = ResearchPolicy.plan(from: "no json here", question: "fusion reactors")
    #expect(plan == ResearchPolicy.Plan(topic: "fusion reactors", libraryQueries: ["fusion reactors"]))
    let gaps = ResearchPolicy.gaps(from: "{}", topic: "fusion reactors")
    #expect(gaps.webQueries == ["fusion reactors"])
}

@Test func researchGapsCapWebQueries() {
    let gaps = ResearchPolicy.gaps(from: "{\"gaps\": [\"schedule\"], \"web_queries\": [\"a\", \"b\", \"c\", \"d\"]}", topic: "t")
    #expect(gaps.gaps == ["schedule"])
    #expect(gaps.webQueries == ["a", "b", "c"])
}

@Test func researchFusionRanksItemsFoundByMoreSearchesFirst() {
    let fused = ResearchPolicy.fuse(pinned: ["open"], searches: [["a1", "a2"], ["a2", "a3"]], id: { $0 }, limit: 3)
    #expect(fused == ["open", "a2", "a1"])
}

@Test func researchWebCitationsRenumberInReadingOrder() {
    let text = "Late news [w3], your feeds [1], background [w1] and again [w3]. Nothing at [w9]."
    let order = ResearchPolicy.citedWebOrder(in: text, count: 3)
    #expect(order == [3, 1])
    #expect(ResearchPolicy.renumberWeb(text, order: order) == "Late news [w1], your feeds [1], background [w2] and again [w1]. Nothing at.")
}

@Test func researchDomainDropsSchemeAndWWW() {
    #expect(ResearchPolicy.domain("https://www.iter.org/timeline?x=1") == "iter.org")
    #expect(ResearchPolicy.domain("http://127.0.0.1:4545/web/a") == "127.0.0.1:4545")
}
