import Foundation
import Testing
@testable import SkimCore

private func primaryCandidates(_ count: Int) -> [TodaySemanticCandidate] {
    (0..<count).map { TodaySemanticCandidate(index: $0, title: "Report \($0)", excerpt: "Report evidence", timestamp: 1723593600, baseScore: 3) }
}

@Test func primaryAcceptsWholeArrayOrEnvelopeWithOneOptionalFence() throws {
    let group = #"{"members":[0,1],"importance":4,"confidence":0.95,"reason":"Same event"}"#
    for response in ["[\(group)]", "{\"groups\":[\(group)]}", "```json\n[\(group)]\n```", "```\n{\"groups\":[\(group)]}\n```"] {
        let decoded = try TodaySemanticPolicy.decode(response)
        #expect(decoded.count == 1)
        #expect(decoded[0].members == [0, 1])
    }
    for response in [group, "[\(group)", "[\(group)] trailing", "Prose {\"groups\":[\(group)]}", "{\"groups\":\(group)}", "{\"groups\":null}", "true", "```json\n[\(group)]", "[\(group),"] {
        #expect(throws: (any Error).self) { try TodaySemanticPolicy.decode(response) }
    }
}

@Test func primaryArrayRetainsTypedValidationAndRejectsOverlappingMembership() throws {
    let response = #"[{"members":[0,1],"importance":4,"confidence":1,"reason":"First event"},{"members":[1,2],"importance":4,"confidence":1,"reason":"Overlapping event"},{"members":[true,2],"importance":4,"confidence":1,"reason":"Invalid handle"},{"members":[2,99],"importance":4,"confidence":1,"reason":"Unknown handle"}]"#
    let plan = try TodaySemanticPolicy.verificationPlan(groups: TodaySemanticPolicy.decode(response), candidates: primaryCandidates(3))
    #expect(plan.pairs == [[0, 1]])
    let verified = try TodaySemanticPolicy.verify(response: #"{"relation":"same_event"}"#, plan: plan)
    #expect(verified.count == 1)
    #expect(verified[0].members == [0, 1])
}

@Test func recordedFortyFiveReportPrimaryArrayReachesVerification() throws {
    struct Fixture: Decodable { let candidate_count: Int; let response: String }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/semantic-primary-array.json")))
    let decoded = try TodaySemanticPolicy.decode(fixture.response)
    #expect(decoded.count == 42)
    let plan = try TodaySemanticPolicy.verificationPlan(groups: decoded, candidates: primaryCandidates(fixture.candidate_count))
    #expect(plan.pairs.count == 3)
    let decisions: [[String: Any]] = plan.pairs.map { ["pair": $0, "same_event": true, "confidence": 1.0] }
    let verified = try verifyHistoricalDecisions(String(decoding: JSONSerialization.data(withJSONObject: decisions), as: UTF8.self), plan: plan)
    #expect(verified.count == 42)
    #expect(verified.flatMap(\.members).map(Int.init).sorted() == Array(0..<45))
}
