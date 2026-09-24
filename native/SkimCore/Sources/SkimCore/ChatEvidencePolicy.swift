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
    public static func retrievalQuery(query: String, priorUserQueries: [String], referenceText: String) -> String {
        guard LibraryChatPolicy.isContextualFollowup(query, referenceTexts: [referenceText]) else { return query }
        let topic = LibraryChatPolicy.retrievalTopic(query: query, priorUserQueries: priorUserQueries,
            referenceTexts: [referenceText])
        return (topic.terms + LibraryChatPolicy.topicKeywords(query)).joined(separator: " ")
    }
}
