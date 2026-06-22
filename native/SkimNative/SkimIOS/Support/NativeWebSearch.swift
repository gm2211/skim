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

        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""

        var results = parseDDGResults(html)
        results = Array(results.prefix(clampedMax))
        return results
    }

    // MARK: - Private parsing helpers

    private static func parseDDGResults(_ html: String) -> [SearchResult] {
        var results: [SearchResult] = []

        for chunk in html.components(separatedBy: "class=\"result__body") {
            if results.count >= 10 { break }

            // --- title + URL ---
            guard let aRange = chunk.range(of: "class=\"result__a\"") else { continue }
            let afterA = String(chunk[aRange.lowerBound...])
            guard let href = extractAttr(afterA, attr: "href"),
                  let title = extractTagText(afterA, tag: "a") else { continue }

            // Unwrap DDG redirect: …?uddg=<percent-encoded-url>&…
            let actualURL: String
            if href.contains("uddg=") {
                if let uddgRange = href.range(of: "uddg=") {
                    let afterUddg = String(href[uddgRange.upperBound...])
                    let raw = afterUddg.components(separatedBy: "&").first ?? afterUddg
                    actualURL = raw.removingPercentEncoding ?? raw
                } else {
                    actualURL = href
                }
            } else {
                actualURL = href
            }

            guard actualURL.hasPrefix("http") else { continue }

            // --- snippet ---
            let snippet: String
            if let sRange = chunk.range(of: "class=\"result__snippet\"") {
                let afterS = String(chunk[sRange.lowerBound...])
                snippet = extractTagText(afterS, tag: "a") ?? extractInnerText(afterS) ?? ""
            } else {
                snippet = ""
            }

            guard !title.isEmpty else { continue }

            results.append(SearchResult(
                title: htmlEntitiesDecode(title),
                url: actualURL,
                snippet: htmlEntitiesDecode(snippet)
            ))
        }

        return results
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
