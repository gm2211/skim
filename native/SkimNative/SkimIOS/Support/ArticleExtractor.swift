import Foundation

/// Lightweight, synchronous HTML → plain-text extractor used for fetching linked
/// articles from aggregator posts (HN, Reddit, Lobsters).
///
/// Strategy (in order):
/// 1. Strip `<script>` / `<style>` / `<nav>` / `<header>` / `<footer>` blocks.
/// 2. Strip noisy HTML attribute values (class, style, data-*, aria-*) so they
///    don't leak into the extracted text.
/// 3. Look for common article body containers: `<article>`, `<main>`,
///    `[role="main"]`, `#content`, `.article-body`, `.post-body`, etc.
/// 4. Strip remaining HTML tags and decode entities.
/// 5. Collapse whitespace.
/// 6. Reject the result if it looks like raw markup / Tailwind CSS fragments.
///
/// This is a best-effort extractor — if the result is too short or looks like
/// markup junk the caller should fall back to a web view.
enum ArticleExtractor {

    enum Error: Swift.Error {
        /// Extracted text contains enough markup-like noise that it is unusable.
        case contentLooksLikeMarkup
    }

    /// Extract the main article body from HTML. Returns plain text.
    /// - Throws: `ArticleExtractor.Error.contentLooksLikeMarkup` when the result
    ///   appears to contain CSS fragments or other markup noise.
    static func extract(from html: String, baseURL: URL) throws -> String {
        var work = html

        // 1. Remove script/style/nav/header/footer blocks entirely
        for tag in ["script", "style", "nav", "header", "footer", "aside", "noscript"] {
            work = removeBlockTags(tag, from: work)
        }

        // 2. Strip noisy attribute values BEFORE tag-stripping so they don't
        //    bleed into the plain-text output. Target: class, style, data-*, aria-*.
        work = stripNoisyAttributes(from: work)

        // 3. Try to isolate the article body container
        if let candidate = extractContainer(from: work), candidate.count > 200 {
            work = candidate
        }

        // 4. Strip tags → plain text, decode entities
        let plain = work
            .strippingHTMLTags()
            .decodingBasicHTMLEntities()
            .collapsingWhitespace()

        // 5. Drop leaked utility-class lines and reject all-garbage output.
        let sanitized = sanitizeReaderText(plain)
        if sanitized.isEmpty || looksLikeMarkup(sanitized) {
            throw Error.contentLooksLikeMarkup
        }

        return sanitized
    }

    /// Removes CSS/attribute fragments that can leak from JS-heavy pages into
    /// reader text. If the whole extraction looks like class-name debris,
    /// returns an empty string so callers can fall back to the web view.
    static func sanitizeReaderText(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.collapsingWhitespace() }
            .filter { !$0.isEmpty && !$0.isTailwindClassFragment }

        let sanitized = lines.joined(separator: "\n\n").collapsingWhitespace()
        return sanitized.isLikelyReaderGarbage ? "" : sanitized
    }

    // MARK: - Garbage detector

    /// Returns true when extracted text contains too many markup/CSS noise signals.
    static func looksLikeMarkup(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        // Pattern 1: Tailwind-style CSS selectors / responsive utilities
        let tailwindPattern = #"\[&>:[^\]]*\]|(?:\]:(?:h-full|w-full|mb-|max-h-|overflow-))|&gt;:"#
        if let regex = try? NSRegularExpression(pattern: tailwindPattern, options: []),
           regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil {
            return true
        }

        // Pattern 2: High ratio of markup/CSS noise characters ([ { &)
        let total = text.unicodeScalars.count
        guard total > 0 else { return false }
        let noiseCount = text.unicodeScalars.filter { $0 == "[" || $0 == "{" || $0 == "&" }.count
        let noiseRatio = Double(noiseCount) / Double(total)
        if noiseRatio > 0.05 {
            return true
        }

        return false
    }

    // MARK: - Helpers

    /// Removes attribute values for class, style, data-*, and aria-* attributes
    /// from the raw HTML so they can't bleed into the extracted text.
    private static func stripNoisyAttributes(from html: String) -> String {
        var result = html
        // Patterns: class="...", style="...", data-foo="...", aria-bar="..."
        // We blank the value (keep the attribute name so tag structure stays valid)
        let attributePatterns: [String] = [
            #"\bclass\s*=\s*"[^"]*""#,
            #"\bclass\s*=\s*'[^']*'"#,
            #"\bstyle\s*=\s*"[^"]*""#,
            #"\bstyle\s*=\s*'[^']*'"#,
            #"\bdata-[^=\s>]+\s*=\s*"[^"]*""#,
            #"\bdata-[^=\s>]+\s*=\s*'[^']*'"#,
            #"\baria-[^=\s>]+\s*=\s*"[^"]*""#,
            #"\baria-[^=\s>]+\s*=\s*'[^']*'"#,
        ]
        for pattern in attributePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: ""
            )
        }
        return result
    }

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

    var isTailwindClassFragment: Bool {
        let lowercased = lowercased()
        if lowercased.contains("[&>:") || lowercased.contains("[&>") {
            return true
        }

        let markers = [
            "first-child]:",
            "last-child]:",
            "rounded-[",
            "h-full w-full",
            "max-h-full",
            "overflow-hidden",
            "class=\"",
            "class='",
            "classname="
        ]
        let markerCount = markers.filter { lowercased.contains($0) }.count
        if markerCount >= 2 { return true }

        let tokens = lowercased.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 3 else { return false }
        let utilityTokens = tokens.filter { token in
            token.contains("]:") ||
                token.contains("[") && token.contains("]") ||
                token.hasPrefix("h-") ||
                token.hasPrefix("w-") ||
                token.hasPrefix("mb-") ||
                token.hasPrefix("max-h-") ||
                token.hasPrefix("overflow-") ||
                token.hasPrefix("rounded-")
        }
        return utilityTokens.count >= 3 && Double(utilityTokens.count) / Double(tokens.count) > 0.45
    }

    var isLikelyReaderGarbage: Bool {
        let lowercased = lowercased()
        if lowercased.contains("[&>:") { return true }

        let tokens = lowercased.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 4 else { return false }
        let classLikeTokens = tokens.filter { token in
            token.contains("]:") ||
                token.contains("[&") ||
                token.hasPrefix("h-") ||
                token.hasPrefix("w-") ||
                token.hasPrefix("mb-") ||
                token.hasPrefix("max-h-") ||
                token.hasPrefix("overflow-") ||
                token.hasPrefix("rounded-")
        }
        return classLikeTokens.count >= 4 && Double(classLikeTokens.count) / Double(tokens.count) > 0.35
    }
}
