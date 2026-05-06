import SkimCore
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ArticleListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showImporter = false
    @State private var showFeedPicker = false
    @State private var showAddFeed = false
    @State private var showAutoGroup = false
    @State private var showSettings = false
    @State private var activeAIResult: AIResultRequest?
    @State private var activeAIChat: AIChatRequest?
    @State private var showSearch = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack {
            SkimStyle.chrome.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                if showSearch || !model.searchQuery.isEmpty {
                    searchBar
                }
                content
                bottomFilter
            }
            .contentShape(Rectangle())
            .simultaneousGesture(openFeedPickerGesture)

            if showFeedPicker {
                FeedPickerSheet(
                    isPresented: $showFeedPicker,
                    onAddFeed: {
                        dismissTextEntry()
                        showFeedPicker = false
                        showAddFeed = true
                    },
                    onImportOPML: {
                        presentImporter()
                    },
                    onAutoGroup: {
                        dismissTextEntry()
                        showFeedPicker = false
                        showAutoGroup = true
                    },
                    onSettings: {
                        dismissTextEntry()
                        showFeedPicker = false
                        showSettings = true
                    },
                    onChat: {
                        dismissTextEntry()
                        showFeedPicker = false
                        presentArticleChat()
                    },
                    onCatchUp: {
                        dismissTextEntry()
                        showFeedPicker = false
                        presentQuickCatchUp()
                    },
                    onAIInbox: {
                        dismissTextEntry()
                        showFeedPicker = false
                        presentAIInbox()
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
                    dismissTextEntry()
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
        .sheet(isPresented: $showAutoGroup) {
            AutoGroupSheet(isPresented: $showAutoGroup)
                .environmentObject(model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(SkimStyle.chrome)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(
                isPresented: $showSettings,
                onAddFeed: {
                    dismissTextEntry()
                    showSettings = false
                    showAddFeed = true
                },
                onImportOPML: {
                    dismissTextEntry()
                    showSettings = false
                    presentImporter()
                },
                onAutoGroup: {
                    dismissTextEntry()
                    showSettings = false
                    showAutoGroup = true
                },
                onRefresh: {
                    Task { await model.refreshAll() }
                }
            )
            .environmentObject(model)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(SkimStyle.chrome)
        }
        .sheet(item: $activeAIResult) { request in
            AIResultSheet(request: request)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(SkimStyle.chrome)
        }
        .sheet(item: $activeAIChat) { request in
            AIChatSheet(request: request)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(SkimStyle.chrome)
        }
        .onChange(of: model.listMode) { _, _ in
            dismissTextEntry()
            Task { await model.reloadArticles() }
        }
        .onChange(of: model.searchQuery) { _, _ in
            Task { await model.reloadArticles() }
        }
        .onChange(of: showFeedPicker) { _, isShowing in
            if isShowing {
                dismissTextEntry()
            }
        }
        .onChange(of: showAutoGroup) { _, isShowing in
            if isShowing {
                dismissTextEntry()
            }
        }
        .onChange(of: showSettings) { _, isShowing in
            if isShowing {
                dismissTextEntry()
            }
        }
        .onChange(of: activeAIResult?.id) { _, requestID in
            if requestID != nil {
                dismissTextEntry()
            }
        }
        .onChange(of: activeAIChat?.id) { _, requestID in
            if requestID != nil {
                dismissTextEntry()
            }
        }
        .alert("Skim", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func presentImporter() {
        dismissTextEntry()
        showFeedPicker = false
        showAddFeed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showImporter = true
        }
    }

    private func presentQuickCatchUp() {
        dismissTextEntry()
        let articles = model.articles
        activeAIResult = AIResultRequest(
            title: "Quick Catch-up",
            subtitle: articles.isEmpty ? "Latest articles" : "\(articles.count) visible articles"
        ) {
            let context = try await model.articlesForAIContext(preferred: articles)
            guard !context.isEmpty else {
                throw NativeAIError.unavailable("No articles are available yet. Add RSS feeds or refresh before running Quick Catch-up.")
            }
            let text = try await NativeAI.quickCatchUp(articles: context, settings: model.settings)
            return AIResultAnswer(text: text, articles: context)
        }
    }

    private func presentArticleChat() {
        dismissTextEntry()
        let articles = model.articles
        activeAIChat = AIChatRequest(
            title: "Chat with Articles",
            placeholder: articles.isEmpty ? "Ask about the latest articles." : "Ask about the currently visible articles."
        ) { question in
            let context = try await model.articlesForAIContext(preferred: articles)
            guard !context.isEmpty else {
                throw NativeAIError.unavailable("No articles are available yet. Add RSS feeds or refresh before chatting.")
            }
            let text = try await NativeAI.chat(question: question, articles: context, settings: model.settings)
            return AIChatAnswer(text: text, articles: context)
        }
    }

    private func presentAIInbox() {
        dismissTextEntry()
        let articles = model.articles
        activeAIResult = AIResultRequest(
            title: "AI Inbox",
            subtitle: articles.isEmpty ? "Smart triage across latest articles" : "Smart triage across \(articles.count) visible articles"
        ) {
            let context = try await model.articlesForAIContext(preferred: articles)
            guard !context.isEmpty else {
                throw NativeAIError.unavailable("No articles are available yet. Add RSS feeds or refresh before opening AI Inbox.")
            }
            let text = try await NativeAI.aiInbox(articles: context, settings: model.settings)
            return AIResultAnswer(text: text, articles: context)
        }
    }

    private var openFeedPickerGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard !showFeedPicker,
                      abs(value.translation.width) > abs(value.translation.height)
                else { return }

                let shouldOpen = value.translation.width > 82 || value.predictedEndTranslation.width > 145
                guard shouldOpen else { return }

                dismissTextEntry()
                withAnimation(.smooth(duration: 0.26)) {
                    showFeedPicker = true
                }
            }
    }

    private var topBar: some View {
        ZStack {
            HStack {
                Spacer()
                VStack(spacing: 1) {
                    Text(compactTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(SkimStyle.text)
                        .lineLimit(1)

                    if model.isLoading {
                        Text("Syncing...")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SkimStyle.secondary)
                    } else if model.currentUnreadCount > 0 {
                        Text("\(model.currentUnreadCount.formatted()) unread")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SkimStyle.secondary.opacity(0.78))
                    }
                }
                .frame(maxWidth: 190)
                Spacer()
            }

            HStack(alignment: .center, spacing: 18) {
                BorderlessIconButton(systemName: "line.3.horizontal", title: "Feeds", size: 20, tapSize: 42) {
                    dismissTextEntry()
                    withAnimation(.smooth(duration: 0.26)) {
                        showFeedPicker = true
                    }
                }
                Spacer()

                Menu {
                    Button("Quick Catch-up", systemImage: "bolt") {
                        presentQuickCatchUp()
                    }
                    Button("Chat with Articles", systemImage: "bubble.left") {
                        presentArticleChat()
                    }
                    Button("AI Inbox", systemImage: "tray") {
                        presentAIInbox()
                    }
                    Divider()
                    Button("Add RSS Feed", systemImage: "plus") {
                        dismissTextEntry()
                        showAddFeed = true
                    }
                    Button("Settings", systemImage: "gearshape") {
                        dismissTextEntry()
                        showSettings = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 23, weight: .bold))
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(SkimStyle.secondary)
                .accessibilityLabel("Article actions")
            }
            .padding(.horizontal, 26)
        }
        .frame(height: 56)
        .background(SkimStyle.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SkimStyle.separator.opacity(0.4))
                .frame(height: 1)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SkimStyle.secondary)
                    .font(.system(size: 15, weight: .regular))
                TextField("Search articles...", text: $model.searchQuery)
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(SkimStyle.text)
                    .font(.system(size: 16, weight: .regular))
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        dismissTextEntry()
                    }
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                        showSearch = false
                        dismissTextEntry()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(SkimStyle.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(SkimStyle.separator.opacity(0.9), lineWidth: 1)
            }
        .padding(.horizontal, 38)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .background(SkimStyle.chrome)
    }

    private func dismissTextEntry() {
        isSearchFocused = false
        dismissUIKitKeyboard()
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
                    Button("Add RSS Feed") {
                        dismissTextEntry()
                        showAddFeed = true
                    }
                        .buttonStyle(.glassProminent)

                    Button("Import OPML") {
                        dismissTextEntry()
                        showImporter = true
                    }
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
                                ArticleRow(
                                    article: article,
                                    feed: model.feeds.first(where: { $0.id == article.feedID }),
                                    visibleArticles: model.articles
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(SkimStyle.chrome)
                        }
                    } header: {
                        Text(group.label)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(SkimStyle.secondary)
                            .tracking(1.15)
                            .padding(.horizontal, 72)
                            .padding(.top, 13)
                            .padding(.bottom, 7)
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            .scrollContentBackground(.hidden)
            .background(SkimStyle.chrome)
            .refreshable {
                await model.refreshAll()
            }
            .simultaneousGesture(openFeedPickerGesture)
            .navigationDestination(for: String.self) { id in
                ArticleDetailView(articleID: id)
            }
        }
    }

    private var bottomFilter: some View {
        HStack(spacing: 30) {
            Button {
                dismissTextEntry()
                model.listMode = .unread
            } label: {
                Label("Unread", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 19, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.listMode == .unread ? SkimStyle.accent : SkimStyle.secondary)

            ForEach(ArticleListMode.allCases) { mode in
                if mode != .unread {
                    Button {
                        dismissTextEntry()
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

            Button {
                withAnimation(.smooth(duration: 0.18)) {
                    showSearch = true
                    isSearchFocused = true
                }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 19, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(showSearch || !model.searchQuery.isEmpty ? SkimStyle.accent : SkimStyle.secondary)
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(SkimStyle.chrome.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SkimStyle.separator)
                .frame(height: 1)
        }
    }

    private var compactTitle: String {
        if let selectedFeedID = model.selectedFeedID,
           let feed = model.feeds.first(where: { $0.id == selectedFeedID }) {
            return feed.title
        }

        switch model.listMode {
        case .unread:
            return "Unread"
        case .all:
            return "All"
        case .recent:
            return "Recent"
        case .starred:
            return "Starred"
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
    var onAutoGroup: () -> Void
    var onSettings: () -> Void
    var onChat: () -> Void
    var onCatchUp: () -> Void
    var onAIInbox: () -> Void
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

                    SkimWordmark(size: 50)
                        .padding(.horizontal, 38)
                        .padding(.top, 18)
                        .padding(.bottom, model.isLoading ? 14 : 46)

                    if model.isLoading {
                        FeedPaneLoadingSpinner()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.bottom, 34)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        pickerRow(
                            icon: nil,
                            title: "All Articles",
                            count: model.totalUnreadCount,
                            isSelected: model.selectedFeedID == nil && model.listMode == .all,
                            action: {
                                model.selectedFeedID = nil
                                model.listMode = .all
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

                        pickerRow(iconSystemName: "clock", title: "Recent", count: nil, isSelected: model.selectedFeedID == nil && model.listMode == .recent) {
                            model.selectedFeedID = nil
                            model.listMode = .recent
                            isPresented = false
                            Task { await model.reloadArticles() }
                        }

                        Spacer(minLength: 38)

                        pickerRow(iconSystemName: "tray", title: "AI Inbox", count: model.totalUnreadCount, isSelected: false) {
                            onAIInbox()
                        }
                    }
                    .padding(.horizontal, 38)
                    .padding(.bottom, 36)

                    HStack {
                        Text("Feeds")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(SkimStyle.text)
                        Spacer()
                        Button(action: onAutoGroup) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(SkimStyle.secondary)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 38)
                    .padding(.bottom, 16)

                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(uniqueFeeds) { feed in
                            pickerRow(
                                icon: AnyView(FeedIcon(feed: feed)),
                                title: feed.title,
                                count: model.unreadCounts[feed.id],
                                isSelected: model.selectedFeedID == feed.id
                            ) { selectFeed(feed) }
                        }
                    }
                    .padding(.horizontal, 38)
                    .padding(.bottom, 34)
                }
            }
            .coordinateSpace(name: "feedPaneScroll")
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .onPreferenceChange(FeedPaneScrollOffsetKey.self) { value in
                scrollTopOffset = value
            }
            .simultaneousGesture(pullRefreshGesture)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dismissGesture)
    }

    private var topControls: some View {
        HStack(spacing: 22) {
            BorderlessIconButton(systemName: "gearshape", title: "Settings", size: 22, tapSize: 42, action: onSettings)
            Spacer()
            BorderlessIconButton(systemName: "bubble.left", title: "Chat", size: 22, tapSize: 42, action: onChat)
            BorderlessIconButton(systemName: "bolt", title: "Quick Catch-up", size: 23, tapSize: 42, action: onCatchUp)
            BorderlessIconButton(systemName: "plus", title: "Add RSS Feed", size: 23, tapSize: 42, action: onAddFeed)
        }
        .padding(.horizontal, 26)
        .frame(height: 56)
        .background(SkimStyle.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SkimStyle.separator.opacity(0.4))
                .frame(height: 1)
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let shouldDismiss = value.translation.width < -80 || value.predictedEndTranslation.width < -140
                guard shouldDismiss else { return }
                dismissUIKitKeyboard()
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
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)
                    .frame(width: 26)
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
                    .font(.system(size: 17, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? SkimStyle.text : SkimStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let count, count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)
                }
            }
            .frame(minHeight: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectFeed(_ feed: Feed) {
        dismissUIKitKeyboard()
        model.selectedFeedID = feed.id
        if model.listMode == .recent {
            model.listMode = .unread
        }
        isPresented = false
        Task { await model.reloadArticles() }
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

private struct FeedPaneLoadingSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .tint(SkimStyle.secondary)
            .frame(width: 36, height: 36)
            .background {
                Circle()
                    .fill(SkimStyle.surface.opacity(0.45))
            }
            .overlay {
                Circle()
                    .stroke(SkimStyle.separator.opacity(0.6), lineWidth: 1)
            }
            .accessibilityLabel("Syncing")
    }
}

private struct FeedPaneScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum AutoGroupNameStyle: String, CaseIterable, Identifiable {
    case titleCase
    case camelCase
    case kebabCase
    case snakeCase

    var id: String { rawValue }

    var label: String {
        switch self {
        case .titleCase: "TitleCase"
        case .camelCase: "camelCase"
        case .kebabCase: "kebab-case"
        case .snakeCase: "snake_case"
        }
    }

    func format(_ words: [String]) -> String {
        let cleaned = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        switch self {
        case .titleCase:
            return cleaned.map(Self.titleWord).joined()
        case .camelCase:
            guard let first = cleaned.first else { return "" }
            return ([first] + cleaned.dropFirst().map(Self.titleWord)).joined()
        case .kebabCase:
            return cleaned.joined(separator: "-")
        case .snakeCase:
            return cleaned.joined(separator: "_")
        }
    }

    func formatName(_ name: String) -> String {
        format(Self.words(in: name))
    }

    private static func titleWord(_ word: String) -> String {
        switch word {
        case "ai": "AI"
        case "rss": "RSS"
        case "ml": "ML"
        default:
            word.prefix(1).uppercased() + word.dropFirst()
        }
    }

    private static func words(in value: String) -> [String] {
        let normalized = value
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)

        return normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .flatMap { word -> [String] in
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? [] : [trimmed]
            }
    }
}

private struct AutoGroupProposal: Identifiable {
    var id: String { "\(baseName)-\(feeds.map(\.id).joined(separator: ","))" }
    var baseName: String
    var feeds: [Feed]

    func displayName(style: AutoGroupNameStyle) -> String {
        style.formatName(baseName)
    }
}

private struct AutoGroupSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var nameStyle: AutoGroupNameStyle = .titleCase
    @State private var proposals: [AutoGroupProposal] = []
    @State private var isRunningAI = false
    @State private var aiMessage: String?
    @State private var didRunAI = false
    @State private var usedFallback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Auto-group feeds")
                        .font(.system(size: 27, weight: .heavy))
                        .foregroundStyle(SkimStyle.text)
                    Text("Use AI to classify feeds into folder proposals, then choose the folder naming style.")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    dismissUIKitKeyboard()
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(SkimStyle.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }

            aiStatus

            VStack(alignment: .leading, spacing: 10) {
                Text("Folder naming")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SkimStyle.secondary)
                    .textCase(.uppercase)
                    .tracking(1.1)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(AutoGroupNameStyle.allCases) { style in
                            Button {
                                withAnimation(.smooth(duration: 0.18)) {
                                    nameStyle = style
                                }
                            } label: {
                                Text(style.label)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(nameStyle == style ? SkimStyle.text : SkimStyle.secondary)
                                    .padding(.horizontal, 13)
                                    .frame(height: 36)
                                    .background(
                                        nameStyle == style ? SkimStyle.surface.opacity(0.95) : SkimStyle.surface.opacity(0.34),
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .stroke(nameStyle == style ? SkimStyle.accent.opacity(0.7) : SkimStyle.separator, lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if proposals.isEmpty {
                ContentUnavailableView(
                    "No feeds to classify",
                    systemImage: "folder.badge.plus",
                    description: Text("Add RSS feeds or import OPML first.")
                )
                .foregroundStyle(SkimStyle.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(proposals) { proposal in
                            AutoGroupProposalRow(proposal: proposal, nameStyle: nameStyle)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 12) {
                Text(usedFallback ? "Local fallback preview. Not AI." : "AI preview until native folder persistence lands.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)
                Spacer()
                Button {
                    Task { await runAI() }
                } label: {
                    HStack(spacing: 8) {
                        if isRunningAI {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(SkimStyle.text)
                        }
                        Text(aiActionTitle)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(SkimStyle.text)
                .padding(.horizontal, 15)
                .frame(height: 42)
                .background(SkimStyle.accent.opacity(isRunningAI ? 0.45 : 0.95), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                }
                .disabled(isRunningAI)
                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.glassProminent)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .task {
            guard !didRunAI else { return }
            await runAI()
        }
    }

    @ViewBuilder
    private var aiStatus: some View {
        if isRunningAI {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(SkimStyle.accent)
                Text("Asking Apple Foundation Models...")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SkimStyle.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(SkimStyle.surface.opacity(0.66), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if let aiMessage {
            VStack(alignment: .leading, spacing: 10) {
                Text(aiMessage)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(usedFallback ? SkimStyle.secondary : (proposals.isEmpty ? Color.red.opacity(0.9) : SkimStyle.secondary))
                    .fixedSize(horizontal: false, vertical: true)

                if proposals.isEmpty {
                    Button("Use local fallback preview") {
                        proposals = AutoGroupClassifier.fallbackProposals(for: model.feeds)
                        usedFallback = true
                        self.aiMessage = "Using local fallback categories. This is not AI."
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SkimStyle.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(SkimStyle.surface.opacity(0.66), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var aiActionTitle: String {
        if isRunningAI {
            return "Running"
        }
        if usedFallback {
            return "Retry AI"
        }
        return didRunAI ? "Regroup" : "Run AI"
    }

    private func runAI() async {
        if model.feeds.isEmpty {
            await model.reloadArticles()
        }

        guard !model.feeds.isEmpty else {
            didRunAI = true
            proposals = []
            aiMessage = "No feeds found yet. Add RSS feeds or import OPML first."
            return
        }

        didRunAI = true
        usedFallback = false
        isRunningAI = true
        aiMessage = nil

        do {
            let result = try await AutoGroupClassifier.aiProposals(for: model.feeds, settings: model.settings)
            proposals = result
            aiMessage = "Grouped with \(AutoGroupClassifier.providerLabel(for: model.settings.ai.provider))."
        } catch {
            proposals = AutoGroupClassifier.fallbackProposals(for: model.feeds)
            usedFallback = true
            aiMessage = proposals.isEmpty
                ? "AI grouping unavailable: \(error.localizedDescription)"
                : "AI grouping unavailable: \(error.localizedDescription)\nShowing local fallback categories."
        }

        isRunningAI = false
    }
}

private struct AutoGroupProposalRow: View {
    var proposal: AutoGroupProposal
    var nameStyle: AutoGroupNameStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text(proposal.displayName(style: nameStyle))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(SkimStyle.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Text("\(proposal.feeds.count)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SkimStyle.secondary)
            }

            Text(proposal.feeds.map(\.title).joined(separator: ", "))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(SkimStyle.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(SkimStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(SkimStyle.separator, lineWidth: 1)
        }
    }
}

private enum AutoGroupClassifier {
    static func aiProposals(for feeds: [Feed], settings: AppSettings) async throws -> [AutoGroupProposal] {
        let uniqueFeeds = deduplicate(feeds)
        guard !uniqueFeeds.isEmpty else { return [] }

        do {
            let proposals = try await requestProposals(for: uniqueFeeds, settings: settings, correctiveNote: nil)
            try validate(proposals: proposals, feedCount: uniqueFeeds.count)
            return proposals
        } catch {
            let proposals = try await requestProposals(
                for: uniqueFeeds,
                settings: settings,
                correctiveNote: """
                Your previous folder proposal was too broad or did not match the requested JSON. Try again. Split the feeds into distinct topical folders; do not put most feeds into one generic folder such as "Programming" or "Technology".
                """
            )
            try validate(proposals: proposals, feedCount: uniqueFeeds.count)
            return proposals
        }
    }

    static func providerLabel(for provider: String) -> String {
        switch provider {
        case "foundation-models": return "Apple Intelligence"
        case "claude-subscription": return "Claude Pro/Max"
        case "mlx": return "MLX"
        case "custom", "openai", "openrouter": return "custom provider"
        case "anthropic": return "Claude Pro/Max"
        default: return provider
        }
    }

    static func fallbackProposals(for feeds: [Feed]) -> [AutoGroupProposal] {
        let uniqueFeeds = deduplicate(feeds)
        let grouped = Dictionary(grouping: uniqueFeeds) { feed in
            categoryWords(for: feed)
        }

        return grouped
            .map { words, feeds in
                AutoGroupProposal(
                    baseName: words.joined(separator: " "),
                    feeds: feeds.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                )
            }
            .sorted {
                if $0.feeds.count == $1.feeds.count {
                    return $0.baseName.localizedCaseInsensitiveCompare($1.baseName) == .orderedAscending
                }
                return $0.feeds.count > $1.feeds.count
            }
    }

    fileprivate static func deduplicate(_ feeds: [Feed]) -> [Feed] {
        var seen: Set<String> = []
        return feeds.filter { feed in
            let key = feed.url.absoluteString.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func requestProposals(
        for feeds: [Feed],
        settings: AppSettings,
        correctiveNote: String?
    ) async throws -> [AutoGroupProposal] {
        let content = try await NativeAI.complete(
            settings: settings,
            instructions: systemInstructions,
            prompt: prompt(for: feeds, correctiveNote: correctiveNote),
            maxTokens: max(512, feeds.count * 4 + 160),
            jsonMode: true
        )
        return try decodeProposals(from: content, feeds: feeds)
    }

    private static var systemInstructions: String {
        """
        You group RSS feeds into 4-8 topical folders. Output JSON only.
        Each feed goes in exactly one folder. Short folder names (2-4 words).
        Refer to feeds by their numeric handle.
        """
    }

    private static func prompt(for feeds: [Feed], correctiveNote: String?) -> String {
        let correction = correctiveNote.map { "\($0)\n\n" } ?? ""

        return """
        \(correction)Feeds (handle TAB title [TAB site]):
        \(listing(for: feeds))

        Output JSON:
        {"folders":[{"name":"Tech","feeds":[0,3,7]}]}
        """
    }

    private static func listing(for feeds: [Feed]) -> String {
        feeds.enumerated()
            .map { index, feed in
                let title = feed.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let site = feed.siteURL?.host() ?? feed.url.host() ?? ""
                return "\(index)\t\(title)\t\(site)"
            }
            .joined(separator: "\n")
    }

    private static func decodeProposals(from content: String, feeds: [Feed]) throws -> [AutoGroupProposal] {
        let json = extractJSON(from: content)
        guard let data = json.data(using: .utf8) else {
            throw AutoGroupAIError.invalidResponse("AI returned unreadable JSON.")
        }

        let folders: [AutoGroupAIFolder]
        do {
            folders = try JSONDecoder().decode(AutoGroupAIResponse.self, from: data).folders
        } catch {
            do {
                folders = try JSONDecoder().decode([AutoGroupAIFolder].self, from: data)
            } catch {
                throw AutoGroupAIError.invalidResponse("Could not parse AI folder JSON.")
            }
        }

        let lookup = FeedReferenceLookup(feeds: feeds)
        var seenFeedIDs: Set<String> = []
        let proposals = folders.compactMap { folder -> AutoGroupProposal? in
            let selectedFeeds = folder.feeds.compactMap { reference -> Feed? in
                guard let feed = lookup.feed(for: reference) else { return nil }
                guard seenFeedIDs.insert(feed.id).inserted else { return nil }
                return feed
            }

            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !selectedFeeds.isEmpty else { return nil }

            return AutoGroupProposal(
                baseName: name,
                feeds: selectedFeeds.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            )
        }

        if proposals.isEmpty {
            throw AutoGroupAIError.invalidResponse("AI did not return any usable folders.")
        }

        return proposals
    }

    private static func validate(proposals: [AutoGroupProposal], feedCount: Int) throws {
        let expectedMinimum = minimumFolderCount(for: feedCount)
        guard proposals.count >= expectedMinimum else {
            throw AutoGroupAIError.invalidResponse("AI returned too few folders.")
        }

        let largestGroup = proposals.map(\.feeds.count).max() ?? 0
        if proposals.count < 4, feedCount >= 8, Double(largestGroup) / Double(max(feedCount, 1)) > 0.6 {
            throw AutoGroupAIError.invalidResponse("AI collapsed too many feeds into one broad folder.")
        }
    }

    private static func minimumFolderCount(for feedCount: Int) -> Int {
        switch feedCount {
        case 0...3:
            return 1
        case 4...7:
            return 2
        default:
            return 4
        }
    }

    private static func extractJSON(from content: String) -> String {
        let withoutFence = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = withoutFence.firstIndex(of: "{"),
           let end = withoutFence.lastIndex(of: "}"),
           start <= end {
            return String(withoutFence[start...end])
        }

        if let start = withoutFence.firstIndex(of: "["),
           let end = withoutFence.lastIndex(of: "]"),
           start <= end {
            return String(withoutFence[start...end])
        }

        return withoutFence
    }

    private static func categoryWords(for feed: Feed) -> [String] {
        let text = [
            feed.title,
            feed.url.host() ?? "",
            feed.siteURL?.host() ?? ""
        ]
        .joined(separator: " ")
        .lowercased()

        if containsAny(text, ["ai", "llm", "openai", "anthropic", "machine learning", "ml", "neural", "model"]) {
            return ["artificial", "intelligence"]
        }
        if containsAny(text, ["distributed", "systems", "kubernetes", "database", "cache", "network", "sre", "infra"]) {
            return ["distributed", "systems"]
        }
        if containsAny(text, ["security", "privacy", "vulnerability", "crypto", "cryptography", "malware", "exploit"]) {
            return ["security"]
        }
        if containsAny(text, ["finance", "economics", "market", "money", "banking", "investing"]) {
            return ["finance", "economics"]
        }
        if containsAny(text, ["software", "programming", "code", "developer", "engineering", "swift", "rust", "typescript"]) {
            return ["software", "engineering"]
        }
        if containsAny(text, ["startup", "business", "company", "product", "venture"]) {
            return ["business"]
        }

        return fallbackWords(for: feed)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func fallbackWords(for feed: Feed) -> [String] {
        let stopWords: Set<String> = ["the", "and", "for", "blog", "rss", "feed", "www", "com", "org", "net", "io"]
        let titleWords = feed.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { $0.count > 2 && !stopWords.contains($0) }

        if let first = titleWords.first {
            return [first]
        }

        let hostWords = (feed.url.host() ?? "feeds")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && !stopWords.contains($0) }

        return Array(hostWords.prefix(2)).isEmpty ? ["feeds"] : Array(hostWords.prefix(2))
    }
}

private enum AutoGroupAIError: LocalizedError {
    case unavailable(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidResponse(let message):
            message
        }
    }
}

private struct AutoGroupAIResponse: Decodable {
    var folders: [AutoGroupAIFolder]

    private enum CodingKeys: String, CodingKey {
        case folders
        case groups
        case categories
        case topics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let folders = try? container.decode([AutoGroupAIFolder].self, forKey: .folders) {
            self.folders = folders
        } else if let groups = try? container.decode([AutoGroupAIFolder].self, forKey: .groups) {
            self.folders = groups
        } else if let categories = try? container.decode([AutoGroupAIFolder].self, forKey: .categories) {
            self.folders = categories
        } else if let topics = try? container.decode([AutoGroupAIFolder].self, forKey: .topics) {
            self.folders = topics
        } else {
            self.folders = []
        }
    }
}

private struct AutoGroupAIFolder: Decodable {
    var name: String
    var feeds: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case title
        case folder
        case category
        case feeds
        case feedIDs = "feed_ids"
        case feedIds
        case feedIndices = "feed_indices"
        case feedIndexes = "feed_indexes"
        case feedHandles = "feed_handles"
        case ids
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (
            (try? container.decode(String.self, forKey: .name)) ??
            (try? container.decode(String.self, forKey: .title)) ??
            (try? container.decode(String.self, forKey: .folder)) ??
            (try? container.decode(String.self, forKey: .category)) ??
            ""
        )

        feeds = Self.decodeFeedReferences(from: container)
    }

    private static func decodeFeedReferences(from container: KeyedDecodingContainer<CodingKeys>) -> [String] {
        let keys: [CodingKeys] = [
            .feeds,
            .feedIDs,
            .feedIds,
            .feedIndices,
            .feedIndexes,
            .feedHandles,
            .ids,
            .items
        ]

        for key in keys where container.contains(key) {
            if let values = try? container.decode([AutoGroupFeedReference].self, forKey: key) {
                return values.compactMap(\.value)
            }
        }
        return []
    }
}

private struct AutoGroupFeedReference: Decodable {
    var value: String?

    init(from decoder: Decoder) throws {
        let single = try? decoder.singleValueContainer()
        if let index = try? single?.decode(Int.self) {
            value = String(index)
        } else if let text = try? single?.decode(String.self) {
            value = text
        } else if let object = try? AutoGroupFeedReferenceObject(from: decoder) {
            value = object.value
        } else {
            value = nil
        }
    }
}

private struct AutoGroupFeedReferenceObject: Decodable {
    var value: String?

    enum CodingKeys: String, CodingKey {
        case index
        case handle
        case id
        case title
        case feed
        case name
        case url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let index = try? container.decode(Int.self, forKey: .index) {
            value = String(index)
        } else if let handle = try? container.decode(Int.self, forKey: .handle) {
            value = String(handle)
        } else if let id = try? container.decode(String.self, forKey: .id) {
            value = id
        } else if let title = try? container.decode(String.self, forKey: .title) {
            value = title
        } else if let feed = try? container.decode(String.self, forKey: .feed) {
            value = feed
        } else if let name = try? container.decode(String.self, forKey: .name) {
            value = name
        } else if let url = try? container.decode(String.self, forKey: .url) {
            value = url
        } else {
            value = nil
        }
    }
}

private struct FeedReferenceLookup {
    private let feeds: [Feed]
    private let byID: [String: Feed]
    private let byTitle: [String: Feed]
    private let byURL: [String: Feed]

    init(feeds: [Feed]) {
        self.feeds = feeds
        byID = Dictionary(feeds.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        byTitle = Dictionary(feeds.map { ($0.title.normalizedFeedReference, $0) }, uniquingKeysWith: { first, _ in first })
        byURL = Dictionary(feeds.flatMap { feed in
            [
                (feed.url.absoluteString.lowercased(), feed),
                (feed.url.host()?.lowercased() ?? "", feed),
                (feed.siteURL?.absoluteString.lowercased() ?? "", feed),
                (feed.siteURL?.host()?.lowercased() ?? "", feed)
            ].filter { !$0.0.isEmpty }
        }, uniquingKeysWith: { first, _ in first })
    }

    func feed(for reference: String) -> Feed? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = Int(trimmed), feeds.indices.contains(index) {
            return feeds[index]
        }
        let lower = trimmed.lowercased()
        if let feed = byID[lower] ?? byURL[lower] {
            return feed
        }
        return byTitle[trimmed.normalizedFeedReference]
    }
}

private extension String {
    var normalizedFeedReference: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum FoundationModelFeedOrganizer {
    static func proposals(for feeds: [Feed]) async throws -> [AutoGroupProposal] {
        guard !feeds.isEmpty else { return [] }

        let model = SystemLanguageModel(useCase: .contentTagging)
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw AutoGroupAIError.unavailable("Apple Intelligence is not available: \(reasonDescription(reason)).")
        }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You group RSS feeds into topical folders. Output JSON only.
            Each feed must appear in exactly one folder. Use 4-8 folders when possible.
            Use short folder names of 2-4 words. Refer to feeds only by numeric handle.
            """
        )

        let maxTokens = max(512, feeds.count * 4 + 160)
        let response = try await session.respond(
            to: prompt(for: feeds),
            options: GenerationOptions(
                sampling: .greedy,
                temperature: 0.1,
                maximumResponseTokens: maxTokens
            )
        )

        return try decodeProposals(from: response.content, feeds: feeds)
    }

    private static func prompt(for feeds: [Feed]) -> String {
        """
        Feeds, one per line as handle TAB title TAB site:
        \(listing(for: feeds))

        Return exactly this JSON shape:
        {"folders":[{"name":"Distributed Systems","feeds":[0,3,7]}]}
        """
    }

    private static func listing(for feeds: [Feed]) -> String {
        feeds.enumerated()
            .map { index, feed in
                let title = feed.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let site = feed.siteURL?.host() ?? feed.url.host() ?? ""
                return "\(index)\t\(title)\t\(site)"
            }
            .joined(separator: "\n")
    }

    private static func decodeProposals(from content: String, feeds: [Feed]) throws -> [AutoGroupProposal] {
        let json = extractJSONObject(from: content)
        guard let data = json.data(using: .utf8) else {
            throw AutoGroupAIError.invalidResponse("AI returned unreadable JSON.")
        }

        let decoded: AutoGroupAIResponse
        do {
            decoded = try JSONDecoder().decode(AutoGroupAIResponse.self, from: data)
        } catch {
            throw AutoGroupAIError.invalidResponse("Could not parse AI folder JSON.")
        }

        let lookup = FeedReferenceLookup(feeds: feeds)
        var seenFeedIDs: Set<String> = []
        let proposals = decoded.folders.compactMap { folder -> AutoGroupProposal? in
            let selectedFeeds = folder.feeds.compactMap { reference -> Feed? in
                guard let feed = lookup.feed(for: reference) else { return nil }
                guard seenFeedIDs.insert(feed.id).inserted else { return nil }
                return feed
            }

            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !selectedFeeds.isEmpty else { return nil }

            return AutoGroupProposal(
                baseName: name,
                feeds: selectedFeeds.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            )
        }

        if proposals.isEmpty {
            throw AutoGroupAIError.invalidResponse("AI did not return any usable folders.")
        }

        return proposals
    }

    private static func extractJSONObject(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else {
            return trimmed
        }
        return String(trimmed[start...end])
    }

    private static func reasonDescription(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "this device is not eligible"
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is not enabled"
        case .modelNotReady:
            "the language model is not ready"
        @unknown default:
            "unknown reason"
        }
    }
}
#endif

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
                    close()
                    onImportOPML()
                }
                .buttonStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SkimStyle.accent)

                Spacer()

                Button("Add Feed") {
                    let value = feedURL
                    close()
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
        .onDisappear {
            isFocused = false
            dismissUIKitKeyboard()
        }
    }

    private func close() {
        isFocused = false
        dismissUIKitKeyboard()
        isPresented = false
    }
}

private struct FeedIcon: View {
    var feed: Feed
    var size: CGFloat = 24

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
        .frame(width: size, height: size)
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
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    var article: Article
    var feed: Feed?
    var visibleArticles: [Article]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if let feed {
                    FeedIcon(feed: feed, size: 30)
                } else {
                    ArticleSourceIcon(article: article)
                }

                if !article.isRead {
                    Circle()
                        .fill(SkimStyle.accent)
                        .frame(width: 6, height: 6)
                        .offset(x: -8, y: 11)
                }
            }
            .padding(.top, 20)
            .frame(width: 34, alignment: .center)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(sourceLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(SkimStyle.secondary.opacity(article.isRead ? 0.58 : 0.78))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(timestamp)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SkimStyle.text.opacity(article.isRead ? 0.46 : 0.78))
                        .lineLimit(1)
                }

                Text(article.title)
                    .font(.system(size: 17, weight: article.isRead ? .regular : .semibold))
                    .foregroundStyle(article.isRead ? SkimStyle.secondary : SkimStyle.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 7) {
                    if let secondaryLine {
                        Text(secondaryLine)
                            .foregroundStyle(SkimStyle.secondary.opacity(article.isRead ? 0.54 : 0.76))
                            .lineLimit(1)
                    }
                    if article.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.91, green: 0.76, blue: 0.19))
                    }
                }
                .font(.system(size: 15, weight: .regular))
            }

            Spacer(minLength: 4)

            if let imageURL = article.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Color.clear
                    case .empty:
                        SkimStyle.surface
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(width: 76, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .opacity(article.isRead ? 0.62 : 1)
                .padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 46)
        .padding(.trailing, 28)
        .padding(.vertical, 11)
        .background(SkimStyle.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SkimStyle.separator.opacity(0.5))
                .frame(height: 1)
                .padding(.leading, 92)
        }
        .contextMenu {
            Button(article.isRead ? "Mark as Unread" : "Mark as Read", systemImage: article.isRead ? "circle" : "checkmark.circle") {
                Task { await model.setRead(article, isRead: !article.isRead) }
            }

            Button(article.isStarred ? "Unfavorite" : "Mark Favorite", systemImage: article.isStarred ? "star.slash" : "star") {
                Task { await model.toggleStar(article) }
            }

            Divider()

            Button("Mark All Above Read", systemImage: "arrow.up.to.line") {
                Task { await model.setRead(articlesAbove, isRead: true) }
            }
            .disabled(articlesAbove.isEmpty)

            Button("Mark All Above Unread", systemImage: "arrow.up.to.line") {
                Task { await model.setRead(articlesAbove, isRead: false) }
            }
            .disabled(articlesAbove.isEmpty)

            Button("Mark All Below Read", systemImage: "arrow.down.to.line") {
                Task { await model.setRead(articlesBelow, isRead: true) }
            }
            .disabled(articlesBelow.isEmpty)

            Button("Mark All Below Unread", systemImage: "arrow.down.to.line") {
                Task { await model.setRead(articlesBelow, isRead: false) }
            }
            .disabled(articlesBelow.isEmpty)

            if let url = article.url {
                Divider()
                Button("Open Link", systemImage: "safari") {
                    openURL(url)
                }
            }
        }
    }

    private var currentIndex: Int? {
        visibleArticles.firstIndex { $0.id == article.id }
    }

    private var articlesAbove: [Article] {
        guard let currentIndex else { return [] }
        return Array(visibleArticles[..<currentIndex])
    }

    private var articlesBelow: [Article] {
        guard let currentIndex, currentIndex + 1 < visibleArticles.count else { return [] }
        return Array(visibleArticles[(currentIndex + 1)...])
    }

    private var sourceLabel: String {
        article.feedTitle.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var secondaryLine: String? {
        if article.feedTitle.localizedCaseInsensitiveContains("hacker news") {
            return "Comments"
        }

        if let author = article.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            return author
        }

        return article.url?.host(percentEncoded: false)?
            .replacingOccurrences(of: "www.", with: "")
    }

    private var timestamp: String {
        let date = article.publishedAt ?? article.fetchedAt
        if Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }

        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct ArticleSourceIcon: View {
    var article: Article

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
            Text(initials)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(width: 30, height: 30)
    }

    private var initials: String {
        let words = article.feedTitle
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
        let index = abs(article.feedID.hashValue) % palette.count
        return palette[index]
    }
}

private func dismissUIKitKeyboard() {
#if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
}
