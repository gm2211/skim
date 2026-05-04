import Foundation

public protocol FeedStore: Sendable {
    func listFeeds() async throws -> [Feed]
    func importFeeds(_ feeds: [ImportedFeed]) async throws
    func upsert(feed: Feed, articles: [Article]) async throws
}

public protocol ArticleStore: Sendable {
    func listArticles(filter: ArticleFilter) async throws -> [Article]
    func countUnread(feedID: String?) async throws -> Int
    func article(id: String) async throws -> Article
    func setArticleRead(id: String, isRead: Bool) async throws
    func toggleStar(id: String) async throws
}

public protocol SettingsStore: Sendable {
    func loadSettings() async throws -> AppSettings
    func saveSettings(_ settings: AppSettings) async throws
}

public struct FeedRefreshService: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func refreshAll(store: some FeedStore) async throws {
        let feeds = try await store.listFeeds()
        for feed in feeds {
            try await refresh(feed: feed, store: store)
        }
    }

    public func refresh(feed: Feed, store: some FeedStore) async throws {
        let fetchURL = feed.url.upgradingHTTPToHTTPS()
        let (data, _) = try await session.data(from: fetchURL)
        let parsed = try FeedParser().parse(data: data, fallbackTitle: feed.title)
        let updatedFeed = Feed(
            id: feed.id,
            title: parsed.title.isEmpty ? feed.title : parsed.title,
            url: fetchURL,
            siteURL: parsed.siteURL ?? feed.siteURL,
            iconURL: feed.iconURL,
            fetchedAt: Date()
        )
        let articles = parsed.articles.map { parsedArticle in
            Article(
                id: parsedArticle.id(feedID: feed.id),
                feedID: feed.id,
                feedTitle: updatedFeed.title,
                title: parsedArticle.title.isEmpty ? "Untitled" : parsedArticle.title,
                url: parsedArticle.url,
                author: parsedArticle.author,
                contentText: parsedArticle.contentText,
                contentHTML: parsedArticle.contentHTML,
                imageURL: parsedArticle.imageURL,
                publishedAt: parsedArticle.publishedAt,
                fetchedAt: Date()
            )
        }
        try await store.upsert(feed: updatedFeed, articles: articles)
    }
}

struct ParsedFeed {
    var title: String
    var siteURL: URL?
    var articles: [ParsedArticle]
}

struct ParsedArticle {
    var guid: String?
    var title: String
    var url: URL?
    var author: String?
    var contentText: String?
    var contentHTML: String?
    var imageURL: URL?
    var publishedAt: Date?

    func id(feedID: String) -> String {
        stableID(prefix: "article", value: url?.absoluteString ?? guid ?? "\(feedID)-\(title)-\(publishedAt?.timeIntervalSince1970 ?? 0)")
    }
}

struct FeedParser {
    func parse(data: Data, fallbackTitle: String) throws -> ParsedFeed {
        let parser = XMLParser(data: data)
        let delegate = FeedParserDelegate(fallbackTitle: fallbackTitle)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SkimCoreError.feedParseFailed
        }
        return ParsedFeed(title: delegate.feedTitle, siteURL: delegate.siteURL, articles: delegate.articles)
    }
}

private final class FeedParserDelegate: NSObject, XMLParserDelegate {
    private enum Context {
        case none
        case channel
        case item
        case entry
    }

    let fallbackTitle: String
    var feedTitle: String
    var siteURL: URL?
    var articles: [ParsedArticle] = []

    private var context: Context = .none
    private var currentElement = ""
    private var text = ""
    private var item = ParsedArticle(guid: nil, title: "", url: nil, author: nil, contentText: nil, contentHTML: nil, imageURL: nil, publishedAt: nil)

    init(fallbackTitle: String) {
        self.fallbackTitle = fallbackTitle
        self.feedTitle = fallbackTitle
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = normalized(elementName)
        currentElement = name
        text = ""

        if name == "channel" || name == "feed" {
            context = .channel
        } else if name == "item" {
            context = .item
            item = ParsedArticle(guid: nil, title: "", url: nil, author: nil, contentText: nil, contentHTML: nil, imageURL: nil, publishedAt: nil)
        } else if name == "entry" {
            context = .entry
            item = ParsedArticle(guid: nil, title: "", url: nil, author: nil, contentText: nil, contentHTML: nil, imageURL: nil, publishedAt: nil)
        }

        if context == .entry, name == "link", item.url == nil {
            let href = attributeDict["href"]
            let rel = attributeDict["rel"] ?? "alternate"
            if rel == "alternate", let href {
                item.url = URL(string: href)
            }
        }

        if context == .channel, name == "link", siteURL == nil, let href = attributeDict["href"] {
            siteURL = URL(string: href)
        }

        if context == .item || context == .entry {
            if name == "enclosure", item.imageURL == nil, let url = attributeDict["url"], (attributeDict["type"] ?? "").hasPrefix("image") {
                item.imageURL = URL(string: url)
            }
            if name == "media:thumbnail", item.imageURL == nil, let url = attributeDict["url"] {
                item.imageURL = URL(string: url)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = normalized(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch context {
        case .channel:
            if name == "title", !value.isEmpty {
                feedTitle = value
            } else if name == "link", siteURL == nil {
                siteURL = URL(string: value)
            }
        case .item, .entry:
            assignItemValue(name: name, value: value)
            if name == "item" || name == "entry" {
                articles.append(item)
                context = .channel
            }
        case .none:
            break
        }

        text = ""
    }

    private func assignItemValue(name: String, value: String) {
        guard !value.isEmpty else { return }
        switch name {
        case "guid", "id":
            item.guid = value
        case "title":
            item.title = value
        case "link":
            if item.url == nil { item.url = URL(string: value) }
        case "author", "dc:creator", "name":
            if item.author == nil { item.author = value }
        case "description", "summary":
            if item.contentText == nil { item.contentText = value.strippingTags() }
            if item.contentHTML == nil { item.contentHTML = value }
        case "content:encoded", "content":
            item.contentHTML = value
            item.contentText = value.strippingTags()
        case "pubdate", "published", "updated":
            item.publishedAt = Date.feedDate(from: value)
        default:
            break
        }
    }

    private func normalized(_ name: String) -> String {
        name.lowercased()
    }
}

extension Date {
    static func feedDate(from value: String) -> Date? {
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        rfc822.dateFormat = "E, d MMM yyyy HH:mm:ss Z"
        if let date = rfc822.date(from: value) { return date }

        let iso = ISO8601DateFormatter()
        return iso.date(from: value)
    }
}

extension String {
    func strippingTags() -> String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
