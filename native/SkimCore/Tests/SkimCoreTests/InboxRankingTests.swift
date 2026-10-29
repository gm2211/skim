import Foundation
import Testing
import SkimStoryPolicy
@testable import SkimCore

private struct InboxFixture: Decodable {
    struct Weight: Decodable {
        var name: String; var dwell: Double; var opened: Bool; var starred: Bool
        var pinned: Bool; var feedback: Int; var read_unopened: Bool; var weight: Double
    }
    struct Affinity: Decodable { var positive: Double; var negative: Double; var affinity: Double }
    struct Strength: Decodable { var signals: Int; var strength: Double }
    struct Score: Decodable {
        var name: String; var importance: Int; var relevance: Int; var has_ai: Bool
        var affinity: Double; var strength: Double; var pinned: Bool; var age_hours: Double; var score: Double
    }
    struct Priority: Decodable { var importance: Int; var relevance: Int; var priority: Int }
    struct Terms: Decodable { var title: String; var terms: [String] }
    struct StoryPreference: Decodable {
        var name: String; var starred: Int64; var pinned: Bool
        var affinity: Double; var strength: Double; var preference: Double
    }
    var signal_weights: [Weight]
    var affinity: [Affinity]
    var strength: [Strength]
    var scores: [Score]
    var priority: [Priority]
    var story_preference: [StoryPreference]
    var terms: [Terms]
    struct LearnDue: Decodable { var name: String; var new_signals: Int; var hours: Double?; var has_note: Bool; var due: Bool }
    var learn_due: [LearnDue]
}

@Test func inboxRankingMatchesSharedFixture() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixture = try JSONDecoder().decode(InboxFixture.self, from: Data(
        contentsOf: root.appendingPathComponent("shared/fixtures/inbox-ranking.json")))
    for c in fixture.signal_weights {
        let w = InboxRanking.weight(.init(dwellSeconds: c.dwell, opened: c.opened, starred: c.starred,
                                          pinned: c.pinned, feedback: c.feedback, readUnopened: c.read_unopened))
        #expect(abs(w - c.weight) < 1e-9, "\(c.name)")
    }
    for c in fixture.affinity {
        #expect(abs(InboxRanking.affinity(positive: c.positive, negative: c.negative) - c.affinity) < 1e-9)
    }
    for c in fixture.strength {
        #expect(abs(InboxRanking.learningStrength(signals: c.signals) - c.strength) < 1e-9)
    }
    for c in fixture.scores {
        let s = InboxRanking.score(importance: c.has_ai ? c.importance : nil,
                                   relevance: c.has_ai ? c.relevance : nil,
                                   affinity: c.affinity, strength: c.strength,
                                   pinned: c.pinned, ageHours: c.age_hours)
        #expect(abs(s - c.score) < 1e-9, "\(c.name)")
    }
    for c in fixture.priority {
        #expect(InboxRanking.priority(importance: c.importance, relevance: c.relevance) == c.priority)
    }
    for c in fixture.story_preference {
        let p = skim_story_preference(c.starred, c.pinned ? 1 : 0, c.affinity, c.strength)
        #expect(abs(p - c.preference) < 1e-9, "\(c.name)")
    }
    for c in fixture.terms {
        #expect(InboxRanking.terms(c.title) == c.terms)
    }
    for c in fixture.learn_due {
        #expect(InboxRanking.learnDue(newSignals: c.new_signals, hoursSinceUpdate: c.hours, hasNote: c.has_note) == c.due, "\(c.name)")
    }
    #expect(InboxRanking.triagePrompt.contains("importance"))
    #expect(InboxRanking.learnPrompt.contains("edited the note"))
}

@Test func inboxTasteLearnsFromReadingAndDismissals() {
    var taste = InboxTaste()
    for _ in 0..<4 {
        taste.learn(feedID: "rust", title: "Rust compiler gets faster builds",
                    signal: .init(dwellSeconds: 200, opened: true))
        taste.learn(feedID: "gossip", title: "Celebrity gossip roundup",
                    signal: .init(readUnopened: true))
    }
    #expect(taste.affinity(feedID: "rust", title: "Faster compiler releases") > 0.5)
    #expect(taste.affinity(feedID: "gossip", title: "Weekly gossip") < 0)
    #expect(taste.affinity(feedID: "unknown", title: "Nothing in common") == 0)
    #expect(taste.strength > 0)
}
