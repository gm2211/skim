import Foundation

/// A feed found by discovery, search, or the built-in catalog.
public struct DiscoveredFeed: Identifiable, Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public var title: String
        public var url: URL?
        public var publishedAt: Date?
    }

    public var url: URL
    public var title: String
    public var siteURL: URL?
    public var summary: String?
    public var iconURL: URL?
    /// Feedly follower count, when the result came from search.
    public var subscribers: Int?
    /// Latest headlines. Empty until the feed has been fetched.
    public var items: [Item]

    public var id: String { url.absoluteString }

    public init(url: URL, title: String, siteURL: URL? = nil, summary: String? = nil, iconURL: URL? = nil, subscribers: Int? = nil, items: [Item] = []) {
        self.url = url
        self.title = title
        self.siteURL = siteURL
        self.summary = summary
        self.iconURL = iconURL ?? FeedDiscoveryService.faviconURL(for: siteURL ?? url)
        self.subscribers = subscribers
        self.items = items
    }
}

/// The built-in catalog of popular feeds by topic (shared/feed-catalog.json).
public struct FeedCatalog: Sendable {
    public struct Topic: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var feeds: [DiscoveredFeed]
    }

    public var topics: [Topic]

    public init(topics: [Topic]) {
        self.topics = topics
    }

    public init(data: Data) throws {
        struct RawFeed: Decodable { var title: String; var url: String; var site: String; var description: String }
        struct RawTopic: Decodable { var id: String; var name: String; var feeds: [RawFeed] }
        struct Raw: Decodable { var topics: [RawTopic] }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        topics = raw.topics.map { topic in
            Topic(id: topic.id, name: topic.name, feeds: topic.feeds.compactMap { feed in
                guard let url = URL(string: feed.url) else { return nil }
                return DiscoveredFeed(url: url, title: feed.title, siteURL: URL(string: feed.site), summary: feed.description)
            })
        }
    }

    /// Feeds whose title, description, topic or site contains every search word.
    public func search(_ query: String) -> [DiscoveredFeed] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var out: [DiscoveredFeed] = []
        for topic in topics {
            for feed in topic.feeds {
                let hay = [feed.title, feed.summary ?? "", topic.name, feed.siteURL?.absoluteString ?? ""].joined(separator: " ").lowercased()
                if words.allSatisfy({ hay.contains($0) }), !out.contains(where: { $0.url == feed.url }) {
                    out.append(feed)
                }
            }
        }
        return out
    }
}

public enum FeedDiscoveryError: Error, LocalizedError, Sendable {
    case notAnAddress(String)
    case noFeedsFound
    case notAFeed

    public var errorDescription: String? {
        switch self {
        case .notAnAddress(let input): "\u{201C}\(input)\u{201D} is not a web address."
        case .noFeedsFound: "No feeds found on that page."
        case .notAFeed: "That address is not a feed."
        }
    }
}

/// Turns a website address, a feed address, or a few words into feeds.
/// Mirrors src-tauri/src/feed/discovery.rs so desktop and iOS find the same feeds.
public struct FeedDiscoveryService: Sendable {
    private let session: URLSession
    private static let previewItems = 5
    private static let maxCandidates = 12

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Input

    /// True when the input reads as an address rather than search words.
    public static func looksLikeURL(_ input: String) -> Bool {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.contains(where: \.isWhitespace) { return false }
        if s.contains("://") || subredditName(s) != nil { return true }
        let host = s.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? ""
        let bareHost = host.split(separator: "@").last.map(String.init) ?? host
        guard let dot = bareHost.lastIndex(of: "."), dot > bareHost.startIndex else { return false }
        let tld = bareHost[bareHost.index(after: dot)...]
        return tld.count >= 2 && tld.allSatisfy { $0.isASCII && $0.isLetter }
    }

    /// Adds `https://` to bare addresses and expands `r/name` to Reddit.
    public static func normalizedInputURL(_ input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sub = subredditName(s) {
            return URL(string: "https://www.reddit.com/r/\(sub)/")
        }
        let withScheme = s.contains("://") ? s : "https://\(s)"
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }

    private static func subredditName(_ s: String) -> String? {
        var rest = Substring(s)
        if rest.hasPrefix("/") { rest = rest.dropFirst() }
        guard rest.hasPrefix("r/") else { return nil }
        rest = rest.dropFirst(2)
        if rest.hasSuffix("/") { rest = rest.dropLast() }
        guard !rest.isEmpty, rest.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return String(rest)
    }

    // MARK: Candidates

