import SwiftUI
import SwiftData

struct ArticleListView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Article.fetchedAt, order: .reverse) private var allArticles: [Article]
    @State private var searchText: String = ""
    @State private var isSearchPresented: Bool = false

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

        // Apply search text
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let lower = query.lowercased()
            articles = articles.filter { article in
                article.title.lowercased().contains(lower)
                    || (article.author?.lowercased().contains(lower) ?? false)
                    || (article.contentText?.lowercased().contains(lower) ?? false)
                    || (article.feed?.title.lowercased().contains(lower) ?? false)
            }
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
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        article.isRead.toggle()
                    } label: {
                        Label(
                            article.isRead ? "Mark Unread" : "Mark Read",
                            systemImage: article.isRead ? "circle.fill" : "circle"
                        )
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        article.triagePriority = TriagePriority.skip.rawValue
                        article.triageReason = "Skipped"
                    } label: {
                        Label("Skip", systemImage: "xmark.bin")
                    }

                    Button {
                        article.isStarred.toggle()
                    } label: {
                        Label(
                            article.isStarred ? "Unstar" : "Star",
                            systemImage: article.isStarred ? "star.slash" : "star.fill"
                        )
                    }
                    .tint(.yellow)
                }
        }
        .listStyle(.plain)
        .navigationTitle(sectionTitle)
        .searchable(text: $searchText, isPresented: $isSearchPresented, placement: .automatic, prompt: "Search articles")
        .refreshable {
            await appState.refreshAllFeeds(modelContext: modelContext)
        }
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
        .background(
            ArticleListShortcuts(
                articles: filteredArticles,
                selected: Binding(
                    get: { appState.selectedArticle },
                    set: { appState.selectedArticle = $0 }
                ),
                onAddFeed: { appState.showAddFeed = true },
                onFocusSearch: { isSearchPresented = true }
            )
        )
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

/// Hidden buttons that expose keyboard shortcuts (iPad hardware keyboard + macOS Catalyst).
private struct ArticleListShortcuts: View {
    let articles: [Article]
    @Binding var selected: Article?
    let onAddFeed: () -> Void
    let onFocusSearch: () -> Void

    var body: some View {
        // Buttons are invisible but still receive keyboard shortcuts.
        Group {
            Button("Next Article", action: selectNext)
                .keyboardShortcut("j", modifiers: [])
            Button("Previous Article", action: selectPrevious)
                .keyboardShortcut("k", modifiers: [])
            Button("Toggle Read", action: toggleRead)
                .keyboardShortcut("r", modifiers: [])
            Button("Toggle Starred", action: toggleStarred)
                .keyboardShortcut("s", modifiers: [])
            Button("Focus Search", action: onFocusSearch)
                .keyboardShortcut("/", modifiers: [])
            Button("Add Feed", action: onAddFeed)
                .keyboardShortcut("n", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func selectNext() {
        guard !articles.isEmpty else { return }
        if let current = selected, let idx = articles.firstIndex(of: current) {
            let next = articles.index(after: idx)
            if next < articles.endIndex {
                selected = articles[next]
                articles[next].isRead = true
            }
        } else {
            selected = articles.first
            articles.first?.isRead = true
        }
    }

    private func selectPrevious() {
        guard !articles.isEmpty else { return }
        if let current = selected, let idx = articles.firstIndex(of: current), idx > articles.startIndex {
            let prev = articles.index(before: idx)
            selected = articles[prev]
            articles[prev].isRead = true
        } else {
            selected = articles.first
            articles.first?.isRead = true
        }
    }

    private func toggleRead() {
        selected?.isRead.toggle()
    }

    private func toggleStarred() {
        selected?.isStarred.toggle()
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
                        .accessibilityLabel("Starred")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts: [String] = []
        if article.isStarred { parts.append("Starred") }
        parts.append(article.isRead ? "Read" : "Unread")
        parts.append(article.title)
        if let feed = article.feed?.title { parts.append("from \(feed)") }
        return parts.joined(separator: ", ")
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
