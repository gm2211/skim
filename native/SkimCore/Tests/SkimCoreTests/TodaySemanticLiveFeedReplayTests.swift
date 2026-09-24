import Foundation
import Testing
@testable import SkimCore

@Test func recordedPublicFeedPipelineSatisfiesIndependentEditorialLabels() throws {
    struct PairLabel: Decodable { let members: [Int] }
    struct ImportanceLabel: Decodable { let higher_index: Int; let lower_index: Int }
    struct Labels: Decodable {
        let must_group_same_event_pairs: [PairLabel]
        let must_separate_different_event_pairs: [PairLabel]
        let importance_comparisons: [ImportanceLabel]
    }
    struct Message: Decodable { let role: String; let content: String }
    struct Request: Decodable { let messages: [Message] }
    struct Fixture: Decodable {
        let candidates: [TodaySemanticCandidate]
        let responses: [String]
        let requests: [Request]
        let editorial_labels: Labels
        let primary_false_group_separations: [[Int]]
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/semantic-live-feed-replay.json")))
    try #require(fixture.responses.count >= 2)
    #expect(fixture.candidates.count == 45)
    let primary = try TodaySemanticPolicy.decode(fixture.responses[0])
    let plan = try TodaySemanticPolicy.verificationPlan(groups: primary, candidates: fixture.candidates)
    #expect(plan.pairs.count == 3)
    var verified = try verifyHistoricalDecisions(fixture.responses[1], plan: plan)
    let splitIDs = verified.indices.filter { verified[$0].needsRating }
    try #require(fixture.responses.count == splitIDs.count + 2)
    try #require(fixture.requests.count == fixture.responses.count)
    for (offset, groupID) in splitIDs.enumerated() {
        let ratingPlan = try #require(try TodaySemanticPolicy.ratingPlan(groups: verified, candidates: fixture.candidates, groupID: groupID))
        let capturedPayload = try #require(fixture.requests[offset + 2].messages.first { $0.role == "user" }?.content)
        let actual = try #require(JSONSerialization.jsonObject(with: Data(ratingPlan.payload.utf8)) as? NSDictionary)
        let captured = try #require(JSONSerialization.jsonObject(with: Data(capturedPayload.utf8)) as? NSDictionary)
        #expect(actual == captured)
        verified = try TodaySemanticPolicy.rate(response: fixture.responses[offset + 2], plan: ratingPlan)
    }
    #expect(verified.allSatisfy { !$0.needsRating })
    #expect(verified.flatMap(\.members).map(Int.init).sorted() == fixture.candidates.map(\.index).sorted())
    func groupIndex(_ handle: Int) throws -> Int {
        try #require(verified.firstIndex { $0.members.contains(Double(handle)) })
    }
    for label in fixture.editorial_labels.must_group_same_event_pairs {
        #expect(try groupIndex(label.members[0]) == groupIndex(label.members[1]))
    }
    for label in fixture.editorial_labels.must_separate_different_event_pairs {
        #expect(try groupIndex(label.members[0]) != groupIndex(label.members[1]))
    }
    #expect(fixture.primary_false_group_separations.count == 2)
    for pair in fixture.primary_false_group_separations {
        #expect(primary.contains { group in pair.allSatisfy { group.members.contains(Double($0)) } })
        #expect(try groupIndex(pair[0]) != groupIndex(pair[1]))
    }
    #expect(fixture.editorial_labels.importance_comparisons.count == 6)
    for label in fixture.editorial_labels.importance_comparisons {
        let higher = try groupIndex(label.higher_index)
        let lower = try groupIndex(label.lower_index)
        #expect(verified[higher].importance > verified[lower].importance)
    }
    // Unlabeled groups are checked for coverage, not claimed editorially correct.
}