    /// Feed URLs for sites whose feeds follow a known pattern.
    public static func siteSpecificFeeds(for pageURL: URL) -> [URL] {
        guard let rawHost = pageURL.host()?.lowercased() else { return [] }
        var bare = rawHost
        for prefix in ["www.", "old.", "m."] where bare.hasPrefix(prefix) {
            bare = String(bare.dropFirst(prefix.count))
        }
        let segs = pageURL.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        var out: [String] = []
        switch bare {
        case "reddit.com":
            if segs.count >= 2, segs[0] == "r" {
                out.append("https://www.reddit.com/r/\(segs[1])/.rss")
            } else if segs.count >= 2, segs[0] == "user" || segs[0] == "u" {
                out.append("https://www.reddit.com/user/\(segs[1])/.rss")
            } else if segs.isEmpty {
                out.append("https://www.reddit.com/.rss")
            }
        case "youtube.com":
            let query = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let list = query.first(where: { $0.name == "list" })?.value {
                out.append("https://www.youtube.com/feeds/videos.xml?playlist_id=\(list)")
            }
            if segs.count >= 2, segs[0] == "channel" {
                out.append("https://www.youtube.com/feeds/videos.xml?channel_id=\(segs[1])")
            } else if segs.count >= 2, segs[0] == "user" {
                out.append("https://www.youtube.com/feeds/videos.xml?user=\(segs[1])")
            }
        case "news.ycombinator.com":
            out += ["https://news.ycombinator.com/rss", "https://hnrss.org/best", "https://hnrss.org/newest?points=100"]
        case "github.com":
            if segs.count >= 2 {
                out += ["https://github.com/\(segs[0])/\(segs[1])/releases.atom", "https://github.com/\(segs[0])/\(segs[1])/commits.atom"]
            } else if segs.count == 1 {
                out.append("https://github.com/\(segs[0]).atom")
            }
        case "medium.com":
            if let first = segs.first { out.append("https://medium.com/feed/\(first)") }
        case "bsky.app":
            if segs.count >= 2, segs[0] == "profile" { out.append("https://bsky.app/profile/\(segs[1])/rss") }
        case "lobste.rs":
            out.append("https://lobste.rs/rss")
        default:
            if bare.hasSuffix(".medium.com") {
                out.append("https://\(rawHost)/feed")
            } else if segs.count == 1, segs[0].hasPrefix("@"), segs[0].count > 1 {
                // Mastodon and other fediverse profiles: /@user -> /@user.rss
                out.append("https://\(rawHost)/\(segs[0]).rss")
            }
        }
        return out.compactMap(URL.init(string:))
    }

