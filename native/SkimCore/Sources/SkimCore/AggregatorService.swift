import Foundation

// MARK: - Comment model

/// One comment in a discussion. Threads come back flattened in reading order:
/// each comment is followed by its replies, which carry a larger `depth`.
public struct AggregatorComment: Identifiable, Sendable, Hashable {
    public var id: String
    public var author: String
    public var score: Int?
    public var body: String
    public var depth: Int

    public init(id: String, author: String, score: Int? = nil, body: String, depth: Int = 0) {
        self.id = id
        self.author = author
        self.score = score
        self.body = body
        self.depth = depth
    }
}

/// A comment with its replies, rebuilt from the flattened, depth-tagged list.
public struct AggregatorCommentThread: Identifiable, Sendable, Hashable {
    public var comment: AggregatorComment
    public var replies: [AggregatorCommentThread]

    public var id: String { comment.id }

    /// Every reply below this comment, at any depth.
    public var replyCount: Int {
        replies.reduce(0) { $0 + 1 + $1.replyCount }
    }

    public init(comment: AggregatorComment, replies: [AggregatorCommentThread] = []) {
        self.comment = comment
        self.replies = replies
    }

    public static func threads(from comments: [AggregatorComment]) -> [AggregatorCommentThread] {
        var index = 0
        return build(comments, from: &index, minimumDepth: Int.min)
    }

    private static func build(_ comments: [AggregatorComment], from index: inout Int, minimumDepth: Int) -> [AggregatorCommentThread] {
        var threads: [AggregatorCommentThread] = []
        while index < comments.count, comments[index].depth >= minimumDepth {
            let comment = comments[index]
            index += 1
            let replies = build(comments, from: &index, minimumDepth: comment.depth + 1)
            threads.append(AggregatorCommentThread(comment: comment, replies: replies))
        }
        return threads
    }
}

// MARK: - Service

/// Fetches discussion threads for aggregator articles (HN, Reddit, Lobsters).
/// All calls are best-effort; errors are silently swallowed and an empty array returned.
public struct AggregatorService: Sendable {
    /// Deepest reply level kept (0 = top-level comment).
    public static let maxCommentDepth = 4
    /// Upper bound on comments returned for one thread, replies included.
    static let maxThreadComments = 300
    private static let redditUserAgent = "ios:com.skimapp.skim:v1.0 (by /u/skim_reader)"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch up to `limit` top-level comments for the given article, each with its replies.
    public func fetchComments(
        for article: SkimCore.Article,
        limit: Int = 10
    ) async -> [AggregatorComment] {
        guard let kind = article.aggregatorKind else { return [] }
        switch kind {
        case .hackerNews:
            return await fetchHNComments(article: article, limit: limit)
        case .reddit:
            return await fetchRedditComments(article: article, limit: limit)
        case .lobsters:
            return await fetchLobstersComments(article: article, limit: limit)
        }
    }

    // MARK: - HN via Algolia

