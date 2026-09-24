import Foundation
import SkimStoryPolicy

/// Query and evidence helpers for native library chat. Search normalization is
/// kept here so the store and the app adapter use the same topic semantics.
public enum LibraryChatPolicy {
    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "by", "for", "from", "with", "about",
        "this", "that", "these", "those", "it", "its", "is", "are", "was", "were", "be", "been", "what", "which",
        "who", "when", "where", "how", "why", "did", "does", "do", "can", "could", "would", "you", "your", "my",
        "me", "our", "we", "i", "find", "search", "show", "look", "looking", "please", "article", "articles",
        "piece", "pieces", "story", "stories", "feed", "feeds", "library", "read", "tell", "more", "catch", "up",
        "them", "they", "say", "said",
    ]

    private static let broadCatchupTerms: Set<String> = [
        "latest", "news", "recent", "today", "today's", "week", "weeks", "week's", "biggest", "important", "top",
        "catchup", "briefing", "brief", "overview", "summarize", "summary", "happening", "new", "missed", "have",
        "has", "happened", "been", "since", "yesterday",
    ]

    private static let operationTerms: Set<String> = [
        "summarize", "summarise", "summary", "explain", "explanation", "compare", "contrast", "changed", "changes",
        "change", "difference", "differences", "expand", "elaborate", "detail", "details", "mean", "means",
    ]

    private static let contextualModifiers: Set<String> = [
        "again", "both", "two", "briefly", "simply", "shorter", "longer", "then", "since",
    ]

    private static let followupPredicates: Set<String> = [
        "compare", "mean", "affect", "matter", "differ", "change", "work", "happen", "help", "relate", "suggest",
        "imply", "show", "tell", "important", "different", "better", "worse", "useful", "possible", "relevant",
        "significant", "surprising", "expensive", "cheaper", "faster", "slower",
    ]

    private static let startsOfContextQuestion: Set<String> = ["how", "why", "what"]
    private static let auxiliaryWords: Set<String> = [
        "does", "do", "did", "is", "are", "was", "were", "would", "will", "can", "could", "should",
    ]

    /// The topic terms and fallback decision used for initial and follow-up
    /// library retrieval. Assistant text is intentionally never an input.
    public static func retrievalTopic(
        query: String,
        priorUserQueries: [String],
        referenceTexts: [String] = []
    ) -> (terms: [String], allowRecentFallback: Bool) {
        let terms = topicKeywords(query)
        if isContextualFollowup(query, referenceTexts: referenceTexts) {
            for previousQuery in priorUserQueries.reversed() {
                if isContextualFollowup(previousQuery) { continue }
                let previous = topicKeywords(previousQuery)
                if !previous.isEmpty || (previousQuery.lowercased().contains("catch") && isBroadCatchup(previousQuery)) {
                    return (previous, isBroadCatchup(previousQuery))
                }
            }
        }
        return (terms, isBroadCatchup(query))
    }

    /// Topic terms for a newly named subject within an otherwise contextual
    /// follow-up. The caller must disable recent fallback for this search.
    public static func topicKeywords(_ query: String) -> [String] {
        var terms = queryKeywords(query)
        if !isFindRequest(query) {
            terms.removeAll(where: operationTerms.contains)
            let words = tokens(query)
            if words.contains(where: { ["this", "that", "these", "those", "it", "them", "they", "then"].contains($0) }) {
                terms.removeAll(where: contextualModifiers.contains)
            }
        }
        return terms
    }

    public static func isContextualFollowup(_ query: String, referenceTexts: [String] = []) -> Bool {
        guard !isFindRequest(query) else { return false }
        if topicKeywords(query).isEmpty {
            return !(query.lowercased().contains("catch") && isBroadCatchup(query))
        }
        let words = tokens(query)
        guard words.count >= 4,
              startsOfContextQuestion.contains(words[0]),
              auxiliaryWords.contains(words[1])
        else { return false }
        switch words[2] {
        case "it", "they": return true
        case "this", "that", "these", "those":
            if followupPredicates.contains(words[3]) { return true }
            guard !referenceTexts.isEmpty else { return false }
            return referenceTexts.prefix(15).contains { termMask(in: $0, terms: [words[3]]) != 0 }
        default: return false
        }
    }

    /// Uses the shared desktop/native C relevance formula.
    public static func rank(titleTerms: UInt32, urlTerms: UInt32, sourceTerms: UInt32, bodyTerms: UInt32) -> Int32 {
        skim_chat_rank(titleTerms, urlTerms, sourceTerms, bodyTerms)
    }

    /// Prefer the full reader cache, then RSS plain text, then a cleaned HTML
    /// body. Returned text is suitable for prompt context and never raw markup.
    static func articleEvidenceText(
        contentText: String?,
        contentHTML: String?,
        readerText: String?,
        terms: [String] = []
    ) -> String? {
        let candidates = [contentText, contentHTML.map(plainTextFromHTMLForSearch), readerText]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !terms.isEmpty {
            return candidates.max {
                let leftCoverage = termMask(in: $0, terms: terms).nonzeroBitCount
                let rightCoverage = termMask(in: $1, terms: terms).nonzeroBitCount
                return leftCoverage == rightCoverage ? $0.count < $1.count : leftCoverage < rightCoverage
            }
        }
        return candidates.max { $0.count < $1.count }
    }

    static func plainTextFromHTMLForSearch(_ contentHTML: String) -> String {
        guard !contentHTML.isEmpty else { return "" }
        let breakTags = try? NSRegularExpression(pattern: "(?i)<\\s*/?\\s*(?:br|p|div|li|h[1-6])\\b[^>]*>")
        let fullRange = NSRange(contentHTML.startIndex..<contentHTML.endIndex, in: contentHTML)
        var plain = breakTags?.stringByReplacingMatches(in: contentHTML, range: fullRange, withTemplate: "\n") ?? contentHTML
        if let tags = try? NSRegularExpression(pattern: "<[^>]*>") {
            let range = NSRange(plain.startIndex..<plain.endIndex, in: plain)
            plain = tags.stringByReplacingMatches(in: plain, range: range, withTemplate: " ")
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, replacement) in entities { plain = plain.replacingOccurrences(of: entity, with: replacement) }
        return plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Exact whole-word matching with a 32-term stable bit assignment.
    static func termMask(in text: String, terms: [String]) -> UInt32 {
        let orderedTerms = Array(terms.prefix(32))
        var positions: [String: Int] = [:]
        for (index, term) in orderedTerms.enumerated() where positions[term] == nil {
            positions[term] = index
        }
        guard !positions.isEmpty else { return 0 }

        var mask: UInt32 = 0
        var token = String.UnicodeScalarView()
        func addToken() {
            guard !token.isEmpty else { return }
            let word = String(token).lowercased()
            if let index = positions[word] { mask |= UInt32(1) << UInt32(index) }
            token = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                token.append(scalar)
            } else {
                addToken()
            }
        }
        addToken()
        return mask
    }

    static func normalizedSearchTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(32)
            .map { $0 }
    }

    /// URLs use substring matching for terms of at least three scalars, which
    /// preserves domain/path matching such as a source slug containing a name.
    static func urlTermMask(in text: String, terms: [String]) -> UInt32 {
        let normalized = text.lowercased()
        var mask: UInt32 = 0
        for (index, term) in terms.prefix(32).enumerated() {
            let match: Bool
            if term.unicodeScalars.count >= 3 {
                match = normalized.range(of: term.lowercased()) != nil
            } else {
                match = termMask(in: text, terms: [term]) != 0
            }
            if match { mask |= UInt32(1) << UInt32(index) }
        }
        return mask
    }

    /// Uses the shared source-span selector without discarding distant evidence.
    public static func queryExcerpt(text: String, query: String, maxCharacters: Int) -> String {
        ChatEvidencePolicy.excerpt(text: text, query: query, maxCharacters: maxCharacters)
    }

    private static func queryKeywords(_ query: String) -> [String] {
        var seen = Set<String>()
        return tokens(query).filter { term in
            term.unicodeScalars.count >= 2 && !stopWords.contains(term) && seen.insert(term).inserted
        }.prefix(32).map { $0 }
    }

    private static func tokens(_ text: String) -> [String] {
        text.split { !CharacterSet.alphanumerics.contains($0.unicodeScalars.first ?? " ") }
            .map { $0.lowercased() }
    }

    private static func isFindRequest(_ query: String) -> Bool {
        let lowered = query.lowercased()
        let words = tokens(lowered)
        return words.contains("find") || words.contains("search")
            || ["look for", "looking for", "which article", "which piece", "show me"].contains(where: lowered.contains)
    }

    private static func isBroadCatchup(_ query: String) -> Bool {
        let terms = queryKeywords(query)
        return !isFindRequest(query) && terms.allSatisfy(broadCatchupTerms.contains)
    }
}
