import SwiftUI
import SwiftData

@MainActor
class AppState: ObservableObject {
    @Published var selectedFeed: Feed?
    @Published var selectedArticle: Article?
    @Published var currentView: SidebarSection = .allArticles
    @Published var listFilter: ListFilter = .unread
    @Published var isRefreshing = false
    @Published var isTriaging = false
    @Published var showAddFeed = false
    @Published var showSettings = false

    enum SidebarSection: Hashable {
        case allArticles
        case starred
        case inbox
        case themes
        case feed(String) // feed ID
    }

    enum ListFilter: String, CaseIterable {
        case all
        case unread
        case starred
    }

    // Settings (stored in UserDefaults)
    @AppStorage("ai_provider") var aiProvider: String = "none"
    @AppStorage("ai_model") var aiModel: String = ""
    @AppStorage("ai_endpoint") var aiEndpoint: String = ""

    func refreshAllFeeds(modelContext: ModelContext) async {
        isRefreshing = true
        defer { isRefreshing = false }

        let descriptor = FetchDescriptor<Feed>()
        guard let feeds = try? modelContext.fetch(descriptor) else { return }

        for feed in feeds {
            guard let url = URL(string: feed.url) else { continue }
            do {
                let (_, _, articles) = try await FeedService.shared.fetchAndParseFeed(url: url)
                for articleData in articles {
                    // Check if article already exists by URL
                    if let articleUrl = articleData.url {
                        let existingDescriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.url == articleUrl })
                        if let existing = try? modelContext.fetch(existingDescriptor), !existing.isEmpty {
                            continue
                        }
                    }

                    let article = Article(title: articleData.title, feedId: feed.id)
                    article.feed = feed
                    article.url = articleData.url
                    article.author = articleData.author
                    article.contentHtml = articleData.contentHtml
                    article.contentText = articleData.contentText
                    article.publishedAt = articleData.publishedAt
                    modelContext.insert(article)
                }
                feed.lastFetchedAt = Date()
                feed.updatedAt = Date()
            } catch {
                print("Failed to refresh \(feed.title): \(error)")
            }
        }

        try? modelContext.save()
    }

    func addFeed(url: String, modelContext: ModelContext) async throws {
        guard let feedUrl = URL(string: url) else {
            throw FeedError.invalidUrl
        }

        let (title, siteUrl, articles) = try await FeedService.shared.fetchAndParseFeed(url: feedUrl)

        let feed = Feed(title: title, url: url)
        feed.siteUrl = siteUrl
        feed.lastFetchedAt = Date()
        modelContext.insert(feed)

        for articleData in articles {
            let article = Article(title: articleData.title, feedId: feed.id)
            article.feed = feed
            article.url = articleData.url
            article.author = articleData.author
            article.contentHtml = articleData.contentHtml
            article.contentText = articleData.contentText
            article.publishedAt = articleData.publishedAt
            modelContext.insert(article)
        }

        try modelContext.save()
    }

    enum FeedError: LocalizedError {
        case invalidUrl
        case fetchFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidUrl: return "Invalid feed URL"
            case .fetchFailed(let msg): return msg
            }
        }
    }
}
