import Foundation
import SkimStoryPolicy
import Testing

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
