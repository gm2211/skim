import PDFKit
import SkimCore
import SwiftUI

private enum DetailPage: String, CaseIterable {
    case reader
    case web
}

struct ArticleDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let articleID: String

    @State private var article: Article?
    @State private var page: DetailPage = .reader
    @State private var isLoading = true
    @State private var activeAIResult: AIResultRequest?
    @State private var activeAIChat: AIChatRequest?
    @State private var activeChatInitialMessage: String? = nil
    @State private var chatMessagesBySession: [String: [AIChatMessage]] = [:]
    @State private var activeSummaryConfiguration: Article?
    @State private var showAIDisclaimerGate = false
    @State private var pendingAIAction: (() -> Void)?
    @State private var webSnapshot = WebViewSnapshot()

    // Reading-time tracking
    @State private var openedAt: Date?
    @State private var currentPriorityOverride: ArticlePriorityOverride = .none

    var body: some View {
        ZStack {
            SkimStyle.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                TabView(selection: $page) {
                    ReaderPage(article: article, isLoading: isLoading)
                        .contextMenu(menuItems: { detailContextMenu }, preview: { contextMenuPreview })
                        .tag(DetailPage.reader)

                    WebPage(article: article, snapshot: $webSnapshot)
                        .contextMenu(menuItems: { detailContextMenu }, preview: { contextMenuPreview })
                        .tag(DetailPage.web)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.smooth(duration: 0.28), value: page)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(readerBackGesture)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await load(markRead: true)
        }
        .onAppear {
            openedAt = Date()
            if let article {
                let signal = model.tasteStore.signal(for: article.id)
                currentPriorityOverride = signal?.priorityOverride ?? .none
            }
        }
        .onDisappear {
            recordDwell()
        }
        .alert("Skim", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $activeAIResult) { request in
            AIResultSheet(request: request)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $activeSummaryConfiguration) { article in
            SummaryConfigurationSheet(article: article, defaults: model.settings.ai) { summarySettings in
                runSummary(article: article, summarySettings: summarySettings)
            }
            .presentationDetents([.medium, .large])
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
                .onDisappear { activeChatInitialMessage = nil }
        }
        .fullScreenCover(isPresented: $showAIDisclaimerGate) {
            AIBootDisclaimerView {
                AIBootDisclaimerView.markAccepted()
                showAIDisclaimerGate = false
                pendingAIAction?()
                pendingAIAction = nil
            }
        }
    }

    private func gatedAI(_ action: @escaping () -> Void) {
        if AIBootDisclaimerView.isAccepted {
            action()
        } else {
            pendingAIAction = action
            showAIDisclaimerGate = true
        }
    }

    private func recordDwell() {
        guard let article, let openedAt else { return }
        let dwell = Date().timeIntervalSince(openedAt)
        model.recordReadingTime(
            articleID: article.id,
            feedID: article.feedID,
            feedTitle: article.feedTitle,
            dwellSeconds: dwell
        )
    }

    private func applyPriorityOverride(_ override: ArticlePriorityOverride) {
        guard let article else { return }
        let newOverride: ArticlePriorityOverride = currentPriorityOverride == override ? .none : override
        currentPriorityOverride = newOverride
        model.setPriorityOverride(
            articleID: article.id,
            feedID: article.feedID,
            feedTitle: article.feedTitle,
            override: newOverride
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            BorderlessIconButton(systemName: "chevron.left", title: "Back", size: 25, tapSize: 42) {
                dismiss()
            }

            Spacer(minLength: 4)

            BorderlessIconButton(systemName: "book", title: "Reader", isActive: page == .reader, size: 25, tapSize: 42) {
                page = .reader
            }
            BorderlessIconButton(systemName: "globe", title: "Web", isActive: page == .web, size: 26, tapSize: 42) {
                page = .web
            }
            BorderlessIconButton(systemName: "doc.text", title: "Summary", size: 23, tapSize: 40) {
                presentSummary()
            }
            BorderlessIconButton(systemName: "bubble.left", title: "Chat", size: 22, tapSize: 40) {
                presentArticleChat()
            }
            BorderlessIconButton(systemName: article?.isStarred == true ? "star.fill" : "star", title: article?.isStarred == true ? "Unstar" : "Star", isActive: article?.isStarred == true, size: 26, tapSize: 42) {
                Task { await toggleStar() }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 76)
    }

    private var readerBackGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard page == .reader,
                      abs(value.translation.width) > abs(value.translation.height)
                else { return }

                let shouldDismiss = value.translation.width > 82 || value.predictedEndTranslation.width > 145
                guard shouldDismiss else { return }
                dismiss()
            }
    }

    // Providing an explicit preview forces iOS to composite the glass-blur backdrop
    // synchronously on the first render frame, preventing the 1-2s lag where menu
    // items appear unreadable against the article content below.
    @ViewBuilder
    private var contextMenuPreview: some View {
        if let article {
            Text(article.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SkimStyle.text)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 280, alignment: .leading)
                .background(SkimStyle.chrome)
        }
    }

    @ViewBuilder
    private var detailContextMenu: some View {
        if let article {
            Button(article.isRead ? "Mark as Unread" : "Mark as Read", systemImage: article.isRead ? "circle" : "checkmark.circle") {
                Task { await toggleRead() }
            }

            Button(article.isStarred ? "Unfavorite" : "Mark Favorite", systemImage: article.isStarred ? "star.slash" : "star") {
                Task { await toggleStar() }
            }

            Divider()

            Button(
                currentPriorityOverride == .pin ? "Unpin" : "Pin to Top",
                systemImage: currentPriorityOverride == .pin ? "pin.slash" : "pin"
            ) {
                applyPriorityOverride(.pin)
            }

            Button(
                currentPriorityOverride == .hide ? "Unhide" : "Hide from Inbox",
                systemImage: currentPriorityOverride == .hide ? "eye" : "eye.slash"
            ) {
                applyPriorityOverride(.hide)
            }

            Divider()

            Button("Summarize", systemImage: "doc.text") {
                presentSummary()
            }

            Button("Chat with Article", systemImage: "bubble.left") {
                presentArticleChat()
            }

            if let url = article.url {
                Divider()

                Button("Open Link", systemImage: "safari") {
                    openURL(url)
                }
            }
        }
    }

    private func load(markRead: Bool) async {
        isLoading = true
        defer { isLoading = false }

        guard var loaded = await model.updatedArticle(id: articleID) else { return }
        if markRead, !loaded.isRead {
            await model.setRead(loaded, isRead: true, keepVisibleInUnreadList: true)
            loaded.isRead = true
        }
        article = loaded
        webSnapshot = WebViewSnapshot(url: loaded.url, title: nil, text: nil)

        // Sync taste state from persisted signals
        let signal = model.tasteStore.signal(for: loaded.id)
        currentPriorityOverride = signal?.priorityOverride ?? .none
    }

    private func toggleRead() async {
        guard var article else { return }
        let next = !article.isRead
        await model.setRead(article, isRead: next, keepVisibleInUnreadList: next)
        article.isRead = next
        self.article = article
    }

    private func toggleStar() async {
        guard var article else { return }
        await model.toggleStar(article)
        article.isStarred.toggle()
        self.article = article
    }

    private func presentSummary() {
        guard let article else { return }
        gatedAI { activeSummaryConfiguration = article }
    }

    private func runSummary(article: Article, summarySettings: AISettings) {
        var settings = model.settings
        settings.ai = summarySettings
        activeSummaryConfiguration = nil
        let useWebContext = page == .web
        let webSnapshot = webSnapshot

        Task {
            await model.saveSettings(settings)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            activeAIResult = AIResultRequest(
                title: "AI Summary",
                subtitle: WebAIContext.subtitle(base: article, preferWeb: useWebContext, snapshot: webSnapshot),
                statusLabel: NativeAI.loadingStatusLabel(for: settings.ai),
                action: {
                    let contextArticle = try await WebAIContext.article(
                        base: article,
                        preferWeb: useWebContext,
                        snapshot: webSnapshot
                    )
                    let text = try await NativeAI.summarize(article: contextArticle, settings: settings)
                    return AIResultAnswer(text: text, articles: [contextArticle])
                },
                streamAction: { onToken in
                    let contextArticle = try await WebAIContext.article(
                        base: article,
                        preferWeb: useWebContext,
                        snapshot: webSnapshot
                    )
                    let text = try await NativeAI.summarizeStreaming(
                        article: contextArticle, settings: settings, onToken: onToken)
                    return AIResultAnswer(text: text, articles: [contextArticle])
                },
                clearAction: {
                    NativeAI.clearSummaryCache(
                        articleID: WebAIContext.articleID(
                            base: article,
                            preferWeb: useWebContext,
                            snapshot: webSnapshot
                        ),
                        ai: settings.ai
                    )
                },
                continueInChat: { [self] summaryText in
                    // Dismiss the summary sheet (already done by AIResultSheet before calling this),
                    // then open the chat sheet with the summary pre-loaded.
                    activeAIResult = nil
                    activeChatInitialMessage = summaryText
                    activeAIChat = AIChatRequest(
                        sessionKey: chatSessionKey(base: article, preferWeb: useWebContext, snapshot: webSnapshot),
                        title: "Chat with Article",
                        placeholder: WebAIContext.subtitle(base: article, preferWeb: useWebContext, snapshot: webSnapshot)
                    ) { conversation in
                        let contextArticle = try await WebAIContext.article(
                            base: article,
                            preferWeb: useWebContext,
                            snapshot: webSnapshot
                        )
                        let text = try await NativeAI.chat(conversation: conversation, article: contextArticle, settings: model.settings)
                        return AIChatAnswer(text: text, articles: [contextArticle])
                    }
                }
            )
        }
    }

    private func chatMessagesBinding(for sessionKey: String) -> Binding<[AIChatMessage]> {
        Binding(
            get: { chatMessagesBySession[sessionKey] ?? [] },
            set: { chatMessagesBySession[sessionKey] = $0 }
        )
    }

    private func chatSessionKey(base article: Article, preferWeb: Bool, snapshot: WebViewSnapshot) -> String {
        WebAIContext.articleID(base: article, preferWeb: preferWeb, snapshot: snapshot)
    }
}

