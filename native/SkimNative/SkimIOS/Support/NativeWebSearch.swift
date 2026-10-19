// NativeWebSearch.swift
// Skim iOS — DuckDuckGo HTML search scraper.
// Ported from src-tauri/src/commands/chat.rs (run_web_search / parse_ddg_results).

import Foundation

struct SearchResult: Codable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

enum NativeWebSearch {

    /// Fetch and parse DuckDuckGo HTML search results.
    /// - Parameters:
    ///   - query: The search query string.
    ///   - maxResults: Number of results to return; clamped to 1–10.
    /// - Returns: Array of `SearchResult` values, up to `maxResults`.
    static func run(query: String, maxResults: Int) async throws -> [SearchResult] {
        let clampedMax = max(1, min(10, maxResults))

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw URLError(.badURL)
        }
        let urlString = "https://html.duckduckgo.com/html/?q=\(encoded)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""

        let results = parseDDGResults(html)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if results.isEmpty && isDDGChallenge(status: status, html: html) {
            // An empty list reads to the model as "the web has nothing on this";
            // a bot check is a transient block it should report as such.
            throw SearchBlocked()
        }
        return Array(results.prefix(clampedMax))
    }

    struct SearchBlocked: LocalizedError {
        var errorDescription: String? {
            "DuckDuckGo blocked the search with a bot check; try again shortly"
        }
    }

    /// DuckDuckGo answers rapid or bot-like requests with a 202 and an
    /// "anomaly" captcha page instead of results.
    static func isDDGChallenge(status: Int, html: String) -> Bool {
        status == 202 || html.contains("anomaly-modal") || html.contains("bots use DuckDuckGo")
    }

    // MARK: - Private parsing helpers

    static func parseDDGResults(_ html: String) -> [SearchResult] {
        var results: [SearchResult] = []

        // Each result has exactly one `result__a` title link, so walk those
        // anchors rather than the result containers. The container's class
        // list is "links_main links_deep result__body", which a split on
        // `class="result__body` never matched: the whole page became one
        // chunk and only the first result survived.
        var starts: [String.Index] = []
        var cursor = html.startIndex
        while let r = html.range(of: "class=\"result__a\"", range: cursor..<html.endIndex) {
            starts.append(r.lowerBound)
            cursor = r.upperBound
        }

        for (n, start) in starts.enumerated() {
            if results.count >= 10 { break }
            let end = n + 1 < starts.count ? starts[n + 1] : html.endIndex
            // Back up to the anchor's `<` so href is found whichever order
            // the attributes come in.
            let tagStart = html[..<start].lastIndex(of: "<") ?? start
            let chunk = String(html[tagStart..<end])

            // --- title + URL ---
            guard let href = extractAttr(chunk, attr: "href"),
                  let title = extractTagText(chunk, tag: "a") else { continue }

            // Unwrap DDG redirect: …?uddg=<percent-encoded-url>&…
            let actualURL: String
            if let uddgRange = href.range(of: "uddg=") {
                let afterUddg = String(href[uddgRange.upperBound...])
                let raw = afterUddg.components(separatedBy: "&").first ?? afterUddg
                actualURL = raw.removingPercentEncoding ?? raw
            } else {
                actualURL = href
            }

            // Sponsored results link through duckduckgo.com/y.js, not uddg.
            guard actualURL.hasPrefix("http"), !isDDGInternal(actualURL) else { continue }
            guard !results.contains(where: { $0.url == actualURL }) else { continue }

            // --- snippet ---
            let snippet: String
            if let sRange = chunk.range(of: "class=\"result__snippet\"") {
                let afterS = String(chunk[sRange.lowerBound...])
                snippet = extractTagText(afterS, tag: "a") ?? extractInnerText(afterS) ?? ""
            } else {
                snippet = ""
            }

            results.append(SearchResult(
                title: htmlEntitiesDecode(title),
                url: actualURL,
                snippet: htmlEntitiesDecode(snippet)
            ))
        }

        return results
    }

    private static func isDDGInternal(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com")
    }

    /// Extract the value of `attr="…"` from the beginning of `html`.
    private static func extractAttr(_ html: String, attr: String) -> String? {
        let pattern = "\(attr)=\""
        guard let startRange = html.range(of: pattern) else { return nil }
        let afterStart = html[startRange.upperBound...]
        guard let endIdx = afterStart.firstIndex(of: "\"") else { return nil }
        return String(afterStart[..<endIdx])
    }

    /// Extract the inner text of the first `<tag>…</tag>` in `html`, stripping
    /// any nested HTML tags.
    private static func extractTagText(_ html: String, tag: String) -> String? {
        guard let openEnd = html.firstIndex(of: ">") else { return nil }
        let closePattern = "</\(tag)"
        guard let closeRange = html.range(of: closePattern) else { return nil }
        let innerStart = html.index(after: openEnd)
        guard innerStart < closeRange.lowerBound else { return nil }
        let inner = String(html[innerStart..<closeRange.lowerBound])
        let stripped = stripHTMLTags(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// Extract the text between the first `>` and the first `</` in `html`.
    private static func extractInnerText(_ html: String) -> String? {
        guard let openEnd = html.firstIndex(of: ">") else { return nil }
        let rest = html[html.index(after: openEnd)...]
        guard let closeRange = rest.range(of: "</") else { return nil }
        let inner = String(rest[..<closeRange.lowerBound])
        let stripped = stripHTMLTags(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// Remove all `<…>` tags from `s`.
    private static func stripHTMLTags(_ s: String) -> String {
        var result = ""
        var inTag = false
        for ch in s {
            switch ch {
            case "<": inTag = true
            case ">": inTag = false
            default:
                if !inTag { result.append(ch) }
            }
        }
        return result
    }

    /// Decode a minimal set of HTML entities (matching the Rust reference).
    private static func htmlEntitiesDecode(_ s: String) -> String {
        var result = s
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // Decode decimal numeric entities &#NNN;
        result = decodeNumericEntities(result)
        return result
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        var out = s
        // Simple scan for &#digits; patterns
        var searchStart = out.startIndex
        while searchStart < out.endIndex,
              let ampRange = out.range(of: "&#", range: searchStart..<out.endIndex) {
            let afterAmp = ampRange.upperBound
            guard afterAmp < out.endIndex else { break }
            // Collect digits
            var idx = afterAmp
            while idx < out.endIndex && out[idx].isNumber {
                idx = out.index(after: idx)
            }
            guard idx < out.endIndex && out[idx] == ";" && idx > afterAmp else {
                searchStart = ampRange.upperBound
                continue
            }
            let digits = String(out[afterAmp..<idx])
            let entityEnd = out.index(after: idx)
            if let codepoint = UInt32(digits), let scalar = Unicode.Scalar(codepoint) {
                out.replaceSubrange(ampRange.lowerBound..<entityEnd, with: String(scalar))
                // After replacement the indices shift; restart from same position
                searchStart = ampRange.lowerBound
            } else {
                searchStart = entityEnd
            }
        }
        return out
    }
}
