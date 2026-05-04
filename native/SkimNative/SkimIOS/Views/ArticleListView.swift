import SkimCore
import SwiftUI
import UniformTypeIdentifiers

struct ArticleListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showImporter = false
    @State private var showFeedPicker = false
    @State private var showAddFeed = false

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

            if showFeedPicker {
                FeedPickerSheet(
                    isPresented: $showFeedPicker,
                    onAddFeed: {
                        showFeedPicker = false
                        showAddFeed = true
                    },
                    onImportOPML: {
                        presentImporter()
                    },
                    onRefresh: {
                        Task { await model.refreshAll() }
                    }
                )
                .environmentObject(model)
                .transition(.move(edge: .leading))
                .zIndex(1)
            }
        }
        .animation(.smooth(duration: 0.26), value: showFeedPicker)
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
        .sheet(isPresented: $showAddFeed) {
            AddFeedSheet(
                isPresented: $showAddFeed,
                onAdd: { url in
                    Task { await model.addFeed(urlString: url) }
                },
                onImportOPML: {
                    presentImporter()
                }
            )
            .presentationDetents([.height(320)])
            .presentationDragIndicator(.visible)
            .presentationBackground(SkimStyle.chrome)
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

    private func presentImporter() {
        showFeedPicker = false
        showAddFeed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showImporter = true
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 24) {
            BorderlessIconButton(systemName: "line.3.horizontal", title: "Feeds", size: 22, tapSize: 46) {
                withAnimation(.smooth(duration: 0.26)) {
                    showFeedPicker = true
                }
            }
            Spacer()
            BorderlessIconButton(systemName: "bolt", title: "Quick Catch-up", size: 27, tapSize: 48) {
            }
            BorderlessIconButton(systemName: "bubble.left", title: "Chat", size: 25, tapSize: 48) {
            }
            BorderlessIconButton(systemName: "checkmark.circle", title: "Unread", isActive: model.listMode == .unread, size: 26, tapSize: 48) {
                model.listMode = .unread
            }
            BorderlessIconButton(systemName: "magnifyingglass", title: "Search", size: 27, tapSize: 48) {
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 72)
        .background(SkimStyle.chrome)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.title)
                .font(.system(size: 27, weight: .heavy))
                .foregroundStyle(SkimStyle.text)
                .lineLimit(2)
            Text("\(model.totalUnreadCount) Unread Items")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(SkimStyle.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 46)
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SkimStyle.secondary)
                .font(.system(size: 19, weight: .regular))
            TextField("Search articles...", text: $model.searchQuery)
                .textInputAutocapitalization(.never)
                .foregroundStyle(SkimStyle.text)
                .font(.system(size: 20, weight: .regular))
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SkimStyle.separator, lineWidth: 1)
        }
        .padding(.horizontal, 46)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var content: some View {
        if model.feeds.isEmpty && model.articles.isEmpty && !model.isLoading {
            VStack(spacing: 16) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)

                VStack(spacing: 8) {
                    Text("Add a feed to begin")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(SkimStyle.text)
                        .multilineTextAlignment(.center)

                    Text("Paste an RSS or Atom URL. OPML is still here when you want the whole library.")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(SkimStyle.text.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 320)
                }

                VStack(spacing: 10) {
                    Button("Add RSS Feed") { showAddFeed = true }
                        .buttonStyle(.glassProminent)

                    Button("Import OPML") { showImporter = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SkimStyle.accent)
                }
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
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(SkimStyle.background)
                        }
                    } header: {
                        Text(group.label)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(SkimStyle.secondary)
                            .tracking(1.6)
                            .padding(.horizontal, 46)
                            .padding(.top, 18)
                            .padding(.bottom, 12)
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
        .background(SkimStyle.chrome.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SkimStyle.separator)
                .frame(height: 1)
        }
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

