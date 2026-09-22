import Foundation

/// Turning an article's raw body into something printable under a headline.
///
/// Story summaries used to be `contentText` truncated at 280 characters, which
/// is why a link-only Hacker News post rendered on the Today page as
/// `[Comments][1]  [1]: https://news.ycombinator.com/item?id=…`. Feeds carry
/// markdown, HTML and bare URLs in their bodies; none of it belongs on a front
/// page. Mirrors `db::story_text` on the desktop side.
public enum StoryText {
    /// Longest printable summary, before the cut falls back to a word boundary.
    static let maxLength = 280
    /// Below this, a "sentence" is an artifact of an abbreviation.
    static let minSentenceLength = 60

    /// A clean one-or-two-sentence excerpt, or an empty string when the body
    /// holds nothing worth printing. Callers fall back to the headline.
    public static func excerpt(_ raw: String) -> String {
        let text = collapseWhitespace(stripMarkup(raw))
        guard !text.isEmpty, !isBareURL(text) else { return "" }
        return truncateAtSentence(text)
    }

    private static func stripMarkup(_ raw: String) -> String {
        var lines: [String] = []
        var inCodeFence = false

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCodeFence.toggle()
                continue
            }
            if inCodeFence || isLinkDefinition(line) { continue }
            lines.append(stripLineMarkers(line))
        }

        let joined = lines.joined(separator: " ")
        return stripBareURLs(decodeEntities(stripHTML(stripLinks(joined))))
    }

    /// A markdown link reference definition: `[1]: https://example.com`.
    private static func isLinkDefinition(_ line: String) -> Bool {
        guard line.hasPrefix("["), let close = line.range(of: "]:") else { return false }
        let label = line[line.index(after: line.startIndex)..<close.lowerBound]
        let target = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return !label.contains("]") && !target.isEmpty
    }

    /// Leading blockquote, heading, list and rule markers.
    private static func stripLineMarkers(_ line: String) -> String {
        var rest = Substring(line)
        while true {
            var trimmed = rest.drop { $0 == ">" || $0 == "#" }
            trimmed = trimmed.drop { $0 == " " }
            if trimmed.hasPrefix("- ") { trimmed = trimmed.dropFirst(2) }
            else if trimmed.hasPrefix("* ") { trimmed = trimmed.dropFirst(2) }
            if trimmed == rest { break }
            rest = trimmed
        }
        if !rest.isEmpty, rest.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
            return ""
        }
        return String(rest)
    }

    /// `![alt](url)` disappears; `[text](url)` and `[text][ref]` keep their text.
    private static func stripLinks(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var index = 0

        while index < chars.count {
            if chars[index] == "!", index + 1 < chars.count, chars[index + 1] == "[",
               let parts = linkParts(chars, open: index + 1) {
                index = parts.after
                continue
            }
            if chars[index] == "[", let parts = linkParts(chars, open: index) {
                out += parts.label
                index = parts.after
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    /// Reads `[label]` plus any `(target)` or `[ref]` after it.
    private static func linkParts(_ chars: [Character], open: Int) -> (label: String, after: Int)? {
        guard let close = (open + 1..<chars.count).first(where: { chars[$0] == "]" }) else { return nil }
        let label = String(chars[(open + 1)..<close])
        var after = close + 1
        if after < chars.count, chars[after] == "(" {
            guard let end = (after + 1..<chars.count).first(where: { chars[$0] == ")" }) else { return nil }
            after = end + 1
        } else if after < chars.count, chars[after] == "[" {
            guard let end = (after + 1..<chars.count).first(where: { chars[$0] == "]" }) else { return nil }
            after = end + 1
        }
        return (label, after)
    }

    private static func stripHTML(_ text: String) -> String {
        var out = ""
        var depth = 0
        for character in text {
            switch character {
            case "<": depth += 1
            case ">": depth = max(0, depth - 1)
            default: if depth == 0 { out.append(character) }
            }
        }
        return out
    }

    private static func decodeEntities(_ text: String) -> String {
        var out = text
        let entities = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–"),
        ]
        for (entity, replacement) in entities {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }

    private static func stripBareURLs(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .filter { !looksLikeURL(String($0)) }
            .joined(separator: " ")
    }

    private static func looksLikeURL(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(
            in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":/.")).inverted
        )
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("www.")
    }

    private static func isBareURL(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count == 1 && looksLikeURL(String(words[0]))
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Cut on the last sentence that ends inside the limit, falling back to a
    /// word boundary with an ellipsis.
    private static func truncateAtSentence(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let clipped = String(text.prefix(maxLength))

        if let end = clipped.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            let sentence = String(clipped[clipped.startIndex...end])
            if sentence.count >= minSentenceLength {
                return sentence.trimmingCharacters(in: .whitespaces)
            }
        }
        if let space = clipped.lastIndex(of: " ") {
            return String(clipped[clipped.startIndex..<space])
                .trimmingCharacters(in: .whitespaces) + "…"
        }
        return clipped.trimmingCharacters(in: .whitespaces) + "…"
    }
}
