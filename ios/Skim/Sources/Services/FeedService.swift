import Foundation
import FeedKit
import SwiftData

actor FeedService {
    static let shared = FeedService()

    func fetchAndParseFeed(url: URL) async throws -> (title: String, siteUrl: String?, articles: [(title: String, url: String?, author: String?, contentHtml: String?, contentText: String?, publishedAt: Date?)]) {
        let (data, _) = try await URLSession.shared.data(from: url)
        let parser = FeedParser(data: data)
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FeedKit.Feed, Error>) in
            parser.parseAsync { parseResult in
                switch parseResult {
                case .success(let feed):
                    continuation.resume(returning: feed)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        var feedTitle = "Untitled Feed"
        var siteUrl: String? = nil
        var articles: [(String, String?, String?, String?, String?, Date?)] = []

        switch result {
        case .rss(let rssFeed):
            feedTitle = rssFeed.title ?? feedTitle
            siteUrl = rssFeed.link
            articles = (rssFeed.items ?? []).map { item in
                let html = item.content?.contentEncoded ?? item.description
                let text = html.flatMap { stripHtml($0) }
                return (item.title ?? "Untitled", item.link, item.author, html, text, item.pubDate)
            }
        case .atom(let atomFeed):
            feedTitle = atomFeed.title ?? feedTitle
            siteUrl = atomFeed.links?.first?.attributes?.href
            articles = (atomFeed.entries ?? []).map { entry in
                let html = entry.content?.value ?? entry.summary?.value
                let text = html.flatMap { stripHtml($0) }
                return (entry.title ?? "Untitled", entry.links?.first?.attributes?.href, entry.authors?.first?.name, html, text, entry.published ?? entry.updated)
            }
        case .json(let jsonFeed):
            feedTitle = jsonFeed.title ?? feedTitle
            siteUrl = jsonFeed.homePageURL
            articles = (jsonFeed.items ?? []).map { item in
                let html = item.contentHtml
                let text = item.contentText ?? html.flatMap { stripHtml($0) }
                return (item.title ?? "Untitled", item.url, item.author?.name, html, text, item.datePublished)
            }
        }

        return (feedTitle, siteUrl, articles)
    }

    private func stripHtml(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        if let attributed = try? NSAttributedString(data: data, options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ], documentAttributes: nil) {
            return attributed.string
        }
        return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
