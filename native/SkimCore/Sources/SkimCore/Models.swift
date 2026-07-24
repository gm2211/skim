import Foundation

public struct Feed: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var url: URL
    public var siteURL: URL?
    public var iconURL: URL?
    public var fetchedAt: Date?
    public var folderID: String?

    public init(id: String, title: String, url: URL, siteURL: URL? = nil, iconURL: URL? = nil, fetchedAt: Date? = nil, folderID: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.siteURL = siteURL
        self.iconURL = iconURL
        self.fetchedAt = fetchedAt
        self.folderID = folderID
    }
}

/// Identifies articles sourced from a link aggregator, where the RSS item points
/// to an external article rather than providing the full article content itself.
public enum AggregatorKind: String, Codable, Hashable, Sendable {
    case hackerNews
    case reddit
    case lobsters
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

    // Aggregator support: set when the article is from HN, Reddit, Lobsters, etc.
    // `url` is the aggregator item page; `externalURL` is the linked external article.
    public var aggregatorKind: AggregatorKind?
    public var externalURL: URL?
    public var commentsURL: URL?

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
        isStarred: Bool = false,
        aggregatorKind: AggregatorKind? = nil,
        externalURL: URL? = nil,
        commentsURL: URL? = nil
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
        self.aggregatorKind = aggregatorKind
        self.externalURL = externalURL
        self.commentsURL = commentsURL
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
    public var offlinePreloadLimit: Int
    public var ai: AISettings

    public init(prefersUnreadOnly: Bool = true, offlinePreloadLimit: Int = 300, ai: AISettings = AISettings()) {
        self.prefersUnreadOnly = prefersUnreadOnly
        self.offlinePreloadLimit = offlinePreloadLimit
        self.ai = ai
    }

    enum CodingKeys: String, CodingKey {
        case prefersUnreadOnly
        case offlinePreloadLimit
        case ai
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prefersUnreadOnly = try container.decodeIfPresent(Bool.self, forKey: .prefersUnreadOnly) ?? true
        offlinePreloadLimit = try container.decodeIfPresent(Int.self, forKey: .offlinePreloadLimit) ?? 300
        ai = try container.decodeIfPresent(AISettings.self, forKey: .ai) ?? AISettings()
    }
}

public struct AISettings: Codable, Equatable, Sendable {
    public var provider: String
    public var apiKey: String?
    public var model: String?
    public var localModelPath: String?
    public var endpoint: String?
    public var chatProvider: String?
    public var chatModel: String?
    public var chatApiKey: String?
    public var chatEndpoint: String?
    public var summaryLength: String?
    public var summaryTone: String?
    public var summaryCustomWordCount: Int?
    public var summaryCustomPrompt: String?
    public var triageUserPrompt: String?

    // MLX sampling parameters (nil means use per-model preset)
    public var mlxTemperature: Double?
    public var mlxTopP: Double?
    public var mlxRepetitionPenalty: Double?
    public var mlxRepetitionContextSize: Int?
    public var mlxMaxTokens: Int?

    // MLX chat web search (nil = default on)
    public var localChatWebSearch: Bool?

