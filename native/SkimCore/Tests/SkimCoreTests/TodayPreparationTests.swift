import Foundation
import Testing
import SkimStoryPolicy
@testable import SkimCore

@Test func preparationSharedPolicyCorpus() throws {
    struct Verdict: Decodable { let name, response: String; let expected: Int32 }
    struct Proposal: Decodable { let name, response: String; let count: Int; let labels: [Int32]? }
    struct Position: Decodable { let ordinal: UInt64; let window: [Int] }
    struct Window: Decodable { let slots: Int; let count: UInt64; let positions: [Position] }
    struct Partition: Decodable { let count: Int; let edges: [[Int]]; let labels: [Int32]?; let invalid: Bool? }
    struct Importance: Decodable { let ratings, labels: [Int32]; let group, expected: Int32 }
    struct Fixture: Decodable {
        let version: UInt32; let block_size, assessment_output_tokens, proposal_output_tokens: Int
        let assessments: [Verdict]; let proposals: [Proposal]; let windows: [Window]; let partitions: [Partition]; let importance: [Importance]
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/today-preparation-policy.json")))
    #expect(TodayPreparationPolicy.version == f.version)
    #expect(skim_preparation_block_size() == f.block_size)
    #expect(skim_preparation_assessment_output_tokens() == f.assessment_output_tokens)
    #expect(skim_preparation_proposal_output_tokens() == f.proposal_output_tokens)
    for row in f.assessments {
        let result = try? TodayPreparationPolicy.validate(row.response, kind: "assessment", count: 1)
        #expect(result == (row.expected < 0 ? nil : [row.expected]), Comment(rawValue: row.name))
    }
    for row in f.proposals {
        #expect((try? TodayPreparationPolicy.validate(row.response, kind: "proposal", count: row.count)) == row.labels, Comment(rawValue: row.name))
    }
    for row in f.windows {
        #expect(skim_preparation_window_count(row.slots) == row.count)
        for position in row.positions {
            var a = 0, b = 0, c = 0, d = 0
            #expect(skim_preparation_window_at(row.slots, position.ordinal, &a, &b, &c, &d) == 1)
            #expect([a,b,c,d] == position.window)
        }
    }
    for row in f.partitions {
        var labels = [Int32](repeating: -1, count: row.count)
        let left = row.edges.map { $0[0] }, right = row.edges.map { $0[1] }
        let count = skim_preparation_partition(row.count, left, right, left.count, &labels, labels.count)
        #expect(row.invalid == true ? count == 0 : labels == row.labels)
    }
    for row in f.importance {
        #expect(skim_preparation_group_importance(row.ratings, row.labels, row.ratings.count, row.group) == row.expected)
    }
}

private let prepStart = Date(timeIntervalSince1970: 0)
private let prepEnd = Date(timeIntervalSince1970: 86400)
private let prepNow = Date(timeIntervalSince1970: 10000)
private func prepSeed(_ store: SkimStore, indices: Range<Int>) async throws {
    for index in indices {
        let id = String(format: "%04d", index)
        let feed = Feed(id: "feed-" + id, title: "Feed " + id, url: URL(string: "https://example.com/" + id)!)
        let article = Article(id: "article-" + id, feedID: feed.id, feedTitle: feed.title, title: "Report " + id,
            contentText: "Original evidence " + id, publishedAt: prepNow, fetchedAt: prepNow)
        try await store.upsert(feed: feed, articles: [article])
        let story = Story(id: "story-" + id, title: article.title, representativeArticleID: article.id,
            firstSeenAt: prepNow, lastActivityAt: prepNow, createdAt: prepNow, updatedAt: prepNow)
        try await store.upsertStory(story)
        try await store.upsertStoryMembership(StoryArticleMembership(storyID: story.id, articleID: article.id, membershipType: .coverage, addedAt: prepNow))
        try await store.insertStoryRevision(StoryRevision(storyID: story.id, revisionNumber: 1, title: article.title,
            summary: "Short teaser", representativeArticleID: article.id, sourceCount: 1, contentFingerprint: id, isMaterialChange: true, createdAt: prepNow))
    }
}
private func prepReply(_ request: TodayPreparationRequest) throws -> String {
    let object = try #require(JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any])
    if let reports = object["reports"] as? [[String: Any]] {
        let related = reports.indices.filter { ["Report 0000", "Report 0064"].contains(reports[$0]["title"] as? String ?? "") }
        var groups = reports.indices.filter { !related.contains($0) }.map { [$0] }
        if !related.isEmpty { groups.append(related) }
        return try TodayPreparationPolicy.json(["groups": groups])
    }
    if object["report_a"] != nil { return #"{"relation":"same_event"}"# }
    #expect(request.maxTokens == 128)
    return #"{"importance":4}"#
}
private func prepRun(_ store: SkimStore, inference: String = "test") async throws -> TodayPreparationStatus {
    var status = try await store.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: inference)
    for _ in 0..<1000 where status.state == "preparing" {
        status = try await store.prepareTodaySlice(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: inference, requestID: UUID(), request: prepReply)
    }
    return status
}

@Test(arguments: [65, 108, 500]) func preparationCoversEntirePoolAndResumes(count: Int) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SkimStore(databaseURL: url)
    try await prepSeed(store, indices: 0..<count)
    let first = try await store.prepareTodaySlice(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test", requestID: UUID(), request: prepReply)
    #expect(first.assessedCount == 1)
    let reopened = try SkimStore(databaseURL: url)
    #expect(try await reopened.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test").assessedCount == 1)
    let ready = try await prepRun(reopened)
    #expect(ready.state == "ready")
    #expect(ready.assessedCount == count)
    #expect(ready.proposalCompletedCount == Int(skim_preparation_window_count(count)))
    #expect(ready.proposedPairCount == 1 && ready.verifiedPairCount == 1)
    let edition = try await reopened.publishPreparedTodayEdition(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, generatedAt: prepNow, inference: "test", manifest: ready.manifest)
    #expect(edition.items.contains { Set($0.sourceArticles.map(\.articleID)).isSuperset(of: ["article-0000", "article-0064"]) })
    let loaded = try await reopened.getOrGenerateTodayEdition(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, generatedAt: prepNow)
    #expect(loaded.edition.id == edition.edition.id)
    let changedConfig = try await reopened.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "other")
    #expect(changedConfig.assessedCount == 0)
    #expect(try await reopened.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test").assessedCount == count)
    try await prepSeed(reopened, indices: count..<(count + 1))
    #expect(try await reopened.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test").assessedCount == count)
}

