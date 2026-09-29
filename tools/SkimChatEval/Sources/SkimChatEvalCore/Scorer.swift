import Foundation

/// One failed grading rule.
public struct ScoreFailure: Sendable, Equatable, Codable {
    public let rule: String
    public let detail: String

    public init(rule: String, detail: String) {
        self.rule = rule
        self.detail = detail
    }
}

public struct ScoreResult: Sendable, Equatable {
    public let passed: Bool
    public let failures: [ScoreFailure]

    public init(passed: Bool, failures: [ScoreFailure]) {
        self.passed = passed
        self.failures = failures
    }

    public var firstFailure: ScoreFailure? { failures.first }
}

/// Grades one model answer against a `ChatEvalCase`'s rules. Every rule is
/// checked (not short-circuited) so a report can show every violation, but
/// `firstFailure` (in fixture-declared rule order: mustContainAny,
/// mustNotContain, firstSentenceMustContainAny, maxSentences) is what the
/// per-model table prints.
public enum ChatAnswerScorer {
    /// Lowercases and folds typographic quotes (small on-device models
    /// routinely emit curly `’`/`‘`/`“`/`”` for contractions/quotes even
    /// when the fixture phrase is authored with straight ASCII quotes) so
    /// matching isn't spuriously punished by quote style.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    public static func score(answer: String, testCase: ChatEvalCase) -> ScoreResult {
        var failures: [ScoreFailure] = []
        let normalized = normalize(answer)

        for group in testCase.mustContainAny {
            let matched = group.contains { normalized.contains(normalize($0)) }
            if !matched {
                failures.append(ScoreFailure(
                    rule: "mustContainAny",
                    detail: "none of \(group) found in answer"
                ))
            }
        }

        for banned in testCase.mustNotContain {
            if normalized.contains(normalize(banned)) {
                failures.append(ScoreFailure(
                    rule: "mustNotContain",
                    detail: "found banned phrase \"\(banned)\""
                ))
            }
        }

        if let required = testCase.firstSentenceMustContainAny {
            let first = firstSentence(of: answer)
            let firstNormalized = normalize(first)
            let matched = required.contains { firstNormalized.contains(normalize($0)) }
            if !matched {
                failures.append(ScoreFailure(
                    rule: "firstSentenceMustContainAny",
                    detail: "first sentence \"\(first)\" contains none of \(required)"
                ))
            }
        }

        if let maxSentences = testCase.maxSentences {
            let count = sentenceCount(answer)
            if count > maxSentences {
                failures.append(ScoreFailure(
                    rule: "maxSentences",
                    detail: "answer has \(count) sentences, max is \(maxSentences)"
                ))
            }
        }

        return ScoreResult(passed: failures.isEmpty, failures: failures)
    }

    /// The text through its first sentence-ending punctuation (`.`/`!`/`?`),
    /// or the whole trimmed answer if none is found. A leading markdown
    /// bullet/number marker ("- ", "1. ") is stripped first so a list-style
    /// answer's first item is graded as the "first sentence".
    public static func firstSentence(of text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let markerRange = trimmed.range(of: "^(?:[-*]|\\d+[.)])\\s+", options: .regularExpression) {
            trimmed = String(trimmed[markerRange.upperBound...])
        }
        if let range = trimmed.range(of: "[.!?]", options: .regularExpression) {
            return String(trimmed[trimmed.startIndex..<range.upperBound])
        }
        return trimmed
    }

    /// A simple sentence count: `.`/`!`/`?` terminators followed by
    /// whitespace or end-of-string. When the answer looks like a markdown
    /// list (two or more non-empty "- "/"* "/"1. " lines), each list item
    /// counts as one unit instead, since a well-formed list item often has
    /// no terminal punctuation of its own.
    public static func sentenceCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
        let listLines = lines.filter { line in
            line.trimmingCharacters(in: .whitespaces).range(of: "^(?:[-*]|\\d+[.)])\\s+", options: .regularExpression) != nil
        }
        if listLines.count >= 2 {
            return listLines.count
        }

        guard let regex = try? NSRegularExpression(pattern: "[.!?]+(?=\\s|$)") else { return 1 }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let count = regex.numberOfMatches(in: trimmed, range: range)
        return max(count, 1)
    }
}