    public init(
        provider: String = "foundation-models",
        apiKey: String? = nil,
        model: String? = nil,
        localModelPath: String? = nil,
        endpoint: String? = nil,
        chatProvider: String? = nil,
        chatModel: String? = nil,
        chatApiKey: String? = nil,
        chatEndpoint: String? = nil,
        summaryLength: String? = "short",
        summaryTone: String? = "concise",
        summaryCustomWordCount: Int? = nil,
        summaryCustomPrompt: String? = nil,
        triageUserPrompt: String? = nil,
        mlxTemperature: Double? = nil,
        mlxTopP: Double? = nil,
        mlxRepetitionPenalty: Double? = nil,
        mlxRepetitionContextSize: Int? = nil,
        mlxMaxTokens: Int? = nil,
        localChatWebSearch: Bool? = nil
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.localModelPath = localModelPath
        self.endpoint = endpoint
        self.chatProvider = chatProvider
        self.chatModel = chatModel
        self.chatApiKey = chatApiKey
        self.chatEndpoint = chatEndpoint
        self.summaryLength = summaryLength
        self.summaryTone = summaryTone
        self.summaryCustomWordCount = summaryCustomWordCount
        self.summaryCustomPrompt = summaryCustomPrompt
        self.triageUserPrompt = triageUserPrompt
        self.mlxTemperature = mlxTemperature
        self.mlxTopP = mlxTopP
        self.mlxRepetitionPenalty = mlxRepetitionPenalty
        self.mlxRepetitionContextSize = mlxRepetitionContextSize
        self.mlxMaxTokens = mlxMaxTokens
        self.localChatWebSearch = localChatWebSearch
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case apiKey
        case model
        case localModelPath
        case endpoint
        case chatProvider
        case chatModel
        case chatApiKey
        case chatEndpoint
        case summaryLength
        case summaryTone
        case summaryCustomWordCount
        case summaryCustomPrompt
        case triageUserPrompt
        case mlxTemperature
        case mlxTopP
        case mlxRepetitionPenalty
        case mlxRepetitionContextSize
        case mlxMaxTokens
        case localChatWebSearch
    }

    enum LegacyCodingKeys: String, CodingKey {
        case api_key
        case local_model_path
        case chat_provider
        case chat_model
        case chat_api_key
        case chat_endpoint
        case summary_length
        case summary_tone
        case summary_custom_word_count
        case summary_custom_prompt
        case triage_user_prompt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "foundation-models"
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? legacy.decodeIfPresent(String.self, forKey: .api_key)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        localModelPath = try container.decodeIfPresent(String.self, forKey: .localModelPath) ?? legacy.decodeIfPresent(String.self, forKey: .local_model_path)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        chatProvider = try container.decodeIfPresent(String.self, forKey: .chatProvider) ?? legacy.decodeIfPresent(String.self, forKey: .chat_provider)
        chatModel = try container.decodeIfPresent(String.self, forKey: .chatModel) ?? legacy.decodeIfPresent(String.self, forKey: .chat_model)
        chatApiKey = try container.decodeIfPresent(String.self, forKey: .chatApiKey) ?? legacy.decodeIfPresent(String.self, forKey: .chat_api_key)
        chatEndpoint = try container.decodeIfPresent(String.self, forKey: .chatEndpoint) ?? legacy.decodeIfPresent(String.self, forKey: .chat_endpoint)
        summaryLength = try container.decodeIfPresent(String.self, forKey: .summaryLength) ?? legacy.decodeIfPresent(String.self, forKey: .summary_length) ?? "short"
        summaryTone = try container.decodeIfPresent(String.self, forKey: .summaryTone) ?? legacy.decodeIfPresent(String.self, forKey: .summary_tone) ?? "concise"
        summaryCustomWordCount = try container.decodeIfPresent(Int.self, forKey: .summaryCustomWordCount) ?? legacy.decodeIfPresent(Int.self, forKey: .summary_custom_word_count)
        summaryCustomPrompt = try container.decodeIfPresent(String.self, forKey: .summaryCustomPrompt) ?? legacy.decodeIfPresent(String.self, forKey: .summary_custom_prompt)
        triageUserPrompt = try container.decodeIfPresent(String.self, forKey: .triageUserPrompt) ?? legacy.decodeIfPresent(String.self, forKey: .triage_user_prompt)
        mlxTemperature = try container.decodeIfPresent(Double.self, forKey: .mlxTemperature)
        mlxTopP = try container.decodeIfPresent(Double.self, forKey: .mlxTopP)
        mlxRepetitionPenalty = try container.decodeIfPresent(Double.self, forKey: .mlxRepetitionPenalty)
        mlxRepetitionContextSize = try container.decodeIfPresent(Int.self, forKey: .mlxRepetitionContextSize)
        mlxMaxTokens = try container.decodeIfPresent(Int.self, forKey: .mlxMaxTokens)
        localChatWebSearch = try container.decodeIfPresent(Bool.self, forKey: .localChatWebSearch)
    }
}

