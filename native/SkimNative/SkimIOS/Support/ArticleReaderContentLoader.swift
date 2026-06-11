import Foundation
import PDFKit
import SkimCore

struct ArticleReaderContent: Sendable {
    var url: URL?
    var text: String
}

enum ArticleReaderContentError: LocalizedError, Sendable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            message
        }
    }
}

enum ArticleReaderContentLoader {
    private static let minimumUsefulTextLength = 200
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func displayBody(for article: Article) -> String {
        let body = article.contentText?.articleReaderDecodingHTMLEntities.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? article.contentHTML?.articleReaderPlainText.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let cleaned = body
            .articleReaderUnescapingLiteralEscapes
            .articleReaderRemovingBoilerplate
        return ArticleExtractor.sanitizeReaderText(cleaned)
    }

    static func isSufficientRSSBody(_ article: Article) -> Bool {
        let body = displayBody(for: article)
        return body.count >= minimumUsefulTextLength && !body.articleReaderIsRSSBoilerplate
    }

    static func loadText(for article: Article) async throws -> ArticleReaderContent {
        if article.aggregatorKind == .reddit {
            let service = AggregatorService()
            if let selftext = await service.fetchRedditSelftext(for: article),
               let text = sanitizedText(selftext),
               !text.isEmpty {
                return ArticleReaderContent(url: article.commentsURL ?? article.url, text: text)
            }

            var externalURL = article.externalURL
            if externalURL == nil {
                externalURL = await service.fetchRedditExternalURL(for: article)
            }
            if let externalURL {
                return try await loadText(from: externalURL)
            }

            throw ArticleReaderContentError.unavailable("Could not find the linked article in this Reddit post.")
        }

        guard let url = article.externalURL ?? article.url else {
            throw ArticleReaderContentError.unavailable("No article URL available.")
        }
        return try await loadText(from: url)
    }

    static func loadText(from url: URL) async throws -> ArticleReaderContent {
        let effectiveURL = await readerURL(for: url) ?? url
        guard !isRedditURL(effectiveURL) else {
            throw ArticleReaderContentError.unavailable("Could not find the linked article in this Reddit post.")
        }

        return try await loadDocument(at: effectiveURL)
    }

    static func readerURL(for url: URL) async -> URL? {
        guard isRedditURL(url) else { return url }
        return await AggregatorService().fetchRedditExternalURL(from: url)
    }

    static func isRedditURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "reddit.com"
            || host == "www.reddit.com"
            || host == "old.reddit.com"
            || host == "new.reddit.com"
            || host.hasSuffix(".reddit.com")
            || host == "redd.it"
    }

    static func sanitizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = ArticleExtractor.sanitizeReaderText(
            text
                .articleReaderDecodingHTMLEntities
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return cleaned.articleReaderNilIfEmpty
    }

    private struct LoadedDocument: Sendable {
        var url: URL
        var text: String
    }

    private static func loadDocument(at url: URL) async throws -> ArticleReaderContent {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/pdf;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw ArticleReaderContentError.unavailable("The article could not be loaded.")
        }

        let responseURL = response.url ?? url
        let mimeType = response.mimeType?.lowercased() ?? ""
        let loaded = try await Task.detached(priority: .utility) {
            try extractDocument(data: data, responseURL: responseURL, mimeType: mimeType)
        }.value
        return ArticleReaderContent(url: loaded.url, text: loaded.text)
    }

    private static func extractDocument(data: Data, responseURL: URL, mimeType: String) throws -> LoadedDocument {
        if isPDF(url: responseURL, mimeType: mimeType, data: data) {
            guard let text = pdfText(from: data), text.count >= minimumUsefulTextLength else {
                throw ArticleReaderContentError.unavailable("The PDF did not contain extractable text.")
            }
            return LoadedDocument(url: responseURL, text: text)
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ArticleReaderContentError.unavailable("The article could not be decoded.")
        }

        let extracted = (try? ArticleExtractor.extract(from: html, baseURL: responseURL))
            ?? sanitizedText(html.articleReaderPlainText)
            ?? ""
        guard extracted.count >= minimumUsefulTextLength else {
            throw ArticleReaderContentError.unavailable("Page content could not be extracted.")
        }
        return LoadedDocument(url: responseURL, text: extracted)
    }

    private static func isPDF(url: URL, mimeType: String, data: Data) -> Bool {
        if mimeType.contains("pdf") || url.pathExtension.lowercased() == "pdf" {
            return true
        }
        return Data(data.prefix(5)) == Data("%PDF-".utf8)
    }

    private static func pdfText(from data: Data) -> String? {
        guard let document = PDFDocument(data: data) else { return nil }
        let pages = (0..<document.pageCount).compactMap { index in
            document.page(at: index)?.string?.articleReaderNilIfEmpty
        }
        return sanitizedText(pages.joined(separator: "\n\n"))
    }
}

private extension String {
    var articleReaderPlainText: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .articleReaderDecodingHTMLEntities
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var articleReaderDecodingHTMLEntities: String {
        var decoded = self
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")

        let pattern = #"&#(x?[0-9A-Fa-f]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return decoded }
        let matches = regex.matches(in: decoded, range: NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)).reversed()

        for match in matches {
            guard match.numberOfRanges == 2,
                  let fullRange = Range(match.range(at: 0), in: decoded),
                  let valueRange = Range(match.range(at: 1), in: decoded)
            else { continue }

            let value = decoded[valueRange]
            let radix = value.lowercased().hasPrefix("x") ? 16 : 10
            let scalarText = radix == 16 ? value.dropFirst() : Substring(value)
            guard let codepoint = UInt32(scalarText, radix: radix),
                  let scalar = UnicodeScalar(codepoint)
            else { continue }

            decoded.replaceSubrange(fullRange, with: String(scalar))
        }

        return decoded
    }

    var articleReaderUnescapingLiteralEscapes: String {
        replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    var articleReaderRemovingBoilerplate: String {
        let normalized = replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let redditPattern = #"^submitted by\s+/u/\S+\s+\[link\]\s+(&\s+)?\[comments\]$"#
        if normalized.range(of: redditPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return ""
        }

        return self
    }

    var articleReaderIsRSSBoilerplate: Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()

        let stubPatterns: [String] = [
            #"^the post .{0,80} appeared first on"#,
            #"click (here )?to (read|view|continue)"#,
            #"read (the )?(full|more|rest|complete)"#,
            #"continue reading"#,
            #"this is a summary"#,
            #"view full (article|post|story)"#,
            #"^<p>\s*</p>$"#,
        ]

        for pattern in stubPatterns {
            if normalized.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    var articleReaderNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