    /// `<link rel="alternate" type="application/rss+xml" href="...">` feeds in a page.
    public static func feedLinks(inHTML html: String, baseURL: URL) -> [URL] {
        var out: [URL] = []
        for tag in matches(of: #"<link\b[^>]*>"#, in: html, options: [.caseInsensitive]) {
            let attrs = attributes(in: tag)
            let rel = (attrs["rel"] ?? "").lowercased().split(separator: " ")
            let type = (attrs["type"] ?? "").lowercased()
            let isFeed = type.contains("rss") || type.contains("atom") || type.contains("feed+json")
            guard rel.contains("alternate"), isFeed, let href = attrs["href"], !href.isEmpty else { continue }
            let decoded = href.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#38;", with: "&")
            if let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL, !out.contains(url) {
                out.append(url)
            }
        }
        // YouTube handle pages carry the channel id in page data even when the
        // alternate link is missing from the served HTML.
        if out.isEmpty, baseURL.host()?.contains("youtube.com") == true,
           let id = firstCapture(of: #""(?:channelId|externalId)":"(UC[\w-]{22})""#, in: html),
           let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)") {
            out.append(url)
        }
        return out
    }

    public static func commonFeedPaths(for pageURL: URL) -> [URL] {
        guard let scheme = pageURL.scheme, let host = pageURL.host() else { return [] }
        let origin = "\(scheme)://\(host)" + (pageURL.port.map { ":\($0)" } ?? "")
        var out = ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml", "/feeds/posts/default"].map { origin + $0 }
        var path = pageURL.path()
        while path.hasSuffix("/") { path.removeLast() }
        if !path.isEmpty { out.insert(origin + path + "/feed", at: 0) }
        return out.compactMap(URL.init(string:))
    }

    // MARK: Network

    /// Finds the feeds behind a website or feed address, with preview headlines.
    public func discover(_ input: String) async throws -> [DiscoveredFeed] {
        guard let pageURL = Self.normalizedInputURL(input) else {
            throw FeedDiscoveryError.notAnAddress(input.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let special = Self.siteSpecificFeeds(for: pageURL)
        var candidates: [URL] = []
        var finalURL = pageURL
        var pageError: Error?
        do {
            let (data, response) = try await fetch(pageURL)
            finalURL = response.url ?? pageURL
            if let feed = Self.discovered(from: data, feedURL: pageURL) {
                return [feed]
            }
            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            candidates += Self.feedLinks(inHTML: html, baseURL: finalURL)
            candidates += Self.siteSpecificFeeds(for: finalURL)
        } catch {
            pageError = error
        }
        candidates += special
        var found = await probe(candidates.uniquePreservingOrder())
        if found.isEmpty {
            found = await probe(Self.commonFeedPaths(for: finalURL))
            // Several common paths often redirect to the same feed.
            var seen = Set<String>()
            found = found.filter { seen.insert("\($0.title)|\($0.items.first?.title ?? "")").inserted }
        }
        if found.isEmpty {
            throw pageError ?? FeedDiscoveryError.noFeedsFound
        }
        return found
    }

    /// Fetches one feed for its preview headlines.
    public func preview(_ feedURL: URL) async throws -> DiscoveredFeed {
        let (data, _) = try await fetch(feedURL)
        guard let feed = Self.discovered(from: data, feedURL: feedURL) else { throw FeedDiscoveryError.notAFeed }
        return feed
    }

    /// Searches feeds by topic or name: catalog matches first, then Feedly's public index.
    public func search(_ query: String, catalog: FeedCatalog?) async -> [DiscoveredFeed] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var results = catalog?.search(q) ?? []
        var components = URLComponents(string: "https://cloud.feedly.com/v3/search/feeds")!
        components.queryItems = [
            URLQueryItem(name: "query", value: q),
            URLQueryItem(name: "count", value: "30"),
            URLQueryItem(name: "locale", value: "en")
        ]
        if let url = components.url, let (data, response) = try? await fetch(url),
           (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
            for feed in Self.parseFeedlySearch(data) where !results.contains(where: { Self.sameFeed($0.url, feed.url) }) {
                results.append(feed)
            }
        }
        return results
    }

    public static func parseFeedlySearch(_ data: Data) -> [DiscoveredFeed] {
        struct Result: Decodable {
            var feedId: String?
            var title: String?
            var website: String?
            var description: String?
            var subscribers: Int?
            var iconUrl: String?
            var visualUrl: String?
        }
        struct Response: Decodable { var results: [Result]? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return (response.results ?? []).compactMap { r in
            guard let id = r.feedId, id.hasPrefix("feed/"), let url = URL(string: String(id.dropFirst(5))) else { return nil }
            let title = r.title.map(cleanText).flatMap { $0.isEmpty ? nil : $0 } ?? url.absoluteString
            return DiscoveredFeed(
                url: url,
                title: title,
                siteURL: r.website.flatMap(URL.init(string:)),
                summary: r.description.map(cleanText).flatMap { $0.isEmpty ? nil : $0 },
                iconURL: (r.iconUrl ?? r.visualUrl).flatMap(URL.init(string:)),
                subscribers: r.subscribers
            )
        }
    }

    public static func faviconURL(for url: URL) -> URL? {
        guard let host = url.host() else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }

    /// Same feed address, ignoring scheme, `www.` and a trailing slash.
    public static func sameFeed(_ a: URL, _ b: URL) -> Bool {
        key(a) == key(b)
    }

    public static func key(_ url: URL) -> String {
        var s = url.absoluteString.lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func discovered(from data: Data, feedURL: URL) -> DiscoveredFeed? {
        guard let parsed = try? FeedParser().parse(data: data, fallbackTitle: feedURL.host() ?? feedURL.absoluteString) else { return nil }
        return DiscoveredFeed(
            url: feedURL,
            title: cleanText(parsed.title),
            siteURL: parsed.siteURL.flatMap { $0 == feedURL ? nil : $0 },
            items: parsed.articles.prefix(previewItems).map {
                DiscoveredFeed.Item(title: cleanText($0.title), url: $0.url, publishedAt: $0.publishedAt)
            }
        )
    }

    private func probe(_ candidates: [URL]) async -> [DiscoveredFeed] {
        let list = Array(candidates.prefix(Self.maxCandidates))
        return await withTaskGroup(of: (Int, DiscoveredFeed?).self) { group in
            for (index, url) in list.enumerated() {
                group.addTask {
                    guard let (data, _) = try? await fetch(url) else { return (index, nil) }
                    return (index, Self.discovered(from: data, feedURL: url))
                }
            }
            var results: [(Int, DiscoveredFeed)] = []
            for await (index, feed) in group {
                if let feed { results.append((index, feed)) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url.upgradingHTTPToHTTPS(), timeoutInterval: 12)
        request.setValue("Skim/0.1 RSS Reader", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    // MARK: Text helpers

    static func cleanText(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        return noTags.decodingHTMLEntities()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func matches(of pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func attributes(in tag: String) -> [String: String] {
        let pattern = #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(['"])(.*?)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        return regex.matches(in: tag, range: range).reduce(into: [:]) { result, match in
            guard match.numberOfRanges == 4,
                  let keyRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: 3), in: tag) else { return }
            result[String(tag[keyRange]).lowercased()] = String(tag[valueRange])
        }
    }
}
