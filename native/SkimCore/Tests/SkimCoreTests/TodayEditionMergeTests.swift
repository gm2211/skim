import Foundation
import Testing
@testable import SkimCore

private func mergeEdition() -> TodayEditionSnapshot {
    let date = Date(timeIntervalSince1970: 100)
    let edition = Edition(id: "edition", title: "Today", scope: "all", storyLimit: 5, status: .ready,
        startsAt: date, endsAt: date.addingTimeInterval(86_400), totalSourceCount: 1)
    let item = TodayEditionItem(snapshot: EditionItem(editionID: edition.id, storyID: "story", storyRevisionNumber: 1,
        position: 0, section: "top_stories", snapshotTitle: "Headline", snapshotSummary: "Excerpt", snapshotSourceCount: 1),
        revision: StoryRevision(storyID: "story", revisionNumber: 1, title: "Headline", summary: "Excerpt", sourceCount: 1),
        representativeArticleID: "article", memberArticleIDs: ["article"], sourceArticles: [])
    return TodayEditionSnapshot(edition: edition, items: [item], consumedItemCount: 0, totalItemCount: 1)
}

@Test func todayMutationResponsesPreserveReadStateAndLedesInBothArrivalOrders() {
    let original = mergeEdition()
    var summary = original
    summary.items[0].snapshot.lede = "New written summary"
    summary.items[0].snapshot.ledeSourceArticleID = "article"
    summary.items[0].snapshot.ledeSourceEvidenceHash = String(repeating: "a", count: 64)
    var consumed = original
    consumed.items[0].snapshot.isConsumed = true
    consumed.items[0].snapshot.consumedAt = Date(timeIntervalSince1970: 200)
    consumed.consumedItemCount = 1
    consumed.progress = 1
    consumed.edition.status = .completed
    consumed.edition.completedAt = Date(timeIntervalSince1970: 200)
    let summaryLast = TodayEditionMerge.ledes(current: consumed, response: summary)
    let consumedLast = TodayEditionMerge.consumption(current: summary, response: consumed)
    for result in [summaryLast, consumedLast] {
        #expect(result.items[0].snapshot.lede == "New written summary")
        #expect(result.items[0].snapshot.ledeSourceArticleID == "article")
        #expect(result.items[0].snapshot.ledeSourceEvidenceHash == summary.items[0].snapshot.ledeSourceEvidenceHash)
        #expect(result.items[0].snapshot.isConsumed)
        #expect(result.items[0].snapshot.consumedAt == consumed.items[0].snapshot.consumedAt)
        #expect(result.consumedItemCount == 1)
        #expect(result.progress == 1)
        #expect(result.edition.status == .completed)
        #expect(result.edition.completedAt == consumed.edition.completedAt)
        #expect(result.items[0].memberArticleIDs == ["article"])
    }
    let reopened = TodayEditionMerge.consumption(current: summaryLast, response: original)
    #expect(!reopened.items[0].snapshot.isConsumed)
    #expect(reopened.progress == 0)
    #expect(reopened.items[0].snapshot.lede == "New written summary")
}

@Test func todayMutationMergesIgnoreBlankLedesAndForeignEditions() {
    let original = mergeEdition()
    var written = original
    written.items[0].snapshot.lede = "Keep this summary"
    var blank = original
    blank.items[0].snapshot.lede = " \n "
    #expect(TodayEditionMerge.ledes(current: written, response: blank) == written)
    #expect(TodayEditionMerge.consumption(current: written, response: blank).items[0].snapshot.lede == "Keep this summary")
    var foreign = original
    foreign.edition.id = "tomorrow"
    #expect(TodayEditionMerge.ledes(current: written, response: foreign) == written)
    #expect(TodayEditionMerge.consumption(current: written, response: foreign) == written)
}
