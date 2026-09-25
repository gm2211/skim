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

    // MARK: - Grouping and cleanup
    //
    // Mirrors `same_story_key`, `same_story_url`, `strip_publication_prefix`
    // and `fallback_lede` in `commands::ai` on the desktop side.

    /// A title reduced to what two postings of the same link share, so the copy
    /// on Hacker News and the copy on Lobsters compare equal.
    public static func sameStoryKey(_ title: String) -> String {
        let normalized = normalize(title)
        for prefix in ["show hn ", "ask hn ", "launch hn ", "tell hn "] where normalized.hasPrefix(prefix) {
            return String(normalized.dropFirst(prefix.count))
        }
        return normalized
    }

    /// The link with scheme, `www.`, query, fragment and trailing slash dropped.
    public static func sameStoryURL(_ url: URL?) -> String? {
        guard let url, let host = url.host?.lowercased() else { return nil }
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = url.path.lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return bareHost + path
    }

    /// Feeds whose name a model likes to glue onto the front of a headline.
    private static let aggregatorNames = ["hacker news", "lobsters", "lobste.rs", "reddit", "slashdot"]

    /// Common headline verbs: a name followed by one was the story's subject
    /// ("Reddit bans ..."), not a label, and stays.
    private static let headlineVerbs: Set<String> = [
        "is", "was", "has", "adds", "bans", "launches", "releases", "ships", "announces", "buys",
        "sues", "cuts", "raises", "removes", "changes", "shuts", "goes", "gets", "says", "blocks",
        "introduces", "updates", "drops", "wins", "loses", "hires", "fires", "faces", "plans",
    ]

    /// The headline without a publication's name stuck to its front ("Hacker
    /// News back-and-shoulder surgery is often worse than useless"). The sources
    /// are cited under the story, so the name only reads as the subject.
    public static func stripPublicationPrefix(_ headline: String, publications: [String]) -> String {
        let trimmed = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let names = (publications.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } + aggregatorNames)
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        let separators: Set<Character> = [" ", ":", "-", "|", "\u{2013}", "\u{2014}"]
        for name in names where lower.hasPrefix(name) {
            let rest = lower.dropFirst(name.count)
            // Whole-word matches only: "Reddit" must not eat "Redditors".
            guard let next = rest.first, separators.contains(next) else { continue }
            let remainder = String(trimmed.dropFirst(name.count).drop { $0.isWhitespace || separators.contains($0) })
            let words = remainder.split(whereSeparator: \.isWhitespace)
            let first = words.first.map { String($0).lowercased().filter { $0.isLetter || $0.isNumber } } ?? ""
            if words.count < 3 || headlineVerbs.contains(first) { return trimmed }
            return remainder.prefix(1).uppercased() + remainder.dropFirst()
        }
        return trimmed
    }

    /// A lede for when no verified passage could be selected: the first clean
    /// excerpt among the story's articles. Empty when every body is link-only,
    /// so the story prints its headline and sources rather than `[Comments][1]`.
    public static func fallbackLede(_ bodies: [String]) -> String {
        for body in bodies {
            let text = StoryText.excerpt(body)
            // What survives stripping a link-only post is its link label.
            if text.split(whereSeparator: \.isWhitespace).count >= 6 { return text }
        }
        return ""
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
