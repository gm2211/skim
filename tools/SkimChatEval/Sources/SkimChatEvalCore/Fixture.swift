import Foundation

/// One prior turn of a chat exchange, used to exercise the follow-up /
/// pronoun-resolution case.
public struct ChatEvalPriorTurn: Codable, Sendable, Equatable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// One evaluation case: a synthetic article, a question about it, and the
/// grading rules a good answer must satisfy. Mirrors
/// `shared/fixtures/chat-answer-quality.json`.
public struct ChatEvalCase: Codable, Sendable, Equatable {
    public let name: String
    public let title: String
    public let feed: String
    public let body: String
    public let question: String
    public let summary: String?
    public let priorTurns: [ChatEvalPriorTurn]?

    /// Synonym groups; every group must have at least one member present
    /// (case-insensitively) in the answer.
    public let mustContainAny: [[String]]

    /// Phrases that must never appear (case-insensitively) in the answer.
    public let mustNotContain: [String]

    /// If set, the first sentence of the answer must contain at least one
    /// of these phrases (case-insensitively).
    public let firstSentenceMustContainAny: [String]?

    /// If set, the answer must not exceed this many sentences (or list items).
    public let maxSentences: Int?

    public init(
        name: String,
        title: String,
        feed: String,
        body: String,
        question: String,
        summary: String? = nil,
        priorTurns: [ChatEvalPriorTurn]? = nil,
        mustContainAny: [[String]],
        mustNotContain: [String],
        firstSentenceMustContainAny: [String]? = nil,
        maxSentences: Int? = nil
    ) {
        self.name = name
        self.title = title
        self.feed = feed
        self.body = body
        self.question = question
        self.summary = summary
        self.priorTurns = priorTurns
        self.mustContainAny = mustContainAny
        self.mustNotContain = mustNotContain
        self.firstSentenceMustContainAny = firstSentenceMustContainAny
        self.maxSentences = maxSentences
    }
}

public struct ChatEvalFixture: Codable, Sendable {
    public let note: String
    public let cases: [ChatEvalCase]

    public static func load(from url: URL) throws -> ChatEvalFixture {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ChatEvalFixture.self, from: data)
    }
}
