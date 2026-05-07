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
    public var ai: AISettings

    public init(prefersUnreadOnly: Bool = true, ai: AISettings = AISettings()) {
        self.prefersUnreadOnly = prefersUnreadOnly
        self.ai = ai
    }

    enum CodingKeys: String, CodingKey {
        case prefersUnreadOnly
        case ai
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prefersUnreadOnly = try container.decodeIfPresent(Bool.self, forKey: .prefersUnreadOnly) ?? true
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
        mlxMaxTokens: Int? = nil
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