private struct SummaryConfigurationSheet: View {
    var article: Article
    var defaults: AISettings
    var onRun: (AISettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var style: String
    @State private var wordCount: Int
    @State private var customPrompt: String

    init(article: Article, defaults: AISettings, onRun: @escaping (AISettings) -> Void) {
        self.article = article
        self.defaults = defaults
        self.onRun = onRun
        _style = State(initialValue: defaults.summaryTone ?? "concise")
        _wordCount = State(initialValue: defaults.summaryCustomWordCount ?? 150)
        _customPrompt = State(initialValue: defaults.summaryCustomPrompt ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Configure Summary")
                            .font(.system(size: 31, weight: .heavy))
                            .foregroundStyle(SkimStyle.text)
                        Text(article.title)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(SkimStyle.secondary)
                            .lineLimit(3)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Style")
                            .summaryControlLabel()
                        Picker("Style", selection: $style) {
                            Text("Concise").tag("concise")
                            Text("Descriptive").tag("descriptive")
                            Text("Casual").tag("casual")
                            Text("Technical").tag("technical")
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Length")
                            .summaryControlLabel()
                        SummaryWordCountPresetChips(wordCount: $wordCount)
                        Stepper(value: $wordCount, in: 30...600, step: 25) {
                            Text("\(wordCount) words")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(SkimStyle.text)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Custom Prompt")
                            .summaryControlLabel()
                        TextField("Focus on tradeoffs, risks, key takeaways...", text: $customPrompt, axis: .vertical)
                            .lineLimit(4...8)
                            .textInputAutocapitalization(.sentences)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(SkimStyle.text)
                            .padding(14)
                            .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(SkimStyle.separator, lineWidth: 1)
                            }
                    }

                    Text("These choices are saved as your new summary defaults when you run.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
            .background(SkimStyle.chrome.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Run") {
                        onRun(configuredSettings)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var configuredSettings: AISettings {
        var next = defaults
        next.summaryTone = style
        next.summaryCustomWordCount = wordCount
        next.summaryCustomPrompt = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return next
    }
}

// MARK: - Word Count Preset Chips

private struct SummaryWordCountPresetChips: View {
    @Binding var wordCount: Int

    private struct Preset {
        let label: String
        let value: Int
    }

    private let presets: [Preset] = [
        Preset(label: "Short", value: 50),
        Preset(label: "Medium", value: 150),
        Preset(label: "Long", value: 400),
        Preset(label: "XL", value: 600),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(presets, id: \.value) { preset in
                let isSelected = wordCount == preset.value
                Button {
                    wordCount = preset.value
                } label: {
                    Text("\(preset.label) \(preset.value)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(isSelected ? Color.white : SkimStyle.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            isSelected
                                ? AnyShapeStyle(SkimStyle.accent)
                                : AnyShapeStyle(Color.clear),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .stroke(SkimStyle.accent, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .animation(.smooth(duration: 0.18), value: isSelected)
            }
        }
    }
}

private extension Text {
    func summaryControlLabel() -> some View {
        font(.system(size: 13, weight: .bold))
            .foregroundStyle(SkimStyle.secondary)
            .textCase(.uppercase)
            .tracking(1.2)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension ArticleDetailView {
    func presentArticleChat() {
        guard let article else { return }
        let useWebContext = page == .web
        let webSnapshot = webSnapshot
        gatedAI {
            activeAIChat = AIChatRequest(
                sessionKey: chatSessionKey(base: article, preferWeb: useWebContext, snapshot: webSnapshot),
                title: useWebContext ? "Chat with Web Page" : "Chat with Article",
                placeholder: WebAIContext.subtitle(base: article, preferWeb: useWebContext, snapshot: webSnapshot)
            ) { conversation in
                let contextArticle = try await WebAIContext.article(
                    base: article,
                    preferWeb: useWebContext,
                    snapshot: webSnapshot
                )
                let text = try await NativeAI.chat(conversation: conversation, article: contextArticle, settings: model.settings)
                return AIChatAnswer(text: text, articles: [contextArticle])
            }
        }
    }
}

private enum ArticleLoadState {
    case idle
    case loading
    case loaded(String)
    case failed(String)

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    var shouldDisplay: Bool {
        switch self {
        case .idle:
            return false
        case .loading, .loaded, .failed:
            return true
        }
    }
}

private struct ReaderPage: View {
    @EnvironmentObject private var model: AppModel

    var article: Article?
    var isLoading: Bool

    @State private var comments: [AggregatorComment] = []
    @State private var commentsState: ArticleLoadState = .idle
    @State private var extractedBody: ArticleLoadState = .idle
    // Tracks whether the 3s auto-extract timeout has fired (shows fallback button)
    @State private var autoExtractTimedOut = false
    // Reddit self-post body text fetched from the .json API
    @State private var redditSelftext: String? = nil
    // External article URL resolved from Reddit JSON when older entries lack it.
    @State private var resolvedExternalURL: URL? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if isLoading && article == nil {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else if let article {
                    articleHeader(article)
                    if article.aggregatorKind != nil {
                        aggregatorSection(article)
                    } else {
                        articleBody(article)
                    }
                } else {
                    ContentUnavailableView("Article not found", systemImage: "doc.text.magnifyingglass")
                        .foregroundStyle(SkimStyle.text)
                        .padding(.top, 80)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 10)
            .padding(.bottom, 56)
        }
        .scrollIndicators(.visible)
        .onChange(of: article?.id) { _, _ in
            comments = []
            commentsState = .idle
            extractedBody = .idle
            autoExtractTimedOut = false
            redditSelftext = nil
            resolvedExternalURL = nil
        }
        .task(id: article?.id) {
            guard let article else { return }
            if article.aggregatorKind != nil {
                await loadCachedReaderText(for: article)
                // Run comments fetch and external-article extraction concurrently.
                // loadComments sets redditSelftext; we wait for it before deciding whether
                // to auto-extract so we know if this is a selftext post or a link post.
                await loadComments(for: article)
                // Auto-extract the linked article for link posts (aggregator with externalURL
                // but no selftext). Reddit selftext posts keep their current rendering.
                let externalURL = await externalArticleURL(for: article)
                resolvedExternalURL = externalURL
                if let externalURL, redditSelftext == nil, !extractedBody.isLoaded {
                    await loadExternalArticle(url: externalURL, articleID: article.id)
                }
            } else {
                await autoExtractIfNeeded(article: article)
            }
        }
    }

    // MARK: - Header

    private func articleHeader(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(article.displayTitle)
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(SkimStyle.text)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                Text(article.displayFeedTitle)
                    .foregroundStyle(SkimStyle.accent)

                HStack(spacing: 7) {
                    if let author = article.displayAuthor {
                        Text(author)
                    }
                    if article.displayAuthor != nil, article.publishedAt != nil {
                        Text("·")
                    }
                    if let publishedAt = article.publishedAt {
                        Text(publishedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute()))
                    }
                }
                .foregroundStyle(SkimStyle.secondary)
            }
            .font(.system(size: 15, weight: .medium))
            .lineLimit(1)
        }
    }

    // MARK: - Aggregator section

    @ViewBuilder
    private func aggregatorSection(_ article: Article) -> some View {
        let externalURL = article.externalURL ?? resolvedExternalURL

        VStack(alignment: .leading, spacing: 20) {
            // Reddit self-post body (fetched from .json API)
            if let selftext = redditSelftext {
                Text(selftext)
                    .font(.system(size: 19, weight: .regular))
                    .lineSpacing(7)
                    .foregroundStyle(SkimStyle.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // External URL card (link posts or non-self-post aggregator items)
            if let externalURL {
                externalURLCard(url: externalURL, article: article)
            }

            // Extracted body — shown when auto-extract is in progress or complete.
            // Applies to all aggregator kinds including Reddit link posts.
            // (Reddit selftext posts show body via `redditSelftext` above instead.)
            if redditSelftext == nil && (externalURL != nil || extractedBody.shouldDisplay) {
                switch extractedBody {
                case .idle:
                    EmptyView()
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading article…")
                            .font(.system(size: 15))
                            .foregroundStyle(SkimStyle.secondary)
                    }
                    .padding(.vertical, 4)
                case .loaded(let text):
                    Text(text)
                        .font(.system(size: 19, weight: .regular))
                        .lineSpacing(7)
                        .foregroundStyle(SkimStyle.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .failed(let reason):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Could not extract article.")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(SkimStyle.text)
                        Text(reason)
                            .font(.system(size: 14))
                            .foregroundStyle(SkimStyle.secondary)
                        Text("Swipe left for the web view.")
                            .font(.system(size: 14))
                            .foregroundStyle(SkimStyle.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .skimGlass(cornerRadius: 16)
                }
            }

            // Comments section
            commentsSection
        }
    }

    @ViewBuilder
    private func externalURLCard(url: URL, article: Article) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Linked article card
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SkimStyle.accent)
                    Text(url.host(percentEncoded: false) ?? url.absoluteString)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SkimStyle.accent)
                        .lineLimit(1)
                }
                Text(url.absoluteString)
                    .font(.system(size: 12))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(SkimStyle.separator, lineWidth: 1)
            }

            // Retry button only shown after a failed extraction attempt
            if case .failed = extractedBody {
                Button {
                    Task { await loadExternalArticle(url: url, articleID: article.id) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(SkimStyle.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Comments")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SkimStyle.secondary)
                .textCase(.uppercase)
                .tracking(1.2)

            switch commentsState {
            case .idle:
                EmptyView()
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading comments…")
                        .font(.system(size: 15))
                        .foregroundStyle(SkimStyle.secondary)
                }
            case .failed:
                Text("Comments unavailable.")
                    .font(.system(size: 15))
                    .foregroundStyle(SkimStyle.secondary)
            case .loaded:
                if comments.isEmpty {
                    Text("No comments yet.")
                        .font(.system(size: 15))
                        .foregroundStyle(SkimStyle.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(comments) { comment in
                            CommentRow(comment: comment)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Standard body

    @ViewBuilder
    private func articleBody(_ article: Article) -> some View {
        let rssFeedBody = ArticleReaderContentLoader.displayBody(for: article)

        // Determine the body to display:
        // 1. Use a cached extracted body if one exists.
        // 2. Use the RSS body if it meets the threshold and isn't boilerplate.
        // 3. Otherwise, show state based on auto-extract progress.
        if case .loaded(let text) = extractedBody {
            Text(text)
                .font(.system(size: 19, weight: .regular))
                .lineSpacing(7)
                .foregroundStyle(SkimStyle.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if ArticleReaderContentLoader.isSufficientRSSBody(article) {
            Text(rssFeedBody)
                .font(.system(size: 19, weight: .regular))
                .lineSpacing(7)
                .foregroundStyle(SkimStyle.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // RSS body is thin — show auto-extract UI states
            switch extractedBody {
            case .idle:
                // Haven't started yet (or waiting for task to kick off)
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 100)
            case .loading:
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        Text("Loading article…")
                            .font(.system(size: 17))
                            .foregroundStyle(SkimStyle.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Show fallback button after 3s timeout so the user isn't stuck
                    if autoExtractTimedOut, let url = article.url {
                        readerFallbackCard(url: url, article: article)
                    }
                }
            case .loaded:
                // Handled above — shouldn't reach here
                EmptyView()
            case .failed:
                if let url = article.url {
                    readerFallbackCard(url: url, article: article)
                } else {
                    noReaderTextCard
                }
            }
        }
    }

    @ViewBuilder
    private func readerFallbackCard(url: URL, article: Article) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reader text not available.")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SkimStyle.text)

            Button {
                Task { await loadArticleForReader(url: url, articleID: article.id) }
            } label: {
                Label("Load Article", systemImage: "arrow.down.doc")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(SkimStyle.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("Swipe left for web view.")
                .font(.system(size: 14))
                .foregroundStyle(SkimStyle.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .skimGlass(cornerRadius: 20)
    }

    @ViewBuilder
    private var noReaderTextCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reader text is not available for this article.")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(SkimStyle.text)
            Text("Swipe left for the web view.")
                .font(.system(size: 17))
                .foregroundStyle(SkimStyle.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .skimGlass(cornerRadius: 20)
    }

    // MARK: - Async actions

    private func externalArticleURL(for article: Article) async -> URL? {
        if let externalURL = article.externalURL {
            return externalURL
        }
        guard article.aggregatorKind == .reddit,
              let redditURL = article.commentsURL ?? article.url
        else { return nil }
        return await AggregatorService().fetchRedditExternalURL(from: redditURL)
    }

    private func loadComments(for article: Article) async {
        commentsState = .loading
        let service = AggregatorService()
        // For Reddit self-posts, fetch the post body alongside comments
        if article.aggregatorKind == .reddit {
            async let selftextTask = service.fetchRedditSelftext(for: article)
            async let commentsTask = service.fetchComments(for: article, limit: 10)
            let (fetchedSelftext, fetched) = await (selftextTask, commentsTask)
            redditSelftext = fetchedSelftext
            if let text = ArticleReaderContentLoader.sanitizedText(fetchedSelftext) {
                await model.cacheReaderText(articleID: article.id, url: article.commentsURL ?? article.url, text: text)
            }
            comments = fetched
            commentsState = fetched.isEmpty ? .failed("No comments returned.") : .loaded("")
        } else {
            let fetched = await service.fetchComments(for: article, limit: 10)
            comments = fetched
            commentsState = fetched.isEmpty ? .failed("No comments returned.") : .loaded("")
        }
    }

    private func loadExternalArticle(url: URL, articleID: String) async {
        extractedBody = .loading
        do {
            let loaded = try await ArticleReaderContentLoader.loadText(from: url)
            await model.cacheReaderText(articleID: articleID, url: loaded.url, text: loaded.text)
            extractedBody = .loaded(loaded.text)
        } catch {
            extractedBody = .failed(error.localizedDescription)
        }
    }

    /// Fetch and extract the article body for the reader pane (non-aggregator articles).
    /// Writes result to the persistent reader cache so it survives navigation and app restarts.
    private func loadArticleForReader(url: URL, articleID: String) async {
        extractedBody = .loading
        autoExtractTimedOut = false

        do {
            let loaded = try await ArticleReaderContentLoader.loadText(from: url)
            await model.cacheReaderText(articleID: articleID, url: loaded.url, text: loaded.text)
            extractedBody = .loaded(loaded.text)
        } catch {
            extractedBody = .failed(error.localizedDescription)
        }
    }

    /// Triggered on `.task` for non-aggregator articles. If the RSS body is too thin,
    /// auto-extracts the article URL. Checks the persistent cache first to avoid redundant fetches.
    private func autoExtractIfNeeded(article: Article) async {
        // Already sufficient RSS content — nothing to do
        guard !ArticleReaderContentLoader.isSufficientRSSBody(article) else { return }

        if await loadCachedReaderText(for: article) {
            return
        }

        if let cached = ExtractedContentCache.shared.get(article.id) {
            await model.cacheReaderText(articleID: article.id, url: article.url, text: cached)
            extractedBody = .loaded(cached)
            return
        }

        guard let url = article.url else {
            // No URL to extract from — show static unavailable card
            extractedBody = .failed("No article URL available.")
            return
        }

        // Start auto-extraction
        extractedBody = .loading

        // Race auto-extract against a 3s timeout; if extraction takes longer,
        // reveal the manual "Load Article" fallback button while still waiting.
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            autoExtractTimedOut = true
        }

        await loadArticleForReader(url: url, articleID: article.id)
        timeoutTask.cancel()
    }

    @discardableResult
    private func loadCachedReaderText(for article: Article) async -> Bool {
        guard let cached = await model.cachedReaderText(articleID: article.id),
              !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        ExtractedContentCache.shared.set(article.id, value: cached)
        extractedBody = .loaded(cached)
        return true
    }
}

// MARK: - Comment row

private struct CommentRow: View {
    var comment: AggregatorComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(comment.author)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SkimStyle.accent)
                if let score = comment.score {
                    Text("·")
                        .foregroundStyle(SkimStyle.secondary)
                    Text("\(score) pts")
                        .font(.system(size: 12))
                        .foregroundStyle(SkimStyle.secondary)
                }
            }
            Text(comment.body)
                .font(.system(size: 15))
                .foregroundStyle(SkimStyle.text)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SkimStyle.separator, lineWidth: 0.5)
        }
    }
}

private struct WebPage: View {
    var article: Article?
    @Binding var snapshot: WebViewSnapshot

    var body: some View {
        if let url = article?.url {
            WebView(url: url, snapshot: $snapshot)
                .ignoresSafeArea(edges: .bottom)
        } else {
            ContentUnavailableView("Web page unavailable", systemImage: "globe.badge.chevron.backward")
                .foregroundStyle(SkimStyle.text)
        }
    }
}

private enum WebAIContext {
    private static let minimumUsefulTextLength = 200

    static func article(base: Article, preferWeb: Bool, snapshot: WebViewSnapshot) async throws -> Article {
        guard preferWeb else {
            // Non-web path: if the article body is thin (aggregator/link posts) and
            // there is an externalURL pointing to the real article, fetch and extract it.
            if articleBodyIsThin(base), let externalURL = base.externalURL {
                if let loaded = try? await loadDocument(at: externalURL, fallbackTitle: base.title),
                   loaded.text.count >= minimumUsefulTextLength {
                    // Preserve base.id so chat session keys remain stable.
                    // Preserve base.feedTitle (not "Web View") so provenance is clear.
                    return Article(
                        id: base.id,
                        feedID: base.feedID,
                        feedTitle: base.feedTitle,
                        title: loaded.title?.nilIfEmpty ?? base.title,
                        url: loaded.url,
                        author: base.author,
                        contentText: loaded.text,
                        contentHTML: nil,
                        imageURL: base.imageURL,
                        publishedAt: base.publishedAt,
                        fetchedAt: base.fetchedAt,
                        isRead: base.isRead,
                        isStarred: base.isStarred,
                        aggregatorKind: base.aggregatorKind,
                        externalURL: base.externalURL,
                        commentsURL: base.commentsURL
                    )
                }
            }
            return base
        }

        let contextURL = snapshot.url ?? base.externalURL ?? base.url
        let title = snapshot.title?.nilIfEmpty ?? contextURL?.host(percentEncoded: false) ?? base.title

        if let snapshotText = sanitizedText(snapshot.text), snapshotText.count >= minimumUsefulTextLength {
            return article(base: base, id: articleID(base: base, preferWeb: true, snapshot: snapshot), title: title, url: contextURL, text: snapshotText)
        }

        guard let contextURL else {
            if let snapshotText = sanitizedText(snapshot.text), !snapshotText.isEmpty {
                return article(base: base, id: articleID(base: base, preferWeb: true, snapshot: snapshot), title: title, url: nil, text: snapshotText)
            }
            return base
        }

        let loaded = try await loadDocument(at: contextURL, fallbackTitle: title)
        return article(
            base: base,
            id: articleID(base: base, preferWeb: true, snapshot: snapshot),
            title: loaded.title ?? title,
            url: loaded.url,
            text: loaded.text
        )
    }

    static func articleID(base: Article, preferWeb: Bool, snapshot: WebViewSnapshot) -> String {
        guard preferWeb else { return base.id }
        return "\(base.id)|web|\((snapshot.url ?? base.externalURL ?? base.url)?.absoluteString ?? "current")"
    }

    static func subtitle(base: Article, preferWeb: Bool, snapshot: WebViewSnapshot) -> String {
        guard preferWeb else { return base.title }
        return snapshot.title?.nilIfEmpty
            ?? (snapshot.url ?? base.externalURL ?? base.url)?.absoluteString
            ?? base.title
    }

    private struct LoadedDocument {
        var title: String?
        var url: URL
        var text: String
    }

    private static func article(base: Article, id: String, title: String, url: URL?, text: String) -> Article {
        Article(
            id: id,
            feedID: base.feedID,
            feedTitle: "Web View",
            title: title,
            url: url,
            author: base.author,
            contentText: text,
            contentHTML: nil,
            imageURL: base.imageURL,
            publishedAt: base.publishedAt,
            fetchedAt: base.fetchedAt,
            isRead: base.isRead,
            isStarred: base.isStarred,
            aggregatorKind: base.aggregatorKind,
            externalURL: base.externalURL,
            commentsURL: base.commentsURL
        )
    }

    private static func loadDocument(at url: URL, fallbackTitle: String) async throws -> LoadedDocument {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/pdf;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw WebAIContextError.unavailable("The current web page could not be loaded for AI context.")
        }

        let responseURL = response.url ?? url
        let mimeType = response.mimeType?.lowercased() ?? ""
        if isPDF(url: responseURL, mimeType: mimeType, data: data) {
            guard let text = pdfText(from: data), text.count >= minimumUsefulTextLength else {
                throw WebAIContextError.unavailable("The current PDF did not contain extractable text.")
            }
            return LoadedDocument(title: fallbackTitle, url: responseURL, text: text)
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw WebAIContextError.unavailable("The current web page could not be decoded for AI context.")
        }

        let extracted = (try? ArticleExtractor.extract(from: html, baseURL: responseURL))
            ?? sanitizedText(html.skimPlainText)
            ?? ""
        guard extracted.count >= minimumUsefulTextLength else {
            throw WebAIContextError.unavailable("The current web page did not contain enough readable text for AI context.")
        }
        return LoadedDocument(title: fallbackTitle, url: responseURL, text: extracted)
    }

    private static func sanitizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = ArticleExtractor.sanitizeReaderText(
            text
                .decodingHTMLEntities
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return cleaned.nilIfEmpty
    }

    /// Returns true when the article's readable body text is absent or shorter than
    /// `minimumUsefulTextLength`. Used to detect aggregator/link posts (HN, lobste.rs,
    /// Reddit) whose RSS items carry only a stub and whose real content lives at
    /// `externalURL`.
    private static func articleBodyIsThin(_ base: Article) -> Bool {
        let body = sanitizedText(base.contentText) ?? sanitizedText(base.contentHTML?.skimPlainText)
        guard let body else { return true }
        return body.count < minimumUsefulTextLength
    }

    private static func isPDF(url: URL, mimeType: String, data: Data) -> Bool {
        if mimeType.contains("pdf") || url.pathExtension.lowercased() == "pdf" {
            return true
        }
        return Data(data.prefix(5)) == Data("%PDF-".utf8)
    }

    private static func pdfText(from data: Data) -> String? {
        guard let document = PDFDocument(data: data) else { return nil }
        let pages = (0..<document.pageCount).compactMap { index in
            document.page(at: index)?.string?.nilIfEmpty
        }
        return sanitizedText(pages.joined(separator: "\n\n"))
    }
}

private enum WebAIContextError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            message
        }
    }
}

private extension String {
    var skimPlainText: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .decodingHTMLEntities
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var decodingHTMLEntities: String {
        var decoded = self
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")

        let pattern = #"&#(x?[0-9A-Fa-f]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return decoded }
        let matches = regex.matches(in: decoded, range: NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)).reversed()

        for match in matches {
            guard match.numberOfRanges == 2,
                  let fullRange = Range(match.range(at: 0), in: decoded),
                  let valueRange = Range(match.range(at: 1), in: decoded)
            else { continue }

            let value = decoded[valueRange]
            let radix = value.lowercased().hasPrefix("x") ? 16 : 10
            let scalarText = radix == 16 ? value.dropFirst() : Substring(value)
            guard let codepoint = UInt32(scalarText, radix: radix),
                  let scalar = UnicodeScalar(codepoint)
            else { continue }

            decoded.replaceSubrange(fullRange, with: String(scalar))
        }

        return decoded
    }
}

private extension Article {
    var displayTitle: String {
        title.decodingHTMLEntities
    }

    var displayFeedTitle: String {
        feedTitle.decodingHTMLEntities
    }

    var displayAuthor: String? {
        author?.decodingHTMLEntities.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var displayBody: String {
        let body = contentText?.decodingHTMLEntities.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? contentHTML?.skimPlainText.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let cleaned = body
            .unescapingLiteralEscapes
            .removingReaderBoilerplate
        return ArticleExtractor.sanitizeReaderText(cleaned)
    }

    /// True if the RSS-provided body is long enough and not boilerplate to use directly,
    /// so we skip auto-extraction. Threshold: 200 chars after stripping boilerplate.
    var isSufficientRSSBody: Bool {
        let body = displayBody
        return body.count >= 200 && !body.isRSSBoilerplate
    }
}

private extension String {
    /// Replaces literal two-character escape sequences (backslash-n, backslash-t) with their
    /// actual control characters. This handles content that was double-escaped during JSON
    /// extraction — e.g. a Next.js blob where `\\n` in the JSON source string was stored as
    /// the literal two characters `\` + `n` rather than a real newline.
    var unescapingLiteralEscapes: String {
        replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    var removingReaderBoilerplate: String {
        let normalized = replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let redditPattern = #"^submitted by\s+/u/\S+\s+\[link\]\s+(&\s+)?\[comments\]$"#
        if normalized.range(of: redditPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return ""
        }

        return self
    }

    /// Returns true if this string looks like a stub/teaser rather than real article body.
    /// Used to decide whether to auto-extract even when char count >= threshold.
    var isRSSBoilerplate: Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()

        // Common feed stub patterns
        let stubPatterns: [String] = [
            #"^the post .{0,80} appeared first on"#,       // syndication footers
            #"click (here )?to (read|view|continue)"#,     // "Click here to read more"
            #"read (the )?(full|more|rest|complete)"#,      // "Read the full article"
            #"continue reading"#,
            #"this is a summary"#,
            #"view full (article|post|story)"#,
            #"^<p>\s*</p>$"#,                              // bare empty paragraph
        ]

        for pattern in stubPatterns {
            if normalized.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }
}
