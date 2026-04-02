import SwiftUI
import SwiftData

struct ArticleListView: View {
    @EnvironmentObject var appState: AppState
    @Query(sort: \Article.fetchedAt, order: .reverse) private var allArticles: [Article]

    var filteredArticles: [Article] {
        var articles = allArticles

        // Filter by sidebar section
        switch appState.currentView {
        case .allArticles:
            break
        case .starred:
            articles = articles.filter { $0.isStarred }
        case .inbox:
            articles = articles.filter { $0.triagePriority != nil }
                .sorted { ($0.triagePriority ?? 0) > ($1.triagePriority ?? 0) }
        case .themes:
            break // TODO: implement theme filtering
        case .feed(let feedId):
            articles = articles.filter { $0.feed?.id == feedId }
        }

        // Apply list filter
        switch appState.listFilter {
        case .all:
            break
        case .unread:
            articles = articles.filter { !$0.isRead }
        case .starred:
            articles = articles.filter { $0.isStarred }
        }

        return articles
    }

    var body: some View {
        List(filteredArticles, selection: Binding(
            get: { appState.selectedArticle },
            set: { article in
                appState.selectedArticle = article
                if let article = article {
                    article.isRead = true
                }
            }
        )) { article in
            ArticleRowView(article: article)
                .tag(article)
        }
        .listStyle(.plain)
        .navigationTitle(sectionTitle)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Picker("Filter", selection: $appState.listFilter) {
                    ForEach(AppState.ListFilter.allCases, id: \.self) { filter in
                        switch filter {
                        case .all:
                            Label("All", systemImage: "list.bullet")
                        case .unread:
                            Label("Unread", systemImage: "circle.fill")
                        case .starred:
                            Label("Starred", systemImage: "star.fill")
                        }
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .overlay {
            if filteredArticles.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "doc.text",
                    description: Text("No articles match the current filter"))
            }
        }
    }

    var sectionTitle: String {
        switch appState.currentView {
        case .allArticles: return "All Articles"
        case .starred: return "Starred"
        case .inbox: return "AI Inbox"
        case .themes: return "Themes"
        case .feed(let feedId):
            return allArticles.first { $0.feed?.id == feedId }?.feed?.title ?? "Feed"
        }
    }
}

struct ArticleRowView: View {
    let article: Article

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Triage indicator
            if let priority = article.triagePriority, let p = TriagePriority(rawValue: priority) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(priorityColor(p))
                        .frame(width: 6, height: 6)
                    Text(article.triageReason ?? p.label)
                        .font(.caption2)
                        .foregroundStyle(priorityColor(p))
                }
            }

            Text(article.title)
                .font(.headline)
                .fontWeight(article.isRead ? .regular : .semibold)
                .foregroundStyle(article.isRead ? .secondary : .primary)
                .lineLimit(2)

            HStack(spacing: 4) {
                if let feedTitle = article.feed?.title {
                    Text(feedTitle)
                        .font(.caption)
                        .foregroundStyle(.accent)
                }
                Text("·")
                    .foregroundStyle(.secondary)
                Text(article.displayDate, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if article.isStarred {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding(.vertical, 4)
    }

    func priorityColor(_ priority: TriagePriority) -> Color {
        switch priority {
        case .mustRead: return .red
        case .important: return .orange
        case .worthReading: return .blue
        case .routine, .skip: return .gray
        }
    }
}
