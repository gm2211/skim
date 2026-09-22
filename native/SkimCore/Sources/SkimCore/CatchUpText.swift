import Foundation

/// Rejecting text the model copied out of the prompt instead of writing.
///
/// Weaker models answer a JSON request by returning the example unchanged, or
/// by filling its placeholder with the feed's name ("Short sentence about the
/// Hacker News article"). That parses cleanly, so nothing downstream rejects it
/// and the front page renders a column of template strings. Catch it at the one
/// point where prompt text and model output meet.
///
/// Mirrors `is_placeholder_text` in `commands::ai` on the desktop side.
public enum CatchUpText {
    /// Stems lifted from the examples in the catch-up prompts, plus the shapes
    /// the older one-pass prompt produced.
    private static let placeholderStems = [
        "short sentence",
        "one concrete sentence",
        "one tight sentence",
        "actor does specific thing",
        "what happened with the specifics",
        "a short sentence",
        "brief summary of the article",
        "summary of the article",
        "headline here",
        "your headline",
        "lorem ipsum",
    ]

    public static func isPlaceholder(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return true }
        if placeholderStems.contains(where: { normalized.hasPrefix($0) }) { return true }
        // "... about the Hacker News article", "... about the Finance &
        // economics article" — the placeholder with a feed name dropped in.
        if normalized.contains("about the"), normalized.hasSuffix("article") { return true }
        return false
    }

    /// Lowercased, punctuation dropped, whitespace collapsed — so a trailing
    /// full stop cannot smuggle a placeholder past the check.
    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { word in String(word.filter { $0.isLetter || $0.isNumber }).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
