import Foundation

public struct Feed: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var url: URL
    public var siteURL: URL?
    public var iconURL: URL?
    public var fetchedAt: Date?

    public init(id: String, title: String, url: URL, siteURL: URL? = nil, iconURL: URL? = nil, fetchedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.siteURL = siteURL
        self.iconURL = iconURL
        self.fetchedAt = fetchedAt
    }
}

public struct Article: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var feedID: String
    public var feedTitle: String
    public var title: String
    public var url: URL?
    public var author: String?
    public var contentText: String?
    public var contentHTML: String?
    public var imageURL: URL?
    public var publishedAt: Date?
    public var fetchedAt: Date
    public var isRead: Bool
    public var isStarred: Bool

    public init(
        id: String,
        feedID: String,
        feedTitle: String,
        title: String,
        url: URL? = nil,
        author: String? = nil,
        contentText: String? = nil,
        contentHTML: String? = nil,
        imageURL: URL? = nil,
        publishedAt: Date? = nil,
        fetchedAt: Date = Date(),
        isRead: Bool = false,
        isStarred: Bool = false
    ) {
        self.id = id
        self.feedID = feedID
        self.feedTitle = feedTitle
        self.title = title
        self.url = url
        self.author = author
        self.contentText = contentText
        self.contentHTML = contentHTML
        self.imageURL = imageURL
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
        self.isRead = isRead
        self.isStarred = isStarred
    }
}

public struct ArticleFilter: Sendable, Equatable {
    public enum ReadState: Sendable, Equatable {
        case all
        case unread
        case read
    }

    public var feedID: String?
    public var readState: ReadState
    public var starredOnly: Bool
    public var searchQuery: String?
    public var limit: Int

    public init(
        feedID: String? = nil,
        readState: ReadState = .all,
        starredOnly: Bool = false,
        searchQuery: String? = nil,
        limit: Int = 300
    ) {
        self.feedID = feedID
        self.readState = readState
        self.starredOnly = starredOnly
        self.searchQuery = searchQuery
        self.limit = limit
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var prefersUnreadOnly: Bool

    public init(prefersUnreadOnly: Bool = true) {
        self.prefersUnreadOnly = prefersUnreadOnly
    }
}

public struct ImportedFeed: Hashable, Sendable {
    public var title: String
    public var xmlURL: URL
    public var htmlURL: URL?

    public init(title: String, xmlURL: URL, htmlURL: URL? = nil) {
        self.title = title
        self.xmlURL = xmlURL
        self.htmlURL = htmlURL
    }
}

public struct ArticleContent: Sendable, Equatable {
    public var title: String
    public var body: String
    public var html: String?

    public init(title: String, body: String, html: String? = nil) {
        self.title = title
        self.body = body
        self.html = html
    }
}

public enum SkimCoreError: Error, LocalizedError, Sendable {
    case invalidOPML
    case invalidFeedURL
    case feedParseFailed
    case articleNotFound
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOPML: "Could not read OPML feeds."
        case .invalidFeedURL: "Feed URL is invalid."
        case .feedParseFailed: "Could not parse the feed."
        case .articleNotFound: "Article not found."
        case .database(let message): "Database error: \(message)"
        }
    }
}

public func stableID(prefix: String, value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return "\(prefix)-\(String(hash, radix: 16))"
}

public extension URL {
    func upgradingHTTPToHTTPS() -> URL {
        guard scheme?.lowercased() == "http", var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.scheme = "https"
        return components.url ?? self
    }
}