private struct FeedPickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var scrollTopOffset: CGFloat = 0
    var onAddFeed: () -> Void
    var onImportOPML: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        ZStack {
            SkimStyle.chrome.ignoresSafeArea()

            ScrollView {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: FeedPaneScrollOffsetKey.self,
                        value: proxy.frame(in: .named("feedPaneScroll")).minY
                    )
                }
                .frame(height: 0)

                VStack(alignment: .leading, spacing: 0) {
                    topControls

                    SkimWordmark(size: 48)
                        .padding(.horizontal, 30)
                        .padding(.bottom, model.isLoading ? 8 : 50)

                    if model.isLoading {
                        Text("Syncing...")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(SkimStyle.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.bottom, 42)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        pickerRow(
                            icon: nil,
                            title: "All Articles",
                            count: model.totalUnreadCount,
                            isSelected: model.selectedFeedID == nil,
                            action: {
                                model.selectedFeedID = nil
                                isPresented = false
                                Task { await model.reloadArticles() }
                            }
                        )

                        pickerRow(iconSystemName: "star", title: "Starred", count: nil, isSelected: model.listMode == .starred) {
                            model.selectedFeedID = nil
                            model.listMode = .starred
                            isPresented = false
                            Task { await model.reloadArticles() }
                        }

                        pickerRow(iconSystemName: "clock", title: "Recent", count: nil, isSelected: false) {
                            model.selectedFeedID = nil
                            model.listMode = .all
                            isPresented = false
                            Task { await model.reloadArticles() }
                        }

                        Spacer(minLength: 38)

                        pickerRow(iconSystemName: "tray", title: "AI Inbox", count: model.totalUnreadCount, isSelected: false) {
                            model.selectedFeedID = nil
                            model.listMode = .unread
                            isPresented = false
                            Task { await model.reloadArticles() }
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 36)

                    HStack {
                        Text("Feeds")
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(SkimStyle.text)
                        Spacer()
                        Button(action: onImportOPML) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(SkimStyle.secondary)
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 20)

                    LazyVStack(alignment: .leading, spacing: 19) {
                        ForEach(uniqueFeeds) { feed in
                            pickerRow(
                                icon: AnyView(FeedIcon(feed: feed)),
                                title: feed.title,
                                count: model.unreadCounts[feed.id],
                                isSelected: model.selectedFeedID == feed.id
                            ) {
                                model.selectedFeedID = feed.id
                                model.listMode = .unread
                                isPresented = false
                                Task { await model.reloadArticles() }
                            }
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 34)
                }
            }
            .coordinateSpace(name: "feedPaneScroll")
            .scrollIndicators(.hidden)
            .onPreferenceChange(FeedPaneScrollOffsetKey.self) { value in
                scrollTopOffset = value
            }
            .simultaneousGesture(pullRefreshGesture)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dismissGesture)
    }

    private var topControls: some View {
        ZStack {
            Button(action: onRefresh) {
                ZStack {
                    Circle()
                        .fill(model.isLoading ? Color.white.opacity(0.11) : .clear)
                        .frame(width: 42, height: 42)

                    if model.isLoading {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(SkimStyle.text)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(SkimStyle.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isLoading ? "Syncing" : "Refresh")

            HStack(spacing: 28) {
                Spacer()
                BorderlessIconButton(systemName: "bubble.left", title: "Chat", size: 24, tapSize: 44) {}
                BorderlessIconButton(systemName: "bolt", title: "Quick Catch-up", size: 27, tapSize: 44) {}
                BorderlessIconButton(systemName: "plus", title: "Add RSS Feed", size: 26, tapSize: 44, action: onAddFeed)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 30)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let shouldDismiss = value.translation.width < -80 || value.predictedEndTranslation.width < -140
                guard shouldDismiss else { return }
                withAnimation(.smooth(duration: 0.26)) {
                    isPresented = false
                }
            }
    }

    private var pullRefreshGesture: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .local)
            .onEnded { value in
                guard scrollTopOffset >= -1,
                      value.translation.height > abs(value.translation.width),
                      value.translation.height > 90 || value.predictedEndTranslation.height > 145
                else { return }
                onRefresh()
            }
    }

    private func pickerRow(
        iconSystemName: String,
        title: String,
        count: Int?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        pickerRow(
            icon: AnyView(
                Image(systemName: iconSystemName)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)
                    .frame(width: 28)
            ),
            title: title,
            count: count,
            isSelected: isSelected,
            action: action
        )
    }

    private func pickerRow(
        icon: AnyView?,
        title: String,
        count: Int?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                if let icon {
                    icon
                }

                Text(title)
                    .font(.system(size: 19, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? SkimStyle.text : SkimStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let count, count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)
                }
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var uniqueFeeds: [Feed] {
        var seen: Set<String> = []
        return model.feeds.filter { feed in
            let key = feed.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

private struct FeedPaneScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AddFeedSheet: View {
    @Binding var isPresented: Bool
    @State private var feedURL = ""
    @FocusState private var isFocused: Bool

    var onAdd: (String) -> Void
    var onImportOPML: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add RSS Feed")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(SkimStyle.text)
                    Text("Paste a feed URL. Skim will fetch the first articles now.")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)
                }

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(SkimStyle.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }

            TextField("https://example.com/feed.xml", text: $feedURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(SkimStyle.text)
                .focused($isFocused)
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(SkimStyle.separator, lineWidth: 1)
                }

            HStack(spacing: 14) {
                Button("Import OPML") {
                    isPresented = false
                    onImportOPML()
                }
                .buttonStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SkimStyle.accent)

                Spacer()

                Button("Add Feed") {
                    let value = feedURL
                    isPresented = false
                    onAdd(value)
                }
                .buttonStyle(.glassProminent)
                .disabled(feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .onAppear {
            isFocused = true
        }
    }
}

private struct FeedIcon: View {
    var feed: Feed

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
            Text(initials)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(width: 24, height: 24)
    }

    private var initials: String {
        let words = feed.title
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        let value = String(words).uppercased()
        return value.isEmpty ? "S" : value
    }

    private var color: Color {
        let palette: [Color] = [
            Color(red: 0.12, green: 0.32, blue: 0.98),
            Color(red: 0.68, green: 0.10, blue: 0.17),
            Color(red: 0.45, green: 0.72, blue: 0.77),
            Color(red: 0.93, green: 0.23, blue: 0.13),
            Color(red: 0.91, green: 0.76, blue: 0.19),
            Color(red: 0.52, green: 0.17, blue: 0.30)
        ]
        let index = abs(feed.id.hashValue) % palette.count
        return palette[index]
    }
}

private struct ArticleRow: View {
    var article: Article

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(article.isRead ? SkimStyle.secondary.opacity(0.35) : SkimStyle.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 31)

            VStack(alignment: .leading, spacing: 8) {
                Text(article.title)
                    .font(.system(size: 18, weight: article.isRead ? .regular : .semibold))
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
                .font(.system(size: 14, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 46)
        .padding(.vertical, 18)
        .background(SkimStyle.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SkimStyle.separator.opacity(0.75))
                .frame(height: 1)
        }
    }
}
