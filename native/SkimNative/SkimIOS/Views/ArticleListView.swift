import OSLog
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
    /// Today is showing in place of the article list, as a bottom-bar tab.
    @State private var showToday = false
    @State private var showTodaySettings = false
    @State private var showBottomBarEditor = false
    @AppStorage(BottomBarItem.storageKey) private var bottomBarStorage = BottomBarItem.defaultStorage
    @State private var showImporter = false
    @State private var showFeedPicker = false
    @State private var showAddFeed = false
    @State private var showAutoGroup = false
    @State private var showSettings = false
    @State private var activeAIResult: AIResultRequest?
    @State private var activeAIChat: AIChatRequest?
    @State private var chatMessagesBySession: [String: [AIChatMessage]] = [:]
    @State private var activeChatInitialMessage: String? = nil
    @State private var activeSummaryConfiguration: Article?
    @State private var showSearch = false
    @FocusState private var isSearchFocused: Bool
    /// Shown when user triggers an AI feature before accepting the disclaimer.
    @State private var showAIDisclaimerGate = false
    @State private var pendingAIAction: (() -> Void)?

    var body: some View {
        ZStack {
            SkimStyle.chrome.ignoresSafeArea(.all, edges: [.top, .horizontal])

            VStack(spacing: 0) {
                topBar
                if isSearchActive && !showToday {
                    searchBar
                }
                if showToday {
                    TodayEditionView(
                        showSettings: $showTodaySettings,
                        onBrowseArticles: { showToday = false },
                        onAsk: { request in gatedAI { dismissTextEntry(); activeAIChat = request } }
                    )
                    .environmentObject(model)
                } else {
                    content
                }
                bottomBar
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
                    onToday: {
                        dismissTextEntry()
                        showFeedPicker = false
                        openToday()
                    },
                    onAIInbox: {
                        dismissTextEntry()
                        showFeedPicker = false
                        presentAIInbox()
                    },
                    onShowList: {
                        showToday = false
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
        .sheet(isPresented: $showBottomBarEditor) {
            BottomBarEditor(storage: $bottomBarStorage)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(SkimStyle.chrome)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.xml, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.importOPML(url: url) }
        }
        .navigationDestination(isPresented: $showAddFeed) {
            DiscoverView(onImportOPML: {
                presentImporter()
            })
            .environmentObject(model)
        }
        .sheet(isPresented: $showAutoGroup) {
            AutoGroupSheet(isPresented: $showAutoGroup)
                .environmentObject(model)
                // Full height only: at .medium the proposals list collapses to nothing.
                .presentationDetents([.large])
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
        .sheet(item: $activeSummaryConfiguration) { article in
            SummaryConfigurationSheet(article: article, defaults: model.settings.ai) { summarySettings in
                runSummary(article: article, summarySettings: summarySettings)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(SkimStyle.chrome)
        }
        .sheet(item: $activeAIChat) { request in
            AIChatSheet(
                request: request,
                messages: chatMessagesBinding(for: request.sessionKey),
                initialAssistantMessage: activeChatInitialMessage
            )
                .environmentObject(model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(SkimStyle.chrome)
                .onDisappear { activeChatInitialMessage = nil }
        }
        .fullScreenCover(isPresented: $showAIDisclaimerGate) {
            AIBootDisclaimerView { dontShowAgain in
                AIBootDisclaimerView.markAccepted(dontShowAgain: dontShowAgain)
                showAIDisclaimerGate = false
                pendingAIAction?()
                pendingAIAction = nil
            }
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
                Task { await model.clearReadLingerAndReloadArticles() }
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
        .onChange(of: activeSummaryConfiguration?.id) { _, articleID in
            if articleID != nil {
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

    /// Executes `action` immediately if the AI disclaimer has been accepted;
    /// otherwise presents the boot disclaimer and enqueues `action` to run after acceptance.
    private func gatedAI(_ action: @escaping () -> Void) {
        if AIBootDisclaimerView.isAccepted {
            action()
        } else {
            pendingAIAction = action
            showAIDisclaimerGate = true
        }
    }

    private func chatMessagesBinding(for sessionKey: String) -> Binding<[AIChatMessage]> {
        Binding(
            get: { chatMessagesBySession[sessionKey] ?? [] },
            set: { chatMessagesBySession[sessionKey] = $0 }
        )
    }

    /// Entry point for the article-row context menu "Summarize" action.
    /// Mirrors the reader-page flow in `ArticleDetailView`: disclaimer gate,
    /// then the summary configuration sheet, then the streaming result sheet.
    private func presentSummary(for article: Article) {
        gatedAI {
            dismissTextEntry()
            activeSummaryConfiguration = article
        }
    }

    private func runSummary(article: Article, summarySettings: AISettings) {
        var settings = model.settings
        settings.ai = summarySettings
        activeSummaryConfiguration = nil
        // The list shares reader evidence: cached extraction, feed text, and a bounded fetch.
        let snapshot = WebViewSnapshot()

        Task {
            await model.saveSettings(settings)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            activeAIResult = AIResultRequest(
                title: "AI Summary",
                subtitle: WebAIContext.subtitle(base: article, preferWeb: false, snapshot: snapshot),
                statusLabel: NativeAI.loadingStatusLabel(for: settings.ai),
                action: {
                    let contextArticle = try await WebAIContext.article(base: article, preferWeb: false, snapshot: snapshot, store: model.store)
                    let text = try await NativeAI.summarize(article: contextArticle, settings: settings)
                    return AIResultAnswer(text: text, articles: [contextArticle])
                },
                streamAction: { onToken in
                    let contextArticle = try await WebAIContext.article(base: article, preferWeb: false, snapshot: snapshot, store: model.store)
                    let text = try await NativeAI.summarizeStreaming(
                        article: contextArticle, settings: settings, onToken: onToken)
                    return AIResultAnswer(text: text, articles: [contextArticle])
                },
                clearAction: {
                    NativeAI.clearSummaryCache(
                        articleID: WebAIContext.articleID(base: article, preferWeb: false, snapshot: snapshot),
                        ai: settings.ai
                    )
                },
                continueInChat: { summaryText in
                    activeAIResult = nil
                    activeChatInitialMessage = summaryText
                    activeAIChat = AIChatRequest(
                        sessionKey: WebAIContext.articleID(base: article, preferWeb: false, snapshot: snapshot),
                        title: "Chat with Article",
                        placeholder: WebAIContext.subtitle(base: article, preferWeb: false, snapshot: snapshot),
                        generatedSummaryContext: summaryText
                    ) { conversation in
                        // Asking about an article reads it; it stays in the
                        // unread list until the reader moves on, as when opened.
                        if !article.isRead {
                            await model.setRead(article, isRead: true, keepVisibleInUnreadList: true)
                        }
                        let contextArticle = try await WebAIContext.article(base: article, preferWeb: false, snapshot: snapshot, store: model.store)
                        let (text, citations) = try await NativeAI.chat(conversation: conversation, article: contextArticle, settings: model.settings)
                        return AIChatAnswer(text: text, articles: [contextArticle], webCitations: citations)
                    }
                }
            )
        }
    }

    private func presentArticleChat() {
        gatedAI {
            dismissTextEntry()
            let scope = model.captureLibraryChatScope()
            activeAIChat = AIChatRequest(
                sessionKey: scope.sessionKey,
                title: "Chat with Articles",
                placeholder: "Find or ask about articles in this view.",
                suggestedPrompts: LibraryChatPolicy.starterPrompts
            ) { conversation in
                let context = try await model.articlesForLibraryChat(scope: scope, conversation: conversation)
                guard !context.isEmpty else {
                    let briefing = LibraryChatPolicy.retrievalTopic(query: conversation.latestQuestion,
                        priorUserQueries: conversation.priorTurns.filter { $0.role == .user }.map(\.text)).allowRecentFallback
                    return AIChatAnswer(text: briefing
                        ? "There are no articles in this view to catch up on yet."
                        : "No matching articles found in this view. Try another title, topic, source, or URL.", articles: [])
                }
                let (text, citations) = try await NativeAI.chat(conversation: conversation, articles: context, settings: model.settings)
                return AIChatAnswer(text: text, articles: context, webCitations: citations,
                                    articleHandles: NativeAI.libraryChatHandles(articles: context, conversation: conversation))
            }
        }
    }

    /// Sort the current list For you (what the AI Inbox used to be). Starred
    /// and Recent are not ranked lists, so they switch to Unread.
    private func presentAIInbox() {
        gatedAI {
            dismissTextEntry()
            showToday = false
            if !model.canSortForYou {
                model.searchQuery = ""
                if model.listMode != .unread && model.listMode != .all { model.listMode = .unread }
                Task { await model.reloadArticles() }
            }
            model.listSort = .forYou
        }
    }

    /// Smart sorting on is the For you ranking; off is the raw list, newest first.
    private var smartSortingBinding: Binding<Bool> {
        Binding(
            get: { model.isForYou },
            set: { on in
                if on { presentAIInbox() } else { model.listSort = .newest }
            }
        )
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
            // On Today the title sits between the clusters (the way a
            // navigation bar does when its buttons leave no room to centre it
            // on the screen); elsewhere it is centred on the screen.
            if !showToday {
                HStack {
                    Spacer()
                    topBarTitle.frame(maxWidth: model.canSortForYou ? 160 : 190)
                    Spacer()
                }
            }

            HStack(alignment: .center, spacing: showToday ? 12 : 18) {
                BorderlessIconButton(systemName: SkimIcon.feeds, title: "Feeds", size: 20, tapSize: 42) {
                    dismissTextEntry()
                    withAnimation(.smooth(duration: 0.26)) {
                        showFeedPicker = true
                    }
                }

                if showToday {
                    topBarTitle.frame(maxWidth: .infinity)
                    BorderlessIconButton(systemName: SkimIcon.settings, title: "Today settings", size: 20, tapSize: 42) {
                        showTodaySettings = true
                    }
                } else {
                    Spacer()
                    if model.canSortForYou {
                        BorderlessIconButton(systemName: "sparkles",
                                             title: "Smart sorting",
                                             isActive: model.isForYou,
                                             size: 17, tapSize: 36) {
                            dismissTextEntry()
                            smartSortingBinding.wrappedValue.toggle()
                        }
                        .opacity(model.isForYou ? 1 : 0.55)
                        .accessibilityValue(model.isForYou ? "On" : "Off")
                        .accessibilityHint("Ranks unread articles for you when on; newest first when off")
                    }
                }

                Menu {
                    if showToday, let items = model.todayEdition?.items, !items.isEmpty {
                        Button("Ask about Today", systemImage: SkimIcon.chat) {
                            gatedAI {
                                dismissTextEntry()
                                activeAIChat = TodayChat.page(items, model: model)
                            }
                        }
                        Divider()
                    }
                    Button("Chat with Articles", systemImage: SkimIcon.chat) {
                        presentArticleChat()
                    }
                    if !showToday && model.canSortForYou {
                        Toggle(isOn: smartSortingBinding) {
                            Label("Smart Sorting", systemImage: "sparkles")
                        }
                    } else {
                        Button("For you", systemImage: SkimIcon.aiInbox) {
                            presentAIInbox()
                        }
                    }
                    Divider()
                    Button("Discover Feeds", systemImage: SkimIcon.addFeed) {
                        dismissTextEntry()
                        showAddFeed = true
                    }
                    Button("Customize Bottom Bar", systemImage: "slider.horizontal.3") {
                        dismissTextEntry()
                        showBottomBarEditor = true
                    }
                    Button("Settings", systemImage: SkimIcon.settings) {
                        dismissTextEntry()
                        showSettings = true
                    }
                } label: {
                    Image(systemName: SkimIcon.more)
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

    /// The list title with its count underneath. On Today the title is the
    /// paper's nameplate, and the only header: the page below it opens with
    /// its dateline, not a second "Today".
    private var topBarTitle: some View {
        VStack(spacing: 1) {
            Text(compactTitle)
                .font(showToday
                      ? .system(size: 26, weight: .bold, design: .serif)
                      : .system(size: 17, weight: .bold))
                .foregroundStyle(SkimStyle.text)
                .lineLimit(1)

            if showToday {
                if model.isLoading {
                    Text("Checking feeds...")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SkimStyle.secondary)
                }
            } else if model.isLoading {
                Text("Syncing...")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SkimStyle.secondary)
            } else if isSearchActive {
                if !model.articles.isEmpty {
                    Text("\(model.articles.count.formatted()) results")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SkimStyle.secondary.opacity(0.78))
                }
            } else if model.listMode == .starred && model.selectedFeedID == nil && model.selectedFolderID == nil {
                if !model.articles.isEmpty {
                    Text("\(model.articles.count.formatted()) starred")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SkimStyle.secondary.opacity(0.78))
                }
            } else if model.currentUnreadCount > 0 {
                Text("\(model.currentUnreadCount.formatted()) unread")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SkimStyle.secondary.opacity(0.78))
            }
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
                    Button("Discover Feeds") {
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
        } else if model.isForYou {
            AIInboxView()
                .environmentObject(model)
                // A new feed or folder is a new ranking.
                .id("\(model.selectedFeedID ?? "")|\(model.selectedFolderID ?? "")")
                .simultaneousGesture(openFeedPickerGesture)
        } else {
            List {
                ForEach(groupedArticles, id: \.label) { group in
                    Section {
                        ForEach(group.articles) { article in
                            NavigationLink(value: article.id) {
                                ArticleRow(
                                    article: article,
                                    feed: model.feeds.first(where: { $0.id == article.feedID }),
                                    visibleArticles: model.articles,
                                    onSummarize: { presentSummary(for: $0) }
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.leading, 72)
                            .padding(.trailing, 18)
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

    private var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    private var bottomBarItems: [BottomBarItem] {
        BottomBarItem.decode(bottomBarStorage)
    }

    /// The bottom bar: the views Giulio picked (Customize Bottom Bar), each an
    /// icon over its name. List filters and Today swap the main view in place;
    /// AI Inbox opens its page; "Catch me up" is a button on Today itself.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach(bottomBarItems) { item in
                Button {
                    selectBottomBarItem(item)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 18, weight: .medium))
                            .frame(height: 22)
                        Text(item.title)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isBottomBarItemSelected(item) ? SkimStyle.accent : SkimStyle.secondary)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isBottomBarItemSelected(item) ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        // On phones with a home indicator, sit the items lower: more room
        // under the separator, and reach part-way into the bottom inset so the
        // gap under the labels isn't bigger than the one above the icons.
        .padding(.top, bottomSafeAreaInset > 0 ? 10 : 0)
        .padding(.bottom, bottomSafeAreaInset > 0 ? -12 : 0)
        .frame(maxWidth: .infinity)
        .background(SkimStyle.chrome.opacity(0.96).ignoresSafeArea(.all, edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SkimStyle.separator)
                .frame(height: 1)
        }
        .contextMenu {
            Button("Customize Bottom Bar", systemImage: "slider.horizontal.3") {
                showBottomBarEditor = true
            }
        }
    }

    private func isBottomBarItemSelected(_ item: BottomBarItem) -> Bool {
        switch item {
        case .today:
            return showToday
        case .search:
            return isSearchActive && !showToday
        case .aiInbox:
            return !showToday && model.isForYou
        case .unread, .all, .starred, .recent:
            // Smart sorting keeps the list's tab lit, unless a For you tab is there to show it.
            let forYouTabShown = model.isForYou && bottomBarItems.contains(.aiInbox)
            return !showToday && !isSearchActive && !forYouTabShown && model.selectedFolderID == nil && model.listMode == item.listMode
        }
    }

    private func selectBottomBarItem(_ item: BottomBarItem) {
        dismissTextEntry()
        switch item {
        case .today:
            openToday()
        case .search:
            showToday = false
            withAnimation(.smooth(duration: 0.18)) {
                showSearch = true
                isSearchFocused = true
            }
        case .aiInbox:
            presentAIInbox()
        case .unread, .all, .starred, .recent:
            showToday = false
            model.listSort = .newest
            model.selectedFolderID = nil
            if let mode = item.listMode {
                model.listMode = mode
            }
        }
    }

    private func openToday() {
        showSearch = false
        model.searchQuery = ""
        showToday = true
    }

    /// The magnifier-tab search box is showing and/or has a query — global search mode.
    private var isSearchActive: Bool {
        showSearch || !model.searchQuery.isEmpty
    }

    private var compactTitle: String {
        if showToday {
            return "Today"
        }
        if isSearchActive {
            return "Search"
        }
        if let selectedFeedID = model.selectedFeedID,
           let feed = model.feeds.first(where: { $0.id == selectedFeedID }) {
            return feed.title
        }
        if let selectedFolderID = model.selectedFolderID,
           let folder = model.folders.first(where: { $0.id == selectedFolderID }) {
            return folder.name
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
    @State private var newFolderKind: NewFolderKind?
    @State private var newFolderName = ""
    @State private var smartFolderDraft: FeedFolder?
    var onAddFeed: () -> Void
    var onImportOPML: () -> Void
    var onAutoGroup: () -> Void
    var onSettings: () -> Void
    var onChat: () -> Void
    var onToday: () -> Void
    var onAIInbox: () -> Void
    /// A feed, folder or library view was picked: leave Today for the list.
    var onShowList: () -> Void
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

                    if model.isLoading {
                        FeedPaneLoadingSpinner()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 18)
                            .padding(.bottom, 18)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        pickerRow(iconSystemName: SkimIcon.today, title: "Today", count: nil, isSelected: false, action: onToday)

                        pickerRow(iconSystemName: SkimIcon.allArticles, title: "All Articles", count: model.totalUnreadCount, isSelected: model.selectedFeedID == nil && model.selectedFolderID == nil && model.listMode == .all) {
                            model.selectedFeedID = nil
                            model.selectedFolderID = nil
                            model.listMode = .all
                            onShowList()
                            isPresented = false
                            Task { await model.reloadArticles() }
                        }

                        pickerRow(iconSystemName: SkimIcon.starred, title: "Starred", count: nil, isSelected: model.listMode == .starred && model.selectedFolderID == nil) {
                            model.selectedFeedID = nil
                            model.selectedFolderID = nil
                            model.listMode = .starred
                            onShowList()
                            isPresented = false
                            Task { await model.reloadArticles() }
                        }

                        pickerRow(iconSystemName: SkimIcon.recent, title: "Recent", count: nil, isSelected: model.selectedFeedID == nil && model.selectedFolderID == nil && model.listMode == .recent) {
                            model.selectedFeedID = nil
                            model.selectedFolderID = nil
                            model.listMode = .recent
                            onShowList()
                            isPresented = false
                            Task { await model.reloadArticles() }
                        }

                        pickerRow(iconSystemName: SkimIcon.aiInbox, title: "For you", count: model.totalUnreadCount, isSelected: model.selectedFeedID == nil && model.selectedFolderID == nil && model.isForYou) {
                            model.selectedFeedID = nil
                            model.selectedFolderID = nil
                            onAIInbox()
                            isPresented = false
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                    HStack {
                        Text("Feeds")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(SkimStyle.secondary)
                            .textCase(.uppercase)
                            .tracking(1.1)
                        Spacer()
                        // One button for everything folder-related, as on desktop.
                        Menu {
                            Button("New Folder", systemImage: "folder") {
                                newFolderName = ""
                                newFolderKind = .regular
                            }
                            Button("New Smart Folder…", systemImage: "folder.badge.gearshape") {
                                newFolderName = ""
                                newFolderKind = .smart
                            }
                            Divider()
                            // Short enough to stay on one line in the native menu.
                            Button("Organize with AI", systemImage: "sparkles", action: onAutoGroup)
                        } label: {
                            AutoGroupIcon(size: 16)
                                .foregroundStyle(SkimStyle.secondary)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Folders")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.folders.isEmpty {
                            // No folders — flat feed list (legacy behaviour)
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(uniqueFeeds) { feed in
                                    pickerRow(
                                        icon: AnyView(FeedIcon(feed: feed)),
                                        title: feed.title,
                                        count: model.unreadCounts[feed.id],
                                        isSelected: model.selectedFeedID == feed.id
                                    ) { selectFeed(feed) }
                                    .contextMenu { MoveToFolderMenu(model: model, feed: feed) }
                                }
                            }
                            .padding(.bottom, 34)
                        } else {
                            // Grouped by folder
                            ForEach(model.folders) { folder in
                                let folderFeeds = model.feedsInFolder(id: folder.id)
                                // An empty regular folder still shows, so a new one is there to move feeds into.
                                if !folderFeeds.isEmpty || !folder.isSmart {
                                    FolderSection(
                                        folder: folder,
                                        feeds: folderFeeds,
                                        selectedFeedID: model.selectedFeedID,
                                        selectedFolderID: model.selectedFolderID,
                                        unreadCounts: model.unreadCounts,
                                        onSelect: { selectFeed($0) },
                                        onSelectFolder: { selectFolder($0) }
                                    )
                                    .padding(.bottom, 4)
                                }
                            }

                            let unfoldered = uniqueFeeds.filter { $0.folderID == nil }
                            if !unfoldered.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Uncategorized")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(SkimStyle.secondary)
                                        .textCase(.uppercase)
                                        .tracking(1.1)
                                        .padding(.horizontal, 20)
                                        .padding(.top, 14)
                                        .padding(.bottom, 2)

                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(unfoldered) { feed in
                                            pickerRow(
                                                icon: AnyView(FeedIcon(feed: feed)),
                                                title: feed.title,
                                                count: model.unreadCounts[feed.id],
                                                isSelected: model.selectedFeedID == feed.id
                                            ) { selectFeed(feed) }
                                            .contextMenu { MoveToFolderMenu(model: model, feed: feed) }
                                        }
                                    }
                                }
                                .padding(.bottom, 34)
                            }
                        }
                    }
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
        .alert(
            newFolderKind == .smart ? "New Smart Folder" : "New Folder",
            isPresented: Binding(get: { newFolderKind != nil }, set: { if !$0 { newFolderKind = nil } })
        ) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderKind = nil }
            Button(newFolderKind == .smart ? "Next" : "Create") {
                let kind = newFolderKind
                newFolderKind = nil
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                if kind == .smart {
                    // Saved by the editor, so cancelling it leaves no empty folder behind.
                    smartFolderDraft = model.newFolderDraft(name: name, isSmart: true)
                } else {
                    Task { await model.createFolder(name: name) }
                }
            }
        } message: {
            Text(newFolderKind == .smart
                 ? "Next, choose the rules that pick its feeds."
                 : "Move feeds into it from a feed's menu, or let AI auto-organize them.")
        }
        .sheet(item: $smartFolderDraft) { draft in
            SmartFolderEditor(
                isPresented: Binding(get: { smartFolderDraft != nil }, set: { if !$0 { smartFolderDraft = nil } }),
                folder: draft
            )
            .environmentObject(model)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(SkimStyle.chrome)
        }
    }

    private enum NewFolderKind {
        case regular
        case smart
    }

    private var topControls: some View {
        HStack(spacing: 22) {
            HStack(spacing: 12) {
                BorderlessIconButton(systemName: SkimIcon.settings, title: "Settings", size: 23, tapSize: 42, action: onSettings)
                SkimWordmark(size: 26)
            }
            Spacer()
            BorderlessIconButton(systemName: SkimIcon.chat, title: "Chat", size: 23, tapSize: 42, action: onChat)
            BorderlessIconButton(systemName: SkimIcon.addFeed, title: "Discover Feeds", size: 23, tapSize: 42, action: onAddFeed)
        }
        // Leading 11 centers the 42pt gear button on the picker rows' icon
        // column below (20pt row inset + 12pt half-tile = 32pt = 11 + 21).
        .padding(.leading, 11)
        .padding(.trailing, 26)
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
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(SkimStyle.surface)
                    Image(systemName: iconSystemName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? SkimStyle.accent : SkimStyle.secondary)
                }
                .frame(width: 24, height: 24)
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
            HStack(spacing: 12) {
                if let icon {
                    icon
                }

                Text(title)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? SkimStyle.text : SkimStyle.text.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let count, count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 20)
            .background(isSelected ? SkimStyle.surface.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectFeed(_ feed: Feed) {
        dismissUIKitKeyboard()
        model.selectedFeedID = feed.id
        model.selectedFolderID = nil
        if model.listMode == .recent {
            model.listMode = .unread
        }
        onShowList()
        isPresented = false
        Task { await model.reloadArticles() }
    }

    private func selectFolder(_ folder: FeedFolder) {
        dismissUIKitKeyboard()
        model.selectedFolderID = folder.id
        model.selectedFeedID = nil
        if model.listMode == .starred || model.listMode == .recent {
            model.listMode = .all
        }
        onShowList()
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

private struct FolderSection: View {
    @EnvironmentObject private var model: AppModel
    var folder: FeedFolder
    var feeds: [Feed]
    var selectedFeedID: String?
    var selectedFolderID: String?
    var unreadCounts: [String: Int]
    var onSelect: (Feed) -> Void
    var onSelectFolder: (FeedFolder) -> Void
    @State private var isExpanded = true
    @State private var showSmartFolderEditor = false

    private var folderUnread: Int {
        feeds.compactMap { unreadCounts[$0.id] }.reduce(0, +)
    }

    private var isFolderSelected: Bool {
        selectedFolderID == folder.id
    }

    private var folderSystemImage: String {
        if folder.isSmart {
            return isExpanded ? "folder.badge.gearshape" : "folder.badge.gearshape"
        }
        return isExpanded ? "folder.fill" : "folder"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Tapping the icon + name area = select folder (filter)
                Button {
                    onSelectFolder(folder)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(SkimStyle.surface)
                            Image(systemName: folderSystemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isFolderSelected ? SkimStyle.accent : SkimStyle.accent.opacity(0.7))
                        }
                        .frame(width: 24, height: 24)

                        Text(folder.name)
                            .font(.system(size: 16, weight: isFolderSelected ? .semibold : .semibold))
                            .foregroundStyle(isFolderSelected ? SkimStyle.text : SkimStyle.text)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer()

                        if folderUnread > 0 {
                            Text(folderUnread.formatted())
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(SkimStyle.secondary)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if folder.isSmart {
                        Button("Edit Rules", systemImage: "slider.horizontal.3") {
                            showSmartFolderEditor = true
                        }
                        Button("Convert to Regular Folder", systemImage: "folder") {
                            Task { await convertToRegularFolder() }
                        }
                    } else {
                        Button("Convert to Smart Folder", systemImage: "folder.badge.gearshape") {
                            showSmartFolderEditor = true
                        }
                    }
                }
                .sheet(isPresented: $showSmartFolderEditor) {
                    SmartFolderEditor(isPresented: $showSmartFolderEditor, folder: folder)
                        .environmentObject(model)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(SkimStyle.chrome)
                }

                // Chevron button — only expands/collapses, does not filter
                Button {
                    withAnimation(.smooth(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SkimStyle.secondary.opacity(0.6))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .background(isFolderSelected ? SkimStyle.surface.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(feeds) { feed in
                        let isSelected = selectedFeedID == feed.id
                        Button {
                            onSelect(feed)
                        } label: {
                            HStack(spacing: 12) {
                                // Indent to align with folder icon column
                                Color.clear.frame(width: 24)
                                    .padding(.leading, 20)

                                FeedIcon(feed: feed)

                                Text(feed.title)
                                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? SkimStyle.text : SkimStyle.text.opacity(0.78))
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer()

                                if let count = unreadCounts[feed.id], count > 0 {
                                    Text(count.formatted())
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundStyle(SkimStyle.secondary)
                                }
                            }
                            .frame(minHeight: 40)
                            .padding(.trailing, 20)
                            .background(isSelected ? SkimStyle.surface.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { MoveToFolderMenu(model: model, feed: feed) }
                    }
                }
            }
        }
    }

    private func convertToRegularFolder() async {
        var updated = folder
        updated.isSmart = false
        updated.rulesJSON = nil
        do {
            try await model.store.upsertFolder(updated)
            model.folders = try await model.store.listFolders()
        } catch {
            // Silently ignore — folder reverts on next load
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

/// Long-press menu on a feed: move it into a regular folder, or out of its folder.
private struct MoveToFolderMenu: View {
    @ObservedObject var model: AppModel
    let feed: Feed

    var body: some View {
        let regularFolders = model.folders.filter { !$0.isSmart }
        Menu("Move to Folder", systemImage: "folder") {
            ForEach(regularFolders) { folder in
                Button {
                    Task { await model.moveFeed(id: feed.id, toFolder: folder.id) }
                } label: {
                    if feed.folderID == folder.id {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
            if feed.folderID != nil {
                Divider()
                Button("Remove from Folder", systemImage: "folder.badge.minus") {
                    Task { await model.moveFeed(id: feed.id, toFolder: nil) }
                }
            }
        }
        .disabled(regularFolders.isEmpty)
    }
}

/// A folder with AI sparkles: auto-grouping sorts feeds with AI, it doesn't just add a folder.
struct AutoGroupIcon: View {
    var size: CGFloat

    var body: some View {
        Image(systemName: "folder")
            .font(.system(size: size, weight: .regular))
            .overlay(alignment: .topTrailing) {
                // Big enough that all three sparkles read at sidebar size; one alone looks like a plus.
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.9, weight: .bold))
                    .offset(x: size * 0.6, y: -size * 0.85)
            }
            .accessibilityHidden(true)
    }
}

private struct AutoGroupProposal: Identifiable {
    var id: String { "\(baseName)-\(feeds.map(\.id).joined(separator: ","))" }
    var baseName: String
    var feeds: [Feed]
    /// User-edited override; nil = derive from baseName + nameStyle
    var customName: String?

    func displayName(style: AutoGroupNameStyle) -> String {
        if let customName, !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return style.formatName(baseName)
    }
}

private struct AutoGroupSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var nameStyle: AutoGroupNameStyle = .titleCase
    @State private var proposals: [AutoGroupProposal] = []
    @State private var isRunningAI = false
    @State private var isApplying = false
    @State private var aiMessage: String?
    @State private var didRunAI = false
    @State private var usedFallback = false
    @State private var draggingFeedID: String?
    @State private var dropTargetProposalID: String?
    @State private var feedbackText = ""
    @State private var isRevising = false
    /// The last AI call failed, so its message offers AI settings.
    @State private var aiFailed = false
    @FocusState private var feedbackFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Auto-group feeds")
                        .font(.system(size: 27, weight: .heavy))
                        .foregroundStyle(SkimStyle.text)
                    if !isEditingFeedback {
                        Text("Use AI to classify feeds into folder proposals, then choose the folder naming style.")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(SkimStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                // The gear sits under the close button so the title keeps its width.
                VStack(spacing: 0) {
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

                    AISettingsButton(font: .system(size: 18, weight: .semibold),
                                     onDismiss: { if aiFailed { Task { await runAI() } } })
                }
            }

            if !isEditingFeedback {
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
                        ForEach($proposals) { $proposal in
                            AutoGroupProposalRow(
                                proposal: $proposal,
                                nameStyle: nameStyle,
                                draggingFeedID: $draggingFeedID,
                                isDropTarget: dropTargetProposalID == proposal.id
                            )
                            .onDrop(
                                of: ["public.plain-text"],
                                delegate: FeedDropDelegate(
                                    targetProposalID: proposal.id,
                                    proposals: $proposals,
                                    draggingFeedID: $draggingFeedID,
                                    dropTargetProposalID: $dropTargetProposalID
                                )
                            )
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }

            if !proposals.isEmpty {
                feedbackField
            }

            if !proposals.isEmpty && !isRunningAI && !isEditingFeedback {
                AIDisclaimerLabel()
                    .padding(.top, 2)
            }

            if !isEditingFeedback {
                HStack(spacing: 12) {
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
                    .foregroundStyle(isRunningAI ? SkimStyle.secondary : SkimStyle.text)
                    .padding(.horizontal, 15)
                    .frame(height: 42)
                    .background(SkimStyle.surface.opacity(0.85), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(SkimStyle.separator, lineWidth: 1)
                    }
                    .disabled(isRunningAI || isApplying)

                    Spacer()

                    if !proposals.isEmpty {
                        Button {
                            Task { await applyProposals() }
                        } label: {
                            HStack(spacing: 8) {
                                if isApplying {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(SkimStyle.text)
                                }
                                Text(isApplying ? "Applying…" : "Apply")
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(SkimStyle.text)
                        .padding(.horizontal, 15)
                        .frame(height: 42)
                        .background(SkimStyle.accent.opacity(isApplying ? 0.45 : 0.95), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.white.opacity(0.28), lineWidth: 1)
                        }
                        .disabled(isRunningAI || isApplying)
                    }

                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.glassProminent)
                }
                .padding(.top, 2)
            }
        }
        .animation(.smooth(duration: 0.2), value: isEditingFeedback)
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
                Text("\(isRevising ? "Revising with" : "Asking") \(AutoGroupClassifier.providerLabel(for: model.settings.ai.provider))...")
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

                if aiFailed {
                    AISettingsButton(titled: true, color: SkimStyle.accent, onDismiss: { Task { await runAI() } })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(SkimStyle.surface.opacity(0.66), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// While typing feedback the keyboard takes half the sheet; drop the chrome so the
    /// proposals being discussed stay visible above the box.
    private var isEditingFeedback: Bool {
        feedbackFocused && !isRunningAI
    }

    private var trimmedFeedback: String {
        feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Free-text feedback on the proposal ("merge Coding into SoftwareEngineering"),
    /// sent to the AI together with the current grouping so it revises rather than restarts.
    private var feedbackField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Tell AI what to change…", text: $feedbackText, axis: .vertical)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(SkimStyle.text)
                .lineLimit(1...4)
                .focused($feedbackFocused)
                .submitLabel(.send)
                .onSubmit { Task { await reviseWithFeedback() } }
                .onChange(of: feedbackText) { _, newValue in
                    // A multi-line field takes Return as a newline; treat it as Send instead.
                    guard newValue.contains("\n") else { return }
                    feedbackText = newValue.replacingOccurrences(of: "\n", with: " ")
                    Task { await reviseWithFeedback() }
                }
                .padding(.vertical, 10)
                .padding(.leading, 14)

            Button {
                Task { await reviseWithFeedback() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(trimmedFeedback.isEmpty || isRunningAI ? SkimStyle.secondary.opacity(0.5) : SkimStyle.accent)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(trimmedFeedback.isEmpty || isRunningAI || isApplying)
            .accessibilityLabel("Revise grouping")
            .padding(.trailing, 2)
        }
        .background(SkimStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(feedbackFocused ? SkimStyle.accent.opacity(0.6) : SkimStyle.separator, lineWidth: 1)
        }
    }

    private func reviseWithFeedback() async {
        let feedback = trimmedFeedback
        guard !feedback.isEmpty, !proposals.isEmpty, !isRunningAI else { return }
        dismissUIKitKeyboard()
        feedbackFocused = false

        let current = proposals.map { (name: $0.displayName(style: nameStyle), feeds: $0.feeds) }
        isRevising = true
        isRunningAI = true
        aiMessage = nil

        do {
            proposals = try await AutoGroupClassifier.revisedProposals(
                current: current,
                feedback: feedback,
                feeds: model.feeds,
                settings: model.settings
            )
            usedFallback = false
            feedbackText = ""
            aiMessage = "Revised with \(AutoGroupClassifier.providerLabel(for: model.settings.ai.provider)): \u{201C}\(feedback)\u{201D}"
            aiFailed = false
        } catch {
            aiFailed = true
            aiMessage = "Couldn't revise the grouping: \(error.localizedDescription)\nYour feedback is still in the box below."
        }

        isRunningAI = false
        isRevising = false
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

    private func applyProposals() async {
        dismissUIKitKeyboard()
        isApplying = true
        let organized: [(folderName: String, feedIDs: [String])] = proposals.map { proposal in
            (folderName: proposal.displayName(style: nameStyle), feedIDs: proposal.feeds.map(\.id))
        }
        await model.applyOrganization(proposal: organized)
        isApplying = false
        isPresented = false
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
            aiFailed = false
        } catch {
            aiFailed = true
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
    @Binding var proposal: AutoGroupProposal
    var nameStyle: AutoGroupNameStyle
    @Binding var draggingFeedID: String?
    var isDropTarget: Bool

    private var editingName: Binding<String> {
        Binding(
            get: { proposal.customName ?? proposal.displayName(style: nameStyle) },
            set: { proposal.customName = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Folder header row
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SkimStyle.accent)
                    .frame(width: 22)

                TextField("Folder name", text: editingName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(SkimStyle.text)
                    .submitLabel(.done)

                Spacer()

                Text("\(proposal.feeds.count)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SkimStyle.secondary)
            }

            // Per-feed rows with drag handles
            VStack(alignment: .leading, spacing: 0) {
                ForEach(proposal.feeds, id: \.id) { feed in
                    let isDraggingThis = draggingFeedID == feed.id
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(SkimStyle.secondary.opacity(0.6))
                            .frame(width: 22)

                        Text(feed.title)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(isDraggingThis ? SkimStyle.secondary.opacity(0.4) : SkimStyle.secondary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .opacity(isDraggingThis ? 0.4 : 1.0)
                    .onDrag {
                        draggingFeedID = feed.id
                        return NSItemProvider(object: feed.id as NSString)
                    }
                }
            }
            .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            isDropTarget
                ? SkimStyle.accent.opacity(0.10)
                : SkimStyle.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    isDropTarget ? SkimStyle.accent.opacity(0.6) : SkimStyle.separator,
                    lineWidth: isDropTarget ? 1.5 : 1
                )
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTarget)
    }
}

private struct FeedDropDelegate: DropDelegate {
    let targetProposalID: String
    @Binding var proposals: [AutoGroupProposal]
    @Binding var draggingFeedID: String?
    @Binding var dropTargetProposalID: String?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: ["public.plain-text"])
    }

    func dropEntered(info: DropInfo) {
        dropTargetProposalID = targetProposalID
    }

    func dropExited(info: DropInfo) {
        if dropTargetProposalID == targetProposalID {
            dropTargetProposalID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetProposalID = nil
        guard let item = info.itemProviders(for: ["public.plain-text"]).first else { return false }

        item.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { data, _ in
            guard
                let data = data as? Data,
                let feedID = String(data: data, encoding: .utf8)
            else { return }

            DispatchQueue.main.async {
                // Find which source proposal contains this feed
                guard
                    let sourceIdx = proposals.firstIndex(where: { $0.feeds.contains(where: { $0.id == feedID }) }),
                    let targetIdx = proposals.firstIndex(where: { $0.id == targetProposalID }),
                    sourceIdx != targetIdx,
                    let feed = proposals[sourceIdx].feeds.first(where: { $0.id == feedID })
                else {
                    draggingFeedID = nil
                    return
                }

                withAnimation(.smooth(duration: 0.22)) {
                    proposals[sourceIdx].feeds.removeAll { $0.id == feedID }
                    proposals[targetIdx].feeds.append(feed)
                    // Remove empty source folder
                    if proposals[sourceIdx].feeds.isEmpty {
                        proposals.remove(at: sourceIdx)
                    }
                }
                draggingFeedID = nil
            }
        }
        return true
    }
}

// Triage JSON parse-failure logger for auto-group path.
// Visible in Console.app: subsystem "com.skim.app" category "triage-json"
private let autoGroupTriageLogger = Logger(subsystem: "com.skim.app", category: "triage-json")

private enum AutoGroupClassifier {
    static func aiProposals(for feeds: [Feed], settings: AppSettings) async throws -> [AutoGroupProposal] {
        let uniqueFeeds = deduplicate(feeds)
        guard !uniqueFeeds.isEmpty else { return [] }

        // FM guided-generation fast path — schema-constrained output, bypasses JSON repair.
#if canImport(FoundationModels)
        if #available(iOS 26.0, *), settings.ai.provider == "foundation-models" {
            let proposals = try await FoundationModelFeedOrganizer.proposals(for: uniqueFeeds)
            try validate(proposals: proposals, feedCount: uniqueFeeds.count)
            return proposals
        }
#endif

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

    /// Revise `current` following the reader's free-text `feedback`. Unlike a fresh run this
    /// skips the folder-count checks: "merge X into Y" legitimately leaves fewer folders.
    static func revisedProposals(
        current: [(name: String, feeds: [Feed])],
        feedback: String,
        feeds: [Feed],
        settings: AppSettings
    ) async throws -> [AutoGroupProposal] {
        let uniqueFeeds = deduplicate(feeds)
        guard !uniqueFeeds.isEmpty else { return [] }
        let currentJSON = currentGroupingJSON(current, feeds: uniqueFeeds)

        let revised: [AutoGroupProposal]
#if canImport(FoundationModels)
        if #available(iOS 26.0, *), settings.ai.provider == "foundation-models" {
            revised = try await FoundationModelFeedOrganizer.proposals(
                for: uniqueFeeds,
                revising: (currentJSON: currentJSON, feedback: feedback)
            )
            return keepUnplacedFeeds(revised, current: current)
        }
#endif
        let content = try await NativeAI.complete(
            settings: settings,
            instructions: revisionInstructions,
            prompt: revisionPrompt(feeds: uniqueFeeds, currentJSON: currentJSON, feedback: feedback),
            maxTokens: max(512, uniqueFeeds.count * 4 + 160),
            jsonMode: true
        )
        revised = try decodeProposals(from: content, feeds: uniqueFeeds, modelID: settings.ai.model ?? settings.ai.provider)
        return keepUnplacedFeeds(revised, current: current)
    }

    static let revisionInstructions = """
    You revise a proposed grouping of RSS feeds into folders, following the reader's feedback. Output ONLY valid JSON. No prose. No markdown fences.
    Each feed goes in exactly one folder. Keep folders the feedback doesn't mention as they are.
    Refer to feeds by their numeric handle.
    """

    /// The current grouping as `{"folders":[{"name":…,"feeds":[handles]}]}`, using the
    /// same zero-based handles as the feed listing.
    static func currentGroupingJSON(_ current: [(name: String, feeds: [Feed])], feeds: [Feed]) -> String {
        var handles: [String: Int] = [:]
        for (index, feed) in feeds.enumerated() where handles[feed.id] == nil {
            handles[feed.id] = index
        }
        let folders: [[String: Any]] = current.map { folder in
            ["name": folder.name, "feeds": folder.feeds.compactMap { handles[$0.id] }]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["folders": folders], options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"folders":[]}"#
    }

    static func revisionPrompt(feeds: [Feed], currentJSON: String, feedback: String) -> String {
        """
        Feeds (handle TAB title [TAB site]):
        \(listing(for: feeds))

        Current grouping:
        \(currentJSON)

        Reader's feedback: "\(feedback)"

        Output the full revised grouping, every feed exactly once, as ONLY this JSON shape:
        {"folders":[{"name":"Tech","feeds":[0,3,7]}]}
        """
    }

    /// A revision must not lose feeds: any feed the AI left out goes back into its
    /// previous folder (matched by name), so applying never drops it.
    static func keepUnplacedFeeds(_ revised: [AutoGroupProposal], current: [(name: String, feeds: [Feed])]) -> [AutoGroupProposal] {
        var result = revised
        let placed = Set(revised.flatMap { $0.feeds.map(\.id) })
        for previous in current {
            let missing = previous.feeds.filter { !placed.contains($0.id) }
            guard !missing.isEmpty else { continue }
            if let index = result.firstIndex(where: { $0.baseName.caseInsensitiveCompare(previous.name) == .orderedSame }) {
                result[index].feeds.append(contentsOf: missing)
            } else {
                result.append(AutoGroupProposal(baseName: previous.name, feeds: missing))
            }
        }
        return result
    }

    static func providerLabel(for provider: String) -> String {
        switch provider {
        case "foundation-models": return "Apple Intelligence"
        case "claude-subscription": return "Claude Pro/Max"
        case "chatgpt-subscription": return "ChatGPT"
        case "mlx": return "MLX"
        case "xai": return "Grok"
        case "openai": return "OpenAI"
        case "openrouter": return "OpenRouter"
        case "custom": return "custom provider"
        case "anthropic": return "Claude"
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
        let modelID: String = {
            let candidates = [settings.ai.localModelPath, settings.ai.model, settings.ai.provider]
            return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty }) ?? settings.ai.provider
        }()
        return try decodeProposals(from: content, feeds: feeds, modelID: modelID)
    }

    private static var systemInstructions: String {
        """
        You group RSS feeds into 4-8 topical folders. Output ONLY valid JSON. No prose. No markdown fences. No explanation before or after the JSON.
        Each feed goes in exactly one folder. Short folder names (2-4 words).
        Refer to feeds by their numeric handle.
        """
    }

    private static func prompt(for feeds: [Feed], correctiveNote: String?) -> String {
        let correction = correctiveNote.map { "\($0)\n\n" } ?? ""

        return """
        \(correction)Feeds (handle TAB title [TAB site]):
        \(listing(for: feeds))

        Output ONLY this JSON shape, nothing else:
        {"folders":[{"name":"Tech","feeds":[0,3,7]}]}
        """
    }

    fileprivate static func listing(for feeds: [Feed]) -> String {
        feeds.enumerated()
            .map { index, feed in
                let title = feed.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let site = feed.siteURL?.host() ?? feed.url.host() ?? ""
                return "\(index)\t\(title)\t\(site)"
            }
            .joined(separator: "\n")
    }

    private static func decodeProposals(from content: String, feeds: [Feed], modelID: String = "unknown") throws -> [AutoGroupProposal] {
        // 1. Try strict decode first (no repair)
        let decoder = JSONDecoder()
        var strictSucceeded = false
        if let rawData = content.data(using: .utf8),
           (try? decoder.decode(AutoGroupAIResponse.self, from: rawData)) != nil {
            strictSucceeded = true
        }

        // 2. Use shared JSON repair: strip fences + find balanced braces
        let json = NativeAI.repairTriageJSON(content)
        if !strictSucceeded && json != content {
            autoGroupTriageLogger.warning("Auto-group JSON repaired for model '\(modelID, privacy: .public)': stripped fences/junk.")
        }

        guard let data = json.data(using: .utf8) else {
            autoGroupTriageLogger.error("Auto-group JSON unreadable for model '\(modelID, privacy: .public)'.")
            throw AutoGroupAIError.invalidResponse("AI returned unreadable JSON.")
        }

        let folders: [AutoGroupAIFolder]
        do {
            folders = try decoder.decode(AutoGroupAIResponse.self, from: data).folders
        } catch {
            do {
                folders = try decoder.decode([AutoGroupAIFolder].self, from: data)
            } catch {
                let preview = String(content.prefix(200)).replacingOccurrences(of: "\n", with: " ")
                autoGroupTriageLogger.error("Auto-group JSON parse failed for model '\(modelID, privacy: .public)'. Raw: \(preview, privacy: .public)")
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
    /// Groups feeds using Foundation Models `@Generable` guided generation.
    /// Bypasses JSON parsing and the `repairTriageJSON` path entirely — the schema
    /// guarantees well-formed output.
    static func proposals(
        for feeds: [Feed],
        revising revision: (currentJSON: String, feedback: String)? = nil
    ) async throws -> [AutoGroupProposal] {
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
            instructions: revision != nil ? AutoGroupClassifier.revisionInstructions : """
            You group RSS feeds into topical folders.
            Each feed must appear in exactly one folder. Use 4–8 folders when possible.
            Use short folder names of 2–4 words. Refer to each feed only by its zero-based numeric handle.
            """
        )

        let maxTokens = max(512, feeds.count * 6 + 160)
        let response = try await session.respond(
            to: revision.map {
                AutoGroupClassifier.revisionPrompt(feeds: feeds, currentJSON: $0.currentJSON, feedback: $0.feedback)
            } ?? prompt(for: feeds),
            generating: NativeAI.FMAutoGroupProposal.self,
            options: GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: maxTokens
            )
        )

        return try buildProposals(from: response.content, feeds: feeds)
    }

    private static func prompt(for feeds: [Feed]) -> String {
        """
        Feeds, one per line as handle TAB title TAB site:
        \(listing(for: feeds))

        Group every feed into 4–8 topical folders. Each feed must appear exactly once.
        Use the zero-based numeric handle to reference feeds.
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

    /// Convert the `@Generable` FM output into `AutoGroupProposal` values.
    /// Uses zero-based `feedIndices` directly — no string parsing required.
    private static func buildProposals(
        from fmProposal: NativeAI.FMAutoGroupProposal,
        feeds: [Feed]
    ) throws -> [AutoGroupProposal] {
        var seenFeedIDs: Set<String> = []
        let proposals = fmProposal.folders.compactMap { folder -> AutoGroupProposal? in
            let selectedFeeds = folder.feedIndices.compactMap { index -> Feed? in
                guard feeds.indices.contains(index) else { return nil }
                let feed = feeds[index]
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
            throw AutoGroupAIError.invalidResponse("Foundation Models returned no usable folder proposals.")
        }

        return proposals
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

private struct FeedIcon: View {
    var feed: Feed
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
            Text(initials)
                .font(.system(size: size * 0.42, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        feed.title.skimFeedInitials(fallback: "S")
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
        let index = Int(feed.id.skimStableHash % UInt64(palette.count))
        return palette[index]
    }
}

private struct ArticleRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    var article: Article
    var feed: Feed?
    var visibleArticles: [Article]
    var onSummarize: (Article) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon column — read/unread state is conveyed by title text color, not a dot.
            Group {
                if let feed {
                    FeedIcon(feed: feed, size: 30)
                } else {
                    ArticleSourceIcon(article: article)
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
                        Image(systemName: SkimIcon.starFilled)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.91, green: 0.76, blue: 0.19))
                    }
                }
                .font(.system(size: 15, weight: .regular))
            }

            // Only reserve space for the trailing image when one is present;
            // image-less rows let the title block expand to the full row width.
            if let imageURL = article.imageURL {
                Spacer(minLength: 4)
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
        // ~18pt horizontal margins so content doesn't abut screen edges.
        .padding(.leading, 18)
        .padding(.trailing, 18)
        .padding(.vertical, 11)
        .background(SkimStyle.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SkimStyle.separator.opacity(0.5))
                .frame(height: 1)
                .padding(.leading, 64)
        }
        // Providing an explicit preview forces iOS to composite the glass-blur backdrop
        // synchronously on the first render frame, preventing the 1-2s lag where menu
        // items appear unreadable against the article list content below.
        .contextMenu(menuItems: {
            Button(article.isRead ? "Mark as Unread" : "Mark as Read", systemImage: article.isRead ? SkimIcon.markUnread : SkimIcon.markRead) {
                Task { await model.setRead(article, isRead: !article.isRead) }
            }

            Button(article.isStarred ? "Unstar" : "Star", systemImage: article.isStarred ? SkimIcon.unstar : SkimIcon.star) {
                Task { await model.toggleStar(article) }
            }

            Divider()

            Button("Mark Above as Read", systemImage: "arrow.up.to.line") {
                Task { await model.setRead(articlesAbove, isRead: true) }
            }
            .disabled(articlesAbove.isEmpty)

            Button("Mark Above as Unread", systemImage: "arrow.up.to.line") {
                Task { await model.setRead(articlesAbove, isRead: false) }
            }
            .disabled(articlesAbove.isEmpty)

            Button("Mark Below as Read", systemImage: "arrow.down.to.line") {
                Task { await model.setRead(articlesBelow, isRead: true) }
            }
            .disabled(articlesBelow.isEmpty)

            Button("Mark Below as Unread", systemImage: "arrow.down.to.line") {
                Task { await model.setRead(articlesBelow, isRead: false) }
            }
            .disabled(articlesBelow.isEmpty)

            Divider()

            Button("Summarize", systemImage: SkimIcon.summarize) {
                onSummarize(article)
            }

            if let url = article.url {
                Divider()
                Button("Open in Browser", systemImage: SkimIcon.openExternal) {
                    openURL(url)
                }
            }
        }, preview: {
            Text(article.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SkimStyle.text)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 280, alignment: .leading)
                .background(SkimStyle.chrome)
        })
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
        // Aggregator posts (Hacker News, Lobsters, Reddit) name the site the
        // story links to; their own feed text is only a "Comments" stub.
        if let host = article.externalURL?.host(percentEncoded: false) {
            return host.replacingOccurrences(of: "www.", with: "")
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
            Circle()
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
        article.feedTitle.skimFeedInitials(fallback: "S")
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
        let index = Int(article.feedID.skimStableHash % UInt64(palette.count))
        return palette[index]
    }
}

private func dismissUIKitKeyboard() {
#if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
}

private extension String {
    /// A deterministic hash that stays identical across app launches and processes.
    /// Swift's built-in `String.hashValue` is seeded randomly per process, so it must
    /// never be used to derive UI that should look the same everywhere (e.g. avatar colors).
    var skimStableHash: UInt64 {
        var hash: UInt64 = 14695981039346656037 // FNV-1a offset basis
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211 // FNV-1a prime
        }
        return hash
    }

    func skimFeedInitials(fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(
            of: #"^/?r/([^/\s]+).*"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )
        let cleaned = normalized.drop(while: { !$0.isLetter && !$0.isNumber })
        let words = cleaned
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(2)
            .compactMap { word in word.first(where: { $0.isLetter || $0.isNumber }) }
        let value = String(words).uppercased()
        return value.isEmpty ? fallback : value
    }
}

/// A view the bottom bar can hold. Giulio picks which ones show, and their
/// order, in Customize Bottom Bar; the choice is kept in user defaults.
enum BottomBarItem: String, CaseIterable, Identifiable {
    case today
    case unread
    case all
    case starred
    case recent
    case aiInbox
    case search

    static let storageKey = "bottomBarItems"
    static let minimumCount = 2
    static let maximumCount = 5
    /// Today takes the place Starred had; Starred stays a tap away in Feeds.
    static let defaultItems: [BottomBarItem] = [.unread, .all, .today, .search]
    static var defaultStorage: String { encode(defaultItems) }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .unread: "Unread"
        case .all: "All"
        case .starred: "Starred"
        case .recent: "Recent"
        case .aiInbox: "For you"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .today: SkimIcon.today
        case .unread: SkimIcon.unread
        case .all: SkimIcon.allArticles
        case .starred: SkimIcon.starred
        case .recent: SkimIcon.recent
        case .aiInbox: SkimIcon.aiInbox
        case .search: SkimIcon.search
        }
    }

    /// The article-list filter this item shows, for the items that are one.
    var listMode: ArticleListMode? {
        switch self {
        case .unread: .unread
        case .all: .all
        case .starred: .starred
        case .recent: .recent
        case .today, .aiInbox, .search: nil
        }
    }

    static func encode(_ items: [BottomBarItem]) -> String {
        items.map(\.rawValue).joined(separator: ",")
    }

    /// Unknown or repeated names are dropped (so a bar that still names the
    /// old Catch-up tab just loses it); a list too short to navigate falls
    /// back to the default.
    static func decode(_ storage: String) -> [BottomBarItem] {
        var seen: Set<BottomBarItem> = []
        let items = storage.split(separator: ",").compactMap { BottomBarItem(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        guard items.count >= minimumCount else { return defaultItems }
        return Array(items.prefix(maximumCount))
    }
}

/// Picks and orders the bottom bar's views: drag to reorder, tap the minus to
/// take one out, tap a view under "More" to add it.
private struct BottomBarEditor: View {
    @Binding var storage: String
    @Environment(\.dismiss) private var dismiss

    private var items: [BottomBarItem] { BottomBarItem.decode(storage) }
    private var hidden: [BottomBarItem] { BottomBarItem.allCases.filter { !items.contains($0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        row(item)
                    }
                    .onMove { from, to in
                        var next = items
                        next.move(fromOffsets: from, toOffset: to)
                        storage = BottomBarItem.encode(next)
                    }
                    .onDelete { offsets in
                        var next = items
                        next.remove(atOffsets: offsets)
                        storage = BottomBarItem.encode(next)
                    }
                    .deleteDisabled(items.count <= BottomBarItem.minimumCount)
                } header: {
                    Text("In the bar")
                } footer: {
                    Text("Up to \(BottomBarItem.maximumCount) views. Long-press the bar to come back here.")
                }

                if !hidden.isEmpty {
                    Section("More") {
                        ForEach(hidden) { item in
                            Button {
                                storage = BottomBarItem.encode(items + [item])
                            } label: {
                                HStack {
                                    row(item)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(items.count < BottomBarItem.maximumCount ? SkimStyle.accent : SkimStyle.secondary)
                                }
                            }
                            .disabled(items.count >= BottomBarItem.maximumCount)
                        }
                    }
                }

                Section {
                    Button("Reset to Default") {
                        storage = BottomBarItem.defaultStorage
                    }
                    .disabled(items == BottomBarItem.defaultItems)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .navigationTitle("Bottom Bar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ item: BottomBarItem) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .foregroundStyle(SkimStyle.text)
    }
}
