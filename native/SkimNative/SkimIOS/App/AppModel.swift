import Foundation
import SkimCore
import UniformTypeIdentifiers

enum ArticleListMode: String, CaseIterable, Identifiable {
    case unread
    case all
    case starred

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unread: "Unread"
        case .all: "All"
        case .starred: "Starred"
        }
    }

    var systemImage: String {
        switch self {
        case .unread: "circle.fill"
        case .all: "list.bullet"
        case .starred: "star"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var feeds: [Feed] = []
    @Published var articles: [Article] = []
    @Published var listMode: ArticleListMode = .unread
    @Published var selectedFeedID: String?
    @Published var searchQuery = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

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
        return listMode == .starred ? "Starred" : "All Articles"
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
            feeds = try await store.listFeeds()
            articles = try await store.listArticles(filter: filter)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadArticles() async {
        do {
            feeds = try await store.listFeeds()
            articles = try await store.listArticles(filter: filter)
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

    func setRead(_ article: Article, isRead: Bool) async {
        do {
            try await store.setArticleRead(id: article.id, isRead: isRead)
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

    func updatedArticle(id: String) async -> Article? {
        try? await store.article(id: id)
    }
}