@Test func preparationFailureRetriesWithoutLosingCheckpoints() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SkimStore(databaseURL: url)
    try await prepSeed(store, indices: 0..<3)
    var failed = try await store.prepareTodaySlice(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test", requestID: UUID()) { request in
        if request.maxTokens == 128 && request.payload.contains("0001") { return "not a verdict" }
        return try prepReply(request)
    }
    while failed.state == "preparing" {
        failed = try await store.prepareTodaySlice(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test", requestID: UUID()) { request in
            if request.maxTokens == 128 && request.payload.contains("0001") { return "not a verdict" }
            return try prepReply(request)
        }
    }
    #expect(failed.state == "failed" && failed.assessedCount == 2 && failed.assessmentFailedCount == 1)
    let retried = try await store.prepareTodaySlice(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test", requestID: UUID(), retryFailed: true, request: prepReply)
    #expect(retried.state == "ready" && retried.assessedCount == 3)
}

private actor PreparationGate {
    var started = false
    var continuation: CheckedContinuation<String, Never>?
    func response() async -> String { started = true; return await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: #"{"importance":4}"#); continuation = nil }
}
@Test func cancelledPreparationCannotCommitLateProviderResponse() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SkimStore(databaseURL: url)
    try await prepSeed(store, indices: 0..<1)
    let gate = PreparationGate()
    let task = Task {
        try await store.prepareTodaySlice(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test", requestID: UUID()) { _ in await gate.response() }
    }
    while !(await gate.started) { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await gate.release()
    #expect(try await store.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test").assessedCount == 0)
}

@Test func preparationPublicationPreservesFrozenSnapshotsAndExcludesConsumed() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SkimStore(databaseURL: url)
    try await prepSeed(store, indices: 0..<3)
    let original = try await store.getOrGenerateTodayEdition(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, generatedAt: prepNow)
    let consumedID = try #require(original.items.first?.snapshot.storyID)
    let frozen = try await store.setTodayEditionItemConsumed(editionID: original.edition.id, storyID: consumedID, isConsumed: true, at: prepNow)
    let ready = try await prepRun(store)
    let new = try await store.publishPreparedTodayEdition(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, generatedAt: prepNow, inference: "test", manifest: ready.manifest)
    #expect(!new.items.contains { $0.snapshot.storyID == consumedID })
    let old = try #require(try await store.todayEdition(id: original.edition.id))
    #expect(try TodayPreparationPolicy.json(old) == TodayPreparationPolicy.json(frozen))
    let repeated = try await store.publishPreparedTodayEdition(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, generatedAt: prepNow, inference: "test", manifest: ready.manifest)
    #expect(repeated.edition.id == new.edition.id)
    let stale = ready.manifest
    try await prepSeed(store, indices: 3..<4)
    await #expect(throws: (any Error).self) {
        try await store.publishPreparedTodayEdition(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, generatedAt: prepNow, inference: "test", manifest: stale)
    }
}