public struct FeedFolder: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var sortOrder: Int
    public var isSmart: Bool
    public var rulesJSON: String?

    public init(id: String, name: String, sortOrder: Int = 0, isSmart: Bool = false, rulesJSON: String? = nil) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.isSmart = isSmart
        self.rulesJSON = rulesJSON
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

/// How an article contributes to a durable story cluster.
///
/// `duplicate` means the article is interchangeable with another source item,
/// while `coverage` preserves a distinct source's reporting on the same event.
public enum StoryMembershipType: String, Codable, CaseIterable, Hashable, Sendable {
    case duplicate = "duplicate"
    case coverage = "coverage"
    case update = "update"
}

public struct Story: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var summary: String?
    public var representativeArticleID: String?
    public var firstSeenAt: Date
    public var lastActivityAt: Date
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        summary: String? = nil,
        representativeArticleID: String? = nil,
        firstSeenAt: Date,
        lastActivityAt: Date,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.representativeArticleID = representativeArticleID
        self.firstSeenAt = firstSeenAt
        self.lastActivityAt = lastActivityAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case summary
        case representativeArticleID = "representative_article_id"
        case firstSeenAt = "first_seen_at"
        case lastActivityAt = "last_activity_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct StoryArticleMembership: Codable, Hashable, Sendable {
    public var storyID: String
    public var articleID: String
    public var membershipType: StoryMembershipType
    public var confidence: Double?
    public var addedAt: Date

    public init(
        storyID: String,
        articleID: String,
        membershipType: StoryMembershipType,
        confidence: Double? = nil,
        addedAt: Date = Date()
    ) {
        self.storyID = storyID
        self.articleID = articleID
        self.membershipType = membershipType
        self.confidence = confidence
        self.addedAt = addedAt
    }

    enum CodingKeys: String, CodingKey {
        case storyID = "story_id"
        case articleID = "article_id"
        case membershipType = "membership_type"
        case confidence
        case addedAt = "added_at"
    }
}

public struct StoryRevision: Identifiable, Codable, Hashable, Sendable {
    public var storyID: String
    public var revisionNumber: Int
    public var title: String
    public var summary: String
    public var deltaSummary: String?
    public var representativeArticleID: String?
    public var sourceCount: Int
    public var contentFingerprint: String?
    public var isMaterialChange: Bool
    public var createdAt: Date

    public var id: String {
        "\(storyID):\(revisionNumber)"
    }

    public init(
        storyID: String,
        revisionNumber: Int,
        title: String,
        summary: String,
        deltaSummary: String? = nil,
        representativeArticleID: String? = nil,
        sourceCount: Int,
        contentFingerprint: String? = nil,
        isMaterialChange: Bool = true,
        createdAt: Date = Date()
    ) {
        self.storyID = storyID
        self.revisionNumber = revisionNumber
        self.title = title
        self.summary = summary
        self.deltaSummary = deltaSummary
        self.representativeArticleID = representativeArticleID
        self.sourceCount = sourceCount
        self.contentFingerprint = contentFingerprint
        self.isMaterialChange = isMaterialChange
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case storyID = "story_id"
        case revisionNumber = "revision_number"
        case title
        case summary
        case deltaSummary = "delta_summary"
        case representativeArticleID = "representative_article_id"
        case sourceCount = "source_count"
        case contentFingerprint = "content_fingerprint"
        case isMaterialChange = "is_material_change"
        case createdAt = "created_at"
    }
}

/// Per-story progress is revision based. It intentionally does not mirror or
/// mutate the read flag of every source article in the cluster.
public struct StoryUserState: Codable, Hashable, Sendable {
    public var storyID: String
    public var lastSeenRevision: Int?
    public var lastReadRevision: Int?
    public var isFollowed: Bool
    public var isHidden: Bool
    public var caughtUpAt: Date?
    public var updatedAt: Date