    private func fetchHNComments(article: SkimCore.Article, limit: Int) async -> [AggregatorComment] {
        // Derive HN story ID from the article URL or commentsURL.
        // HN item URLs look like: https://news.ycombinator.com/item?id=12345678
        guard let storyID = hnStoryID(from: article) else { return [] }

        let apiURL = URL(string: "https://hn.algolia.com/api/v1/items/\(storyID)")!
        do {
            var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("Skim/1.0 (RSS reader)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let children = json["children"] as? [[String: Any]]
            else { return [] }
            var comments: [AggregatorComment] = []
            for child in children.prefix(limit) {
                Self.appendHNThread(child, depth: 0, to: &comments)
            }
            return comments
        } catch {
            return []
        }
    }

    static func appendHNThread(_ dict: [String: Any], depth: Int, to comments: inout [AggregatorComment]) {
        guard comments.count < maxThreadComments,
              // A deleted comment drops its subtree; its replies would read as answers to the wrong parent.
              let comment = hnComment(from: dict, depth: depth)
        else { return }
        comments.append(comment)
        guard depth < maxCommentDepth else { return }
        for child in dict["children"] as? [[String: Any]] ?? [] {
            appendHNThread(child, depth: depth + 1, to: &comments)
        }
    }

    private static func hnComment(from dict: [String: Any], depth: Int) -> AggregatorComment? {
        guard let id = (dict["id"] as? Int).map(String.init) ?? (dict["id"] as? String),
              let author = dict["author"] as? String,
              let text = dict["text"] as? String,
              !text.isEmpty
        else { return nil }
        let body = commentText(fromHTML: text)
        guard !body.isEmpty else { return nil }
        return AggregatorComment(
            id: id,
            author: author,
            score: dict["points"] as? Int,
            body: body,
            depth: depth
        )
    }

    private func hnStoryID(from article: SkimCore.Article) -> String? {
        // Try commentsURL first (https://news.ycombinator.com/item?id=XXXXX)
        for candidate in [article.commentsURL, article.url].compactMap({ $0 }) {
            if let host = candidate.host?.lowercased(),
               (host == "news.ycombinator.com" || host.hasSuffix(".ycombinator.com")),
               let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
               let id = components.queryItems?.first(where: { $0.name == "id" })?.value {
                return id
            }
        }
        return nil
    }

    // MARK: - Reddit selftext

    /// Fetches the selftext body of a Reddit self-post. Returns `nil` for link posts
    /// (where selftext is empty) or when the request fails.
    public func fetchRedditSelftext(for article: SkimCore.Article) async -> String? {
        guard let commentsURL = article.commentsURL ?? article.url,
              let postData = await fetchRedditPostData(from: commentsURL)
        else { return nil }

        guard let selftext = postData["selftext"] as? String,
              !selftext.isEmpty,
              selftext != "[deleted]",
              selftext != "[removed]"
        else { return nil }
        return selftext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetches the external link for a Reddit link post. Returns `nil` for self-posts,
    /// Reddit-internal links, and failed requests.
    public func fetchRedditExternalURL(for article: SkimCore.Article) async -> URL? {
        guard let commentsURL = article.commentsURL ?? article.url else { return nil }
        return await fetchRedditExternalURL(from: commentsURL)
    }

    /// Fetches the external link for a Reddit comments/permalink URL.
    public func fetchRedditExternalURL(from commentsURL: URL) async -> URL? {
        guard let postData = await fetchRedditPostData(from: commentsURL) else { return nil }
        return Self.redditExternalURL(from: postData)
    }

    static func redditExternalURL(from postData: [String: Any]) -> URL? {
        let isSelf = postData["is_self"] as? Bool ?? false
        guard !isSelf else { return nil }

        let candidate = (postData["url_overridden_by_dest"] as? String)
            ?? (postData["url"] as? String)
        guard let candidate,
              let url = URL(string: candidate.decodingHTMLEntities),
              let host = url.host?.lowercased(),
              !Self.isRedditHost(host)
        else { return nil }
        return url
    }

    private func fetchRedditPostData(from commentsURL: URL) async -> [String: Any]? {
        guard let root = await fetchRedditJSON(from: commentsURL, queryItems: [URLQueryItem(name: "limit", value: "1")]),
              let postListing = root.first,
              let listingData = postListing["data"] as? [String: Any],
              let children = listingData["children"] as? [[String: Any]],
              let postData = children.first?["data"] as? [String: Any]
        else { return nil }
        return postData
    }

    /// Reddit refuses or rate-limits anonymous JSON unpredictably, so try www
    /// first and old.reddit as a second door, and only accept a real listing.
    private func fetchRedditJSON(from commentsURL: URL, queryItems: [URLQueryItem]) async -> [[String: Any]]? {
        for host in ["www.reddit.com", "old.reddit.com"] {
            guard let jsonURL = redditThreadURL(from: commentsURL, host: host, extension: ".json", queryItems: queryItems) else { continue }
            var request = URLRequest(url: jsonURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue(Self.redditUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let result = try? await session.data(for: request),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: result.0)) as? [[String: Any]]
            else { continue }
            return root
        }
        return nil
    }

    // MARK: - Reddit

    private func fetchRedditComments(article: SkimCore.Article, limit: Int) async -> [AggregatorComment] {
        guard let commentsURL = article.commentsURL ?? article.url else { return [] }
        let queryItems = [
            URLQueryItem(name: "sort", value: "top"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "depth", value: "\(Self.maxCommentDepth + 1)"),
            // Keeps &, < and > literal in comment bodies.
            URLQueryItem(name: "raw_json", value: "1")
        ]
        if let root = await fetchRedditJSON(from: commentsURL, queryItems: queryItems) {
            let comments = Self.redditComments(fromThread: root, limit: limit)
            if !comments.isEmpty { return comments }
        }
        // Reddit blocks anonymous JSON on some networks while its RSS keeps
        // working (Skim already reads subreddits that way): the thread's
        // comment feed has no scores or nesting, but it has the conversation.
        return await fetchRedditFeedComments(from: commentsURL, limit: limit)
    }

    static func redditComments(fromThread root: [[String: Any]], limit: Int) -> [AggregatorComment] {
        guard root.count >= 2 else { return [] }
        var comments: [AggregatorComment] = []
        for child in redditListingChildren(root[1]).filter({ ($0["kind"] as? String) != "more" }).prefix(limit) {
            appendRedditThread(child, depth: 0, to: &comments)
        }
        return comments
    }

    private static func redditListingChildren(_ listing: Any?) -> [[String: Any]] {
        // A comment with no replies has `replies: ""` instead of a listing.
        ((listing as? [String: Any])?["data"] as? [String: Any])?["children"] as? [[String: Any]] ?? []
    }

    private static func appendRedditThread(_ child: [String: Any], depth: Int, to comments: inout [AggregatorComment]) {
        guard comments.count < maxThreadComments,
              (child["kind"] as? String) != "more",
              let comment = redditComment(from: child, depth: depth)
        else { return }
        comments.append(comment)
        guard depth < maxCommentDepth else { return }
        let replies = (child["data"] as? [String: Any])?["replies"]
        for reply in redditListingChildren(replies) {
            appendRedditThread(reply, depth: depth + 1, to: &comments)
        }
    }

    private static func redditComment(from child: [String: Any], depth: Int) -> AggregatorComment? {
        guard let data = child["data"] as? [String: Any],
              let author = data["author"] as? String,
              author != "[deleted]",
              let body = data["body"] as? String,
              body != "[deleted]", body != "[removed]",
              !body.isEmpty
        else { return nil }
        let id = (data["id"] as? String) ?? UUID().uuidString
        let score = data["score"] as? Int
        return AggregatorComment(
            id: id,
            author: author,
            score: score,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            depth: depth
        )
    }

    private func fetchRedditFeedComments(from commentsURL: URL, limit: Int) async -> [AggregatorComment] {
        guard let feedURL = redditThreadURL(
            from: commentsURL,
            host: "www.reddit.com",
            extension: ".rss",
            queryItems: [URLQueryItem(name: "sort", value: "top"), URLQueryItem(name: "limit", value: "\(limit)")]
        ) else { return [] }
        let request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        guard let result = try? await session.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        return Self.redditFeedComments(from: result.0, limit: limit)
    }

    static func redditFeedComments(from data: Data, limit: Int) -> [AggregatorComment] {
        guard let feed = try? FeedParser().parse(data: data, fallbackTitle: "") else { return [] }
        let comments = feed.articles
            // The first entry (t3_) is the post itself; comments are t1_.
            .filter { !($0.guid ?? "").hasPrefix("t3_") }
            .compactMap { entry -> AggregatorComment? in
                guard let author = entry.author, let html = entry.contentHTML else { return nil }
                let body = commentText(fromHTML: html)
                guard !body.isEmpty, body != "[deleted]", body != "[removed]" else { return nil }
                let name = author.hasPrefix("/u/") ? String(author.dropFirst(3)) : author
                let id = entry.guid.map { $0.hasPrefix("t1_") ? String($0.dropFirst(3)) : $0 } ?? UUID().uuidString
                return AggregatorComment(id: id, author: name, score: nil, body: body, depth: 0)
            }
        return Array(comments.prefix(limit))
    }

    private func redditThreadURL(from commentsURL: URL, host: String, extension ext: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: commentsURL, resolvingAgainstBaseURL: false) else { return nil }
        if let current = components.host?.lowercased(), Self.isRedditHost(current) {
            components.host = host
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in [".json", ".rss"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        components.path = path + ext
        components.queryItems = queryItems
        return components.url
    }

    private static func isRedditHost(_ host: String) -> Bool {
        host == "reddit.com"
            || host == "www.reddit.com"
            || host == "old.reddit.com"
            || host == "new.reddit.com"
            || host.hasSuffix(".reddit.com")
            || host == "redd.it"
    }

    // MARK: - Lobsters

    private func fetchLobstersComments(article: SkimCore.Article, limit: Int) async -> [AggregatorComment] {
        // Lobsters JSON API: replace lobste.rs/s/<id> with lobste.rs/s/<id>.json
        guard let candidate = article.commentsURL ?? article.url else { return [] }
        guard let host = candidate.host?.lowercased(),
              host == "lobste.rs" || host.hasSuffix(".lobste.rs")
        else { return [] }

        var path = candidate.path
        if path.hasSuffix("/") { path.removeLast() }
        guard let jsonURL = URL(string: candidate.scheme.map({ "\($0)://\(host)\(path).json" }) ?? "") else { return [] }

        do {
            var request = URLRequest(url: jsonURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("Skim/1.0 (RSS reader)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let comments = json["comments"] as? [[String: Any]]
            else { return [] }
            return Self.lobstersComments(comments, limit: limit)
        } catch {
            return []
        }
    }

    /// Lobsters already lists comments in thread order with each one's depth.
    static func lobstersComments(_ items: [[String: Any]], limit: Int) -> [AggregatorComment] {
        var comments: [AggregatorComment] = []
        var topLevel = 0
        // While set, comments deeper than this belong to a dropped comment.
        var skipBelow: Int?
        for item in items {
            let isTop = item["parent_comment"] == nil || item["parent_comment"] is NSNull
            let depth = max(0, (item["depth"] as? Int) ?? (item["indent_level"] as? Int).map { $0 - 1 } ?? (isTop ? 0 : 1))
            if let skip = skipBelow {
                if depth > skip { continue }
                skipBelow = nil
            }
            if depth == 0 {
                topLevel += 1
                if topLevel > limit { break }
            }
            guard comments.count < maxThreadComments else { break }
            if depth <= maxCommentDepth, let comment = lobstersComment(from: item, depth: depth) {
                comments.append(comment)
            } else {
                skipBelow = depth
            }
        }
        return comments
    }

    private static func lobstersComment(from dict: [String: Any], depth: Int) -> AggregatorComment? {
        let user = dict["commenting_user"]
        guard let author = (user as? String) ?? (user as? [String: Any])?["username"] as? String ?? dict["author"] as? String,
              let body = dict["comment"] as? String,
              !body.isEmpty
        else { return nil }
        let id = (dict["short_id"] as? String) ?? UUID().uuidString
        let score = dict["score"] as? Int
        return AggregatorComment(
            id: id,
            author: author,
            score: score,
            body: commentText(fromHTML: body),
            depth: depth
        )
    }

    /// Plain text for a comment's HTML that keeps its paragraph breaks.
    static func commentText(fromHTML html: String) -> String {
        html
            .replacingOccurrences(of: "(?i)</p>\\s*<p(\\s[^>]*)?>|<p(\\s[^>]*)?>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodingHTMLEntities
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
