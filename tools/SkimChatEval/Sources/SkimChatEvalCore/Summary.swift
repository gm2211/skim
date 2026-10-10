import Foundation
import SkimCore
import SkimInferencePolicy

/// One summary case: an article from the chat fixture (by case name), the
/// summary length setting the app would use, and what a faithful summary
/// must and must not say. Mirrors `shared/fixtures/summary-faithfulness.json`.
public struct SummaryEvalCase: Codable, Sendable, Equatable {
    public let name: String
    /// A `ChatEvalCase.name` whose title/feed/body is the article.
    public let article: String
    /// The app's summary length setting: "short", "medium" or "long".
    public let length: String
    public let mustContainAny: [[String]]
    public let mustNotContain: [String]
    /// Numbers a summary may use that the article only implies ("a third" -> 33).
    public let allowedNumbers: [String]?

    public init(name: String, article: String, length: String, mustContainAny: [[String]], mustNotContain: [String], allowedNumbers: [String]? = nil) {
        self.name = name
        self.article = article
        self.length = length
        self.mustContainAny = mustContainAny
        self.mustNotContain = mustNotContain
        self.allowedNumbers = allowedNumbers
    }
}

public struct SummaryEvalFixture: Codable, Sendable {
    public let note: String
    public let cases: [SummaryEvalCase]

    public static func load(from url: URL) throws -> SummaryEvalFixture {
        try JSONDecoder().decode(SummaryEvalFixture.self, from: Data(contentsOf: url))
    }
}

public enum SummaryPromptBuilder {
    /// The messages `NativeAI.summarizeStreaming` sends for one article with
    /// default tone and the case's length (instructions from
    /// `AIRequestPolicy.summaryInstructions`, the article as the
    /// `articleDigest` entry, 2200-word excerpt).
    public static func build(article: ChatEvalCase, length: String) -> (messages: [LocalChatMessage], maxTokens: Int, wordCount: Int) {
        let settings = AISettings(summaryLength: length)
        let wordCount = AIRequestPolicy.summaryWordCount(settings)
        let instructions = AIRequestPolicy.summaryInstructions(settings, wordCount: wordCount)
        let words = article.body.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let excerpt = words.count > 2200 ? words.prefix(2200).joined(separator: " ") + "..." : article.body
        let prompt = """
        Article to summarize:

        [1] \(article.title)
        Feed: \(article.feed)
        Author: unknown
        Excerpt: \(excerpt)
        """
        let messages = LocalChatMessages.prepare(system: instructions, user: prompt).map {
            LocalChatMessage(role: $0["role"] ?? "user", content: $0["content"] ?? "")
        }
        return (messages, AIRequestPolicy.summaryPlan(settings).fullMaxTokens, wordCount)
    }
}

public enum SummaryScorer {
    // "one" is left out: it is far more often a pronoun ("one of the") than a count.
    private static let numberWords: [String: String] = [
        "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "dozen": "12",
        "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
        "fifty": "50", "hundred": "100",
    ]

    /// Every number a text states, as digits: "$42.7 million" -> 42.7,
    /// "14,000" -> 14000, "eleven" -> 11, "1920s" -> 1920.
    public static func numbers(in text: String) -> Set<String> {
        var found = Set<String>()
        let lowered = text.lowercased()
        if let regex = try? NSRegularExpression(pattern: "\\d[\\d,]*(?:\\.\\d+)?") {
            let range = NSRange(lowered.startIndex..., in: lowered)
            for match in regex.matches(in: lowered, range: range) {
                guard let r = Range(match.range, in: lowered) else { continue }
                found.insert(lowered[r].replacingOccurrences(of: ",", with: ""))
            }
        }
        for word in lowered.split(whereSeparator: { !$0.isLetter }) {
            if let digits = numberWords[String(word)] { found.insert(digits) }
        }
        return found
    }

    public static func score(summary: String, testCase: SummaryEvalCase, articleBody: String, wordCount: Int) -> ScoreResult {
        var failures: [ScoreFailure] = []
        let lowered = summary.lowercased()

        for group in testCase.mustContainAny where !group.contains(where: { lowered.contains($0.lowercased()) }) {
            failures.append(ScoreFailure(rule: "mustContainAny", detail: "none of \(group) found in summary"))
        }
        for banned in testCase.mustNotContain where lowered.contains(banned.lowercased()) {
            failures.append(ScoreFailure(rule: "mustNotContain", detail: "found banned phrase \"\(banned)\""))
        }

        // Invented numbers are the most common unfaithful detail in small
        // model summaries, and the one a reader is likeliest to repeat.
        let supported = numbers(in: articleBody).union(testCase.allowedNumbers ?? [])
        let unsupported = numbers(in: summary).subtracting(supported).sorted()
        if !unsupported.isEmpty {
            failures.append(ScoreFailure(rule: "unsupportedNumber", detail: "numbers not in the article: \(unsupported)"))
        }

        let words = summary.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        if words > wordCount * 2 {
            failures.append(ScoreFailure(rule: "tooLong", detail: "\(words) words for a \(wordCount)-word summary"))
        }
        if words == 0 {
            failures.append(ScoreFailure(rule: "empty", detail: "no summary text"))
        }

        return ScoreResult(passed: failures.isEmpty, failures: failures)
    }
}