    public init(
        storyID: String,
        lastSeenRevision: Int? = nil,
        lastReadRevision: Int? = nil,
        isFollowed: Bool = false,
        isHidden: Bool = false,
        caughtUpAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.storyID = storyID
        self.lastSeenRevision = lastSeenRevision
        self.lastReadRevision = lastReadRevision
        self.isFollowed = isFollowed
        self.isHidden = isHidden
        self.caughtUpAt = caughtUpAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case storyID = "story_id"
        case lastSeenRevision = "last_seen_revision"
        case lastReadRevision = "last_read_revision"
        case isFollowed = "is_followed"
        case isHidden = "is_hidden"
        case caughtUpAt = "caught_up_at"
        case updatedAt = "updated_at"
    }
}

public enum EditionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case draft = "draft"
    case ready = "ready"
    case completed = "completed"
    case failed = "failed"
}

public struct Edition: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var scope: String
    public var storyLimit: Int
    public var status: EditionStatus
    public var startsAt: Date
    public var endsAt: Date
    public var generatedAt: Date
    public var completedAt: Date?
    public var totalSourceCount: Int

    public init(
        id: String,
        title: String,
        scope: String,
        storyLimit: Int,
        status: EditionStatus = .draft,
        startsAt: Date,
        endsAt: Date,
        generatedAt: Date = Date(),
        completedAt: Date? = nil,
        totalSourceCount: Int
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.storyLimit = storyLimit
        self.status = status
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.generatedAt = generatedAt
        self.completedAt = completedAt
        self.totalSourceCount = totalSourceCount
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case scope
        case storyLimit = "story_limit"
        case status
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case generatedAt = "generated_at"
        case completedAt = "completed_at"
        case totalSourceCount = "total_source_count"
    }
}

/// A frozen rendering of a story revision as it appeared in an edition.
/// Snapshot fields are insert-only in the persistence layer.
public struct EditionItem: Identifiable, Codable, Hashable, Sendable {
    public var editionID: String
    public var storyID: String
    public var storyRevisionNumber: Int
    public var position: Int
    public var section: String
    public var snapshotTitle: String
    public var snapshotSummary: String
    public var snapshotDeltaSummary: String?
    public var snapshotSourceCount: Int
    public var snapshotReason: String?
    public var isUniqueFind: Bool
    public var isConsumed: Bool
    public var consumedAt: Date?

    public var id: String {
        "\(editionID):\(storyID)"
    }

    public init(
        editionID: String,
        storyID: String,
        storyRevisionNumber: Int,
        position: Int,
        section: String,
        snapshotTitle: String,
        snapshotSummary: String,
        snapshotDeltaSummary: String? = nil,
        snapshotSourceCount: Int,
        snapshotReason: String? = nil,
        isUniqueFind: Bool = false,
        isConsumed: Bool = false,
        consumedAt: Date? = nil
    ) {
        self.editionID = editionID
        self.storyID = storyID
        self.storyRevisionNumber = storyRevisionNumber
        self.position = position
        self.section = section
        self.snapshotTitle = snapshotTitle
        self.snapshotSummary = snapshotSummary
        self.snapshotDeltaSummary = snapshotDeltaSummary
        self.snapshotSourceCount = snapshotSourceCount
        self.snapshotReason = snapshotReason
        self.isUniqueFind = isUniqueFind
        self.isConsumed = isConsumed
        self.consumedAt = consumedAt
    }

    enum CodingKeys: String, CodingKey {
        case editionID = "edition_id"
        case storyID = "story_id"
        case storyRevisionNumber = "story_revision_number"
        case position
        case section
        case snapshotTitle = "snapshot_title"
        case snapshotSummary = "snapshot_summary"
        case snapshotDeltaSummary = "snapshot_delta_summary"
        case snapshotSourceCount = "snapshot_source_count"
        case snapshotReason = "snapshot_reason"
        case isUniqueFind = "is_unique_find"
        case isConsumed = "is_consumed"
        case consumedAt = "consumed_at"
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
