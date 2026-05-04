import SkimCore
import SwiftUI
import UniformTypeIdentifiers

struct ArticleListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showImporter = false
    @State private var showFeedPicker = false

    var body: some View {
        ZStack {
            SkimStyle.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                header
                searchField
                content
                bottomFilter
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.xml, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.importOPML(url: url) }
        }
        .confirmationDialog("Feed", isPresented: $showFeedPicker) {
            Button("All Articles") {
                model.selectedFeedID = nil
                Task { await model.reloadArticles() }
            }
            ForEach(model.feeds) { feed in
                Button(feed.title) {
                    model.selectedFeedID = feed.id
                    Task { await model.reloadArticles() }
                }
            }
        }
        .onChange(of: model.listMode) { _, _ in
            Task { await model.reloadArticles() }
        }
        .onChange(of: model.searchQuery) { _, _ in
            Task { await model.reloadArticles() }
        }
        .alert("Skim", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack {
            BorderlessIconButton(systemName: "line.3.horizontal", title: "Feeds") {
                showFeedPicker = true
            }
            Spacer()
            BorderlessIconButton(systemName: "tray.and.arrow.down", title: "Import OPML") {
                showImporter = true
            }
            BorderlessIconButton(systemName: "arrow.clockwise", title: "Refresh") {
                Task { await model.refreshAll() }
            }
            BorderlessIconButton(systemName: "checkmark.circle", title: "Unread", isActive: model.listMode == .unread) {
                model.listMode = .unread
            }
            BorderlessIconButton(systemName: "magnifyingglass", title: "Search") {}
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(SkimStyle.text)
                .lineLimit(2)
            Text("\(model.articles.filter { !$0.isRead }.count) Unread Items")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SkimStyle.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SkimStyle.secondary)
            TextField("Search articles...", text: $model.searchQuery)
                .textInputAutocapitalization(.never)
                .foregroundStyle(SkimStyle.text)
                .font(.system(size: 18))
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(SkimStyle.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.feeds.isEmpty && model.articles.isEmpty && !model.isLoading {
            VStack(spacing: 18) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(SkimStyle.secondary)

                VStack(spacing: 8) {
                    Text("Import OPML to begin")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(SkimStyle.text)
                        .multilineTextAlignment(.center)

                    Text("Bring in your feeds and Skim will fetch the first batch of articles.")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(SkimStyle.text.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 320)
                }

                Button("Import OPML") { showImporter = true }
                    .buttonStyle(.glassProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
            .padding(.bottom, 18)
        } else {
            List {
                ForEach(groupedArticles, id: \.label) { group in
                    Section {
                        ForEach(group.articles) { article in
                            NavigationLink(value: article.id) {
                                ArticleRow(article: article)
                                    .listRowInsets(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 18))
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    Task { await model.setRead(article, isRead: !article.isRead) }
                                } label: {
                                    Label(article.isRead ? "Unread" : "Read", systemImage: article.isRead ? "circle" : "checkmark")
                                }
                                .tint(SkimStyle.accent)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task { await model.toggleStar(article) }
                                } label: {
                                    Label("Star", systemImage: "star")
                                }
                                .tint(.yellow)
                            }
                        }
                    } header: {
                        Text(group.label)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(SkimStyle.secondary)
                            .tracking(1.6)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable {
                await model.refreshAll()
            }
            .navigationDestination(for: String.self) { id in
                ArticleDetailView(articleID: id)
            }
        }
    }

    private var bottomFilter: some View {
        HStack(spacing: 28) {
            ForEach(ArticleListMode.allCases) { mode in
                Button {
                    model.listMode = mode
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 18, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.listMode == mode ? SkimStyle.accent : SkimStyle.secondary)
            }
        }
        .frame(height: 58)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var groupedArticles: [(label: String, articles: [Article])] {
        Dictionary(grouping: model.articles) { article in
            let date = article.publishedAt ?? article.fetchedAt
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        }
        .map { ($0.key.uppercased(), $0.value.sorted { ($0.publishedAt ?? $0.fetchedAt) > ($1.publishedAt ?? $1.fetchedAt) }) }
        .sorted { ($0.articles.first?.publishedAt ?? .distantPast) > ($1.articles.first?.publishedAt ?? .distantPast) }
    }
}

private struct ArticleRow: View {
    var article: Article

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(article.isRead ? SkimStyle.secondary.opacity(0.35) : SkimStyle.accent)
                .frame(width: 9, height: 9)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(article.title)
                    .font(.system(size: 19, weight: article.isRead ? .regular : .semibold))
                    .foregroundStyle(article.isRead ? SkimStyle.secondary : SkimStyle.text)
                    .lineLimit(3)

                HStack(spacing: 8) {
                    Text(article.feedTitle)
                        .foregroundStyle(SkimStyle.accent)
                    if let publishedAt = article.publishedAt {
                        Text(publishedAt, style: .relative)
                            .foregroundStyle(SkimStyle.secondary)
                    }
                    if article.isStarred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                .font(.system(size: 15, weight: .medium))
            }
        }
        .padding(.vertical, 4)
    }
}
