import Foundation
import SkimStoryPolicy

/// Bounded verbatim evidence selected from the complete source by the shared C policy.
public enum ChatEvidencePolicy {
    public static func excerpt(text: String, query: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0, !text.isEmpty else { return "" }
        let source = Array(text.utf8)
        let queryBytes = Array(query.utf8)
        var spans = Array(repeating: SkimEvidenceSpan(), count: 4)
        let count = source.withUnsafeBufferPointer { sourceBuffer in
            queryBytes.withUnsafeBufferPointer { queryBuffer in
                spans.withUnsafeMutableBufferPointer { output in
                    skim_chat_evidence_spans(sourceBuffer.baseAddress, sourceBuffer.count,
                        queryBuffer.baseAddress, queryBuffer.count, maxCharacters, output.baseAddress, output.count)
                }
            }
        }
        guard count <= spans.count else { return "" }
        var passages: [String] = []
        for span in spans.prefix(count) {
            guard span.byte_offset <= source.count,
                  span.byte_length <= source.count - span.byte_offset,
                  let passage = String(bytes: source[span.byte_offset..<(span.byte_offset + span.byte_length)], encoding: .utf8)
            else { return "" }
            passages.append(passage)
        }
        return passages.joined(separator: "\n…\n")
    }

    /// Prior user questions resolve contextual references; assistant output is never evidence.
    ///
    /// The returned string is not term-expanded. `skim_chat_evidence_spans` does
    /// exact casefold matching with no stemming, so a question word such as
    /// "nozzles" will not match a source passage that only says "nozzle". Callers
    /// building the final query passed to `excerpt`/`articleContext` should wrap
    /// it with `expandedQuery(_:)`, e.g. `expandedQuery(retrievalQuery(...))`.
    public static func retrievalQuery(query: String, priorUserQueries: [String], referenceText: String) -> String {
        guard LibraryChatPolicy.isContextualFollowup(query, referenceTexts: [referenceText]) else { return query }
        let topic = LibraryChatPolicy.retrievalTopic(query: query, priorUserQueries: priorUserQueries,
            referenceTexts: [referenceText])
        return (topic.terms + LibraryChatPolicy.topicKeywords(query)).joined(separator: " ")
    }

    /// Appends simple mechanical plural/singular variants (`s`, `es`, `ies`↔`y`)
    /// for each word in `query` so the shared selector's exact, unstemmed
    /// casefold matching also catches near-miss forms (e.g. a question asking
    /// about "nozzles" when the source text only says "nozzle"). Distinct
    /// terms are deduped and the result is capped at 32 terms, matching the
    /// query-term budget of `skim_chat_evidence_spans`. Does not touch the C
    /// selector or the shared chat-evidence contract; this only changes what
    /// query string a Swift caller may choose to pass in.
    public static func expandedQuery(_ query: String) -> String {
        let words = query.split { !CharacterSet.alphanumerics.contains($0.unicodeScalars.first ?? " ") }
            .map { $0.lowercased() }
        var seen = Set<String>()
        var terms: [String] = []
        outer: for word in words {
            for candidate in [word] + pluralVariants(of: word) {
                guard !candidate.isEmpty, seen.insert(candidate).inserted else { continue }
                terms.append(candidate)
                if terms.count >= 32 { break outer }
            }
        }
        return terms.joined(separator: " ")
    }

    /// Simple mechanical plural/singular candidates for a single lowercased word.
    /// Deliberately unconditional and dictionary-free: some candidates will be
    /// nonsense (e.g. "boxees" for "box"), which is harmless as an extra query
    /// term but keeps this from needing a real stemmer.
    private static func pluralVariants(of word: String) -> [String] {
        guard word.count >= 2 else { return [] }
        var variants: [String] = [word + "s", word + "es"]
        if word.hasSuffix("y") {
            variants.append(String(word.dropLast()) + "ies")
        }
        if word.hasSuffix("ies"), word.count > 3 {
            variants.append(String(word.dropLast(3)) + "y")
        }
        if word.hasSuffix("es"), word.count > 2 {
            variants.append(String(word.dropLast(2)))
        }
        if word.hasSuffix("s"), word.count > 1 {
            variants.append(String(word.dropLast()))
        }
        return variants
    }

    /// Byte-identical successor to the inline header formatting that used to
    /// live in `NativeAI.singleArticleChatContext`. Kept pure and non-throwing
    /// so an eval tool can reproduce production chat context deterministically
    /// from the same inputs, and so the app can call it directly once it wires
    /// this in (evidence validation stays the app's concern).
    public static func articleContext(
        title: String,
        feedTitle: String,
        author: String?,
        publishedAt: Date?,
        body: String,
        query: String,
        maxCharacters: Int
    ) -> String {
        let excerptText = body.isEmpty ? "No reader text available."
            : ChatEvidencePolicy.excerpt(text: body, query: query, maxCharacters: maxCharacters)
        return "[1] \(title)\nFeed: \(feedTitle)\nAuthor: \(author ?? "unknown")\n\(AIRequestPolicy.publicationContext(publishedAt))\nExcerpt: \(excerptText)"
    }
}
