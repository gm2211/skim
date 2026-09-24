import Foundation
import SkimStoryPolicy
import SkimCore
import Testing

@Test func recordedSmallModelFailureCannotBecomeSemanticPlan() throws {
    struct Fixture: Decodable { var response: String }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(
        contentsOf: root.appendingPathComponent("shared/fixtures/semantic-model-failure.json")
    ))
    #expect(throws: (any Error).self) {
        try TodaySemanticPolicy.decode(fixture.response)
    }
}

@Test func semanticPolicyContractCrossesSwiftABI() throws {
    struct Case: Decodable {
        var name: String
        var members: [Double]
        var count: Int
        var assigned: [UInt8]
        var importance: Double
        var confidence: Double
        var valid: Bool
        var base: Double
        var score: Double
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let cases = try JSONDecoder().decode([Case].self, from: Data(
        contentsOf: root.appendingPathComponent("shared/fixtures/semantic-policy.json")
    ))
    for item in cases {
        let valid = item.members.withUnsafeBufferPointer { members in
            item.assigned.withUnsafeBufferPointer { assigned in
                skim_semantic_group_valid(members.baseAddress, members.count, item.count,
                    assigned.baseAddress, assigned.count, item.importance, item.confidence) != 0
            }
        }
        #expect(valid == item.valid, "\(item.name)")
        #expect(skim_semantic_score(item.base, item.importance, item.confidence) == item.score)
    }
    for invalid in [Double.nan, Double.infinity, -Double.infinity] {
        let members = [invalid]
        let assigned: [UInt8] = [0]
        let valid = members.withUnsafeBufferPointer { values in
            assigned.withUnsafeBufferPointer {
                skim_semantic_group_valid(values.baseAddress, values.count, 1,
                    $0.baseAddress, $0.count, 3, 0.9)
            }
        }
        #expect(valid == 0)
    }
}

@Test func sharedPolicyContractCrossesSwiftABI() throws {
    struct Fixture: Decodable {
        struct Match: Decodable {
            var name: String
            var lexical: Double
            var title: Double
            var entities: Bool
            var update: Bool
            var kind: Int32
        }
        struct Rank: Decodable {
            var name: String
            var sources: Int64
            var age: Double
            var window: Double
            var preference: Double
            var score: Double
            var unique: Bool
        }
        var matches: [Match]
        var ranks: [Rank]
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(
        contentsOf: root.appendingPathComponent("shared/fixtures/story-policy.json")
    ))
    for match in fixture.matches {
        let confidence = skim_story_confidence(match.lexical, match.title)
        #expect(skim_story_classify(confidence, match.title, match.entities ? 1 : 0,
            match.update ? 1 : 0, skim_story_default_thresholds()) == match.kind,
            "\(match.name)")
    }
    for rank in fixture.ranks {
        let score = skim_story_score(rank.sources, rank.age, rank.window, rank.preference)
        #expect(abs(score - rank.score) < 1e-12, "\(rank.name)")
        #expect((skim_story_is_unique(rank.sources) != 0) == rank.unique, "\(rank.name)")
    }
}
