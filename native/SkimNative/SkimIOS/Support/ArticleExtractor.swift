import Foundation

/// Lightweight, synchronous HTML → plain-text extractor used for fetching linked
/// articles from aggregator posts (HN, Reddit, Lobsters).
///
/// Strategy (in order):
/// 1. Strip `<script>` / `<style>` / `<nav>` / `<header>` / `<footer>` blocks.
/// 2. Look for common article body containers: `<article>`, `<main>`,
///    `[role="main"]`, `#content`, `.article-body`, `.post-body`, etc.
/// 3. Strip remaining HTML tags and decode entities.
/// 4. Collapse whitespace.
///
/// This is a best-effort extractor — if the result is too short the caller
/// should fall back to a web view.
enum ArticleExtractor {

    /// Extract the main article body from HTML. Returns plain text.
    static func extract(from html: String, baseURL: URL) -> String {
        var work = html

        // 1. Remove script/style/nav/header/footer blocks entirely
        for tag in ["script", "style", "nav", "header", "footer", "aside", "noscript"] {
            work = removeBlockTags(tag, from: work)
        }

        // 2. Try to isolate the article body container
        if let candidate = extractContainer(from: work), candidate.count > 200 {
            work = candidate
        }

        // 3. Strip tags → plain text, decode entities
        let plain = work
            .strippingHTMLTags()
            .decodingBasicHTMLEntities()
            .collapsingWhitespace()

        return plain
    }

    // MARK: - Helpers

    private static func removeBlockTags(_ tag: String, from html: String) -> String {
        let pattern = "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return html
        }
        return regex.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..<html.endIndex, in: html),
            withTemplate: " "
        )
    }

    /// Tries to find a prominent article container by scanning for common selectors.
    private static func extractContainer(from html: String) -> String? {
        // Ordered from most-specific to least-specific
        let patterns: [String] = [
            #"<article\b[^>]*>(.*?)</article>"#,
            #"<main\b[^>]*>(.*?)</main>"#,
            // role="main"
            #"<[a-z]+\b[^>]*\brole\s*=\s*['""]main['""][^>]*>(.*?)</[a-z]+>"#,
            // id="content" / id="article" / id="main-content"
            #"<[a-z]+\b[^>]*\bid\s*=\s*['""](content|article|main.content|article.content)['""][^>]*>(.*?)</[a-z]+>"#,
            // class containing "article-body" / "post-body" / "entry-content" / "story-body"
            #"<[a-z]+\b[^>]*\bclass\s*=\s*['""'][^'""]*(?:article[-_]body|post[-_]body|entry[-_]content|story[-_]body|post[-_]content)[^'""]*['""'][^>]*>(.*?)</[a-z]+>"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }

            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range) else { continue }

            // Last capture group holds the inner content
            let captureIndex = match.numberOfRanges - 1
            guard captureIndex > 0,
                  let innerRange = Range(match.range(at: captureIndex), in: html)
            else { continue }

            let inner = String(html[innerRange])
            let plain = inner.strippingHTMLTags().decodingBasicHTMLEntities().collapsingWhitespace()
            if plain.count > 200 { return inner }
        }
        return nil
    }
}

// MARK: - String helpers (local, not exported)

private extension String {
    func strippingHTMLTags() -> String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    func decodingBasicHTMLEntities() -> String {
        var s = self
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")

        // Numeric entities
        let pattern = #"&#(x?[0-9A-Fa-f]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let matches = regex.matches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)).reversed()
        for match in matches {
            guard match.numberOfRanges == 2,
                  let fullRange = Range(match.range(at: 0), in: s),
                  let valueRange = Range(match.range(at: 1), in: s)
            else { continue }
            let value = s[valueRange]
            let radix = value.lowercased().hasPrefix("x") ? 16 : 10
            let scalarText = radix == 16 ? value.dropFirst() : Substring(value)
            guard let codepoint = UInt32(scalarText, radix: radix),
                  let scalar = UnicodeScalar(codepoint)
            else { continue }
            s.replaceSubrange(fullRange, with: String(scalar))
        }
        return s
    }

    func collapsingWhitespace() -> String {
        replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
