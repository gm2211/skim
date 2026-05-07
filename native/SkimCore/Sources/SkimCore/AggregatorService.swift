import Foundation

// MARK: - Comment model

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

// MARK: - Service

/// Fetches top comments for aggregator articles (HN, Reddit).
/// All calls are best-effort; errors are silently swallowed and an empty array returned.
public struct AggregatorService: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch up to `limit` top-level comments for the given article.
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
            return children
                .prefix(limit)
                .compactMap { hnComment(from: $0, depth: 0) }
        } catch {
            return []
        }
    }

    private func hnComment(from dict: [String: Any], depth: Int) -> AggregatorComment? {
        guard let id = (dict["id"] as? Int).map(String.init) ?? (dict["id"] as? String),
              let author = dict["author"] as? String,
              let text = dict["text"] as? String,
              !text.isEmpty
        else { return nil }
        let body = text.strippingTags().trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let commentsURL = article.commentsURL ?? article.url else { return nil }
        guard var components = URLComponents(url: commentsURL, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        path += ".json"
        components.path = path
        components.queryItems = [URLQueryItem(name: "limit", value: "1")]
        guard let jsonURL = components.url else { return nil }

        do {
            var request = URLRequest(url: jsonURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("ios:com.skimapp.skim:v1.0 (by /u/skim_reader)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let postListing = root.first,
                  let listingData = postListing["data"] as? [String: Any],
                  let children = listingData["children"] as? [[String: Any]],
                  let postData = children.first?["data"] as? [String: Any],
                  let selftext = postData["selftext"] as? String,
                  !selftext.isEmpty,
                  selftext != "[deleted]",
                  selftext != "[removed]"
            else { return nil }
            return selftext.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Reddit

    private func fetchRedditComments(article: SkimCore.Article, limit: Int) async -> [AggregatorComment] {
        // Reddit comments API: append .json to the comments permalink
        guard let commentsURL = article.commentsURL ?? article.url else { return [] }
        guard var components = URLComponents(url: commentsURL, resolvingAgainstBaseURL: false) else { return [] }
        // Strip trailing slash, then add .json
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        path += ".json"
        components.path = path
        // Ask for top comments only
        components.queryItems = [
            URLQueryItem(name: "sort", value: "top"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "depth", value: "1")
        ]
        guard let jsonURL = components.url else { return [] }

        do {
            var request = URLRequest(url: jsonURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            // Reddit requires a custom User-Agent
            request.setValue("ios:com.skimapp.skim:v1.0 (by /u/skim_reader)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  root.count >= 2,
                  let commentsListing = root[1]["data"] as? [String: Any],
                  let children = commentsListing["children"] as? [[String: Any]]
            else { return [] }
            return children
                .prefix(limit)
                .compactMap { redditComment(from: $0) }
        } catch {
            return []
        }
    }

    private func redditComment(from child: [String: Any]) -> AggregatorComment? {
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
            depth: 0
        )
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
            return comments
                .filter { ($0["parent_comment"] == nil) }  // top-level only
                .prefix(limit)
                .compactMap { lobstersComment(from: $0) }
        } catch {
            return []
        }
    }

    private func lobstersComment(from dict: [String: Any]) -> AggregatorComment? {
        guard let author = (dict["commenting_user"] as? [String: Any])?["username"] as? String ?? dict["author"] as? String,
              let body = dict["comment"] as? String,
              !body.isEmpty
        else { return nil }
        let id = (dict["short_id"] as? String) ?? UUID().uuidString
        let score = dict["score"] as? Int
        return AggregatorComment(
            id: id,
            author: author,
            score: score,
            body: body.strippingTags().trimmingCharacters(in: .whitespacesAndNewlines),
            depth: 0
        )
    }
}