extension SkimStore {
    func corruptPreparationAssessmentsForTest() throws {
        try db.execute("UPDATE today_preparation_tasks SET result='[]' WHERE kind='assessment'")
    }
}
@Test func preparationRejectsCorruptCacheAndIgnoresPresentationOnlyChanges() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SkimStore(databaseURL: url)
    try await prepSeed(store, indices: 0..<2)
    let ready = try await prepRun(store)
    try await store.toggleStar(id: "article-0000")
    try await store.setArticleRead(id: "article-0000", isRead: true)
    let presentation = try await store.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test", preferences: TodayRankingPreferences(feedWeights: ["feed-0000": 1]))
    #expect(presentation.manifest == ready.manifest)
    #expect(presentation.assessedCount == 2)
    try await store.corruptPreparationAssessmentsForTest()
    let corrupt = try await store.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test")
    #expect(corrupt.assessedCount == 0 && corrupt.state == "preparing" && !corrupt.canPublish)
}

@Test func preparationReintroducesOnlyNewMaterialRevisionAfterConsumption() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SkimStore(databaseURL: url)
    try await prepSeed(store, indices: 0..<1)
    let ready = try await prepRun(store)
    let edition = try await store.publishPreparedTodayEdition(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, generatedAt: prepNow, inference: "test", manifest: ready.manifest)
    _ = try await store.setTodayEditionItemConsumed(editionID: edition.edition.id, storyID: "story-0000", isConsumed: true, at: prepNow)
    #expect(try await store.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test").state == "empty")
    for number in 2...3 {
        try await store.insertStoryRevision(StoryRevision(storyID: "story-0000", revisionNumber: number, title: "Report 0000", summary: "Revision \(number)", representativeArticleID: "article-0000", sourceCount: 1, contentFingerprint: "changed-\(number)", isMaterialChange: number == 3, createdAt: prepNow.addingTimeInterval(Double(number))))
        let status = try await store.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test")
        #expect(status.eligibleCount == (number == 3 ? 1 : 0))
    }
}

@Test func preparationRejectsResponseAfterEvidenceOrInferenceChanges() async throws {
    for configChange in [false, true] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SkimStore(databaseURL: url)
        try await prepSeed(store, indices: 0..<1)
        let gate = PreparationGate()
        let task = Task {
            try await store.prepareTodaySlice(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "test", requestID: UUID()) { _ in await gate.response() }
        }
        while !(await gate.started) { await Task.yield() }
        if configChange {
            _ = try await store.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: "new-model")
        } else {
            let feed = Feed(id: "feed-0000", title: "Feed 0000", url: URL(string: "https://example.com/0000")!)
            let article = Article(id: "article-0000", feedID: feed.id, feedTitle: feed.title, title: "Report 0000", contentText: "Changed original evidence", publishedAt: prepNow, fetchedAt: prepNow)
            try await store.upsert(feed: feed, articles: [article])
        }
        await gate.release()
        if configChange { await #expect(throws: CancellationError.self) { try await task.value } }
        else { #expect(try await task.value.assessedCount == 0) }
        let status = try await store.todayPreparationStatus(startsAt: prepStart, endsAt: prepEnd, storyLimit: 20, inference: configChange ? "new-model" : "test")
        #expect(status.assessedCount == 0)
    }
}
