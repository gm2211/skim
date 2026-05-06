import Foundation
import SkimCore
import UniformTypeIdentifiers

enum ArticleListMode: String, CaseIterable, Identifiable {
    case unread
    case all
    case recent
    case starred

    static var allCases: [ArticleListMode] {
        [.unread, .all, .starred]
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unread: "Unread"
        case .all: "All"
        case .recent: "Recent"
        case .starred: "Starred"
        }
    }

    var systemImage: String {
        switch self {
        case .unread: "circle.fill"
        case .all: "list.bullet"
        case .recent: "clock"
        case .starred: "star"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var feeds: [Feed] = []
    @Published var folders: [FeedFolder] = []
    @Published var articles: [Article] = []
    @Published var listMode: ArticleListMode = .unread
    @Published var selectedFeedID: String?
    @Published var selectedFolderID: String?
    @Published var searchQuery = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var unreadCounts: [String: Int] = [:]
    @Published var totalUnreadCount = 0
    @Published var settings = AppSettings()

    let store: SkimStore
    private let importer = OPMLImportService()
    private let refresher = FeedRefreshService()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SkimNative", isDirectory: true)
        let url = support.appendingPathComponent("skim.sqlite")
        do {
            self.store = try SkimStore(databaseURL: url)
        } catch {
            fatalError("Could not open Skim database: \(error)")
        }
    }

    var title: String {
        if let selectedFeedID, let feed = feeds.first(where: { $0.id == selectedFeedID }) {
            return feed.title
        }
        switch listMode {
        case .starred:
            return "Starred"
        case .recent:
            return "Recent"
        case .unread, .all:
            return "All Articles"
        }
    }

    var currentUnreadCount: Int {
        if let selectedFeedID {
            return unreadCounts[selectedFeedID] ?? 0
        }
        return totalUnreadCount
    }

    var filter: ArticleFilter {
        ArticleFilter(
            feedID: selectedFeedID,
            readState: listMode == .unread ? .unread : .all,
            starredOnly: listMode == .starred,
            searchQuery: searchQuery,
            limit: 500
        )
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            folders = try await store.listFolders()
            feeds = try await store.listFeeds()
            settings = try await store.loadSettings()
            articles = try await store.listArticles(filter: filter)
            try await refreshCounts()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadArticles() async {
        do {
            folders = try await store.listFolders()
            feeds = try await store.listFeeds()
            articles = try await store.listArticles(filter: filter)
            try await refreshCounts()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshAll() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await refresher.refreshAll(store: store)
            await reloadArticles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importOPML(url: URL) async {
        isLoading = true
        defer { isLoading = false }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let imported = try importer.parseOPML(data: data)
            try await store.importFeeds(imported)
            feeds = try await store.listFeeds()
            try await refresher.refreshAll(store: store)
            await reloadArticles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addFeed(urlString: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let url = try normalizedFeedURL(from: urlString)
            let feed = Feed(
                id: stableID(prefix: "feed", value: url.absoluteString),
                title: url.host(percentEncoded: false) ?? url.absoluteString,
                url: url
            )
            try await refresher.refresh(feed: feed, store: store)
            selectedFeedID = feed.id
            listMode = .unread
            await reloadArticles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setRead(_ article: Article, isRead: Bool) async {
        do {
            try await store.setArticleRead(id: article.id, isRead: isRead)
            await reloadArticles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setRead(_ articles: [Article], isRead: Bool) async {
        do {
            for article in articles {
                try await store.setArticleRead(id: article.id, isRead: isRead)
            }
            await reloadArticles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleStar(_ article: Article) async {
        do {
            try await store.toggleStar(id: article.id)
            await reloadArticles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveSettings(_ next: AppSettings) async {
        do {
            try await store.saveSettings(next)
            settings = next
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Applies an auto-group proposal: creates missing folders, assigns feeds, persists all.
    /// `proposal` maps folder name → array of feed IDs to assign.
    func applyOrganization(proposal: [(folderName: String, feedIDs: [String])]) async {
        do {
            // Remove existing folder assignments for all feeds being touched
            let touchedFeedIDs = proposal.flatMap(\.feedIDs)
            for feedID in touchedFeedIDs {
                try await store.setFeedFolder(feedID: feedID, folderID: nil)
            }

            // Create or reuse folders and assign feeds
            for (index, entry) in proposal.enumerated() {
                let name = entry.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !entry.feedIDs.isEmpty else { continue }

                let folderID = stableID(prefix: "folder", value: name.lowercased())
                let folder = FeedFolder(id: folderID, name: name, sortOrder: index)
                try await store.upsertFolder(folder)

                for feedID in entry.feedIDs {
                    try await store.setFeedFolder(feedID: feedID, folderID: folderID)
                }
            }

            await reloadArticles()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updatedArticle(id: String) async -> Article? {
        try? await store.article(id: id)
    }

    func articlesForAIContext(preferred: [Article], limit: Int = 45) async throws -> [Article] {
        let visible = Array(preferred.prefix(limit))
        if !visible.isEmpty {
            return visible
        }

        let contextualFilter = ArticleFilter(
            feedID: selectedFeedID,
            readState: .all,
            starredOnly: listMode == .starred,
            searchQuery: searchQuery,
            limit: limit
        )
        let contextual = try await store.listArticles(filter: contextualFilter)
        if !contextual.isEmpty {
            return contextual
        }

        return try await store.listArticles(
            filter: ArticleFilter(
                readState: .all,
                limit: limit
            )
        )
    }

    private func refreshCounts() async throws {
        totalUnreadCount = try await store.countUnread(feedID: nil)
        var next: [String: Int] = [:]
        for feed in feeds {
            next[feed.id] = try await store.countUnread(feedID: feed.id)
        }
        unreadCounts = next
    }

    private func normalizedFeedURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkimCoreError.invalidFeedURL }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme)?.upgradingHTTPToHTTPS(),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host() != nil
        else {
            throw SkimCoreError.invalidFeedURL
        }
        return url
    }
}
