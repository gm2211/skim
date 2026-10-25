import PDFKit
import SkimCore
import SwiftUI
import UIKit

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
    @State private var summaryContextBySession: [String: String] = [:]
    @State private var activeSummaryConfiguration: Article?
    @State private var showAIDisclaimerGate = false
    @State private var pendingAIAction: (() -> Void)?
    @State private var webSnapshot = WebViewSnapshot()
    // True while a passage of the reader text is selected, so dragging a
    // selection handle never reads as the swipe-back gesture.
    @State private var hasReaderSelection = false

    // Reading-time tracking
    @State private var openedAt: Date?
    @State private var currentPriorityOverride: ArticlePriorityOverride = .none

    var body: some View {
        ZStack {
            SkimStyle.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                TabView(selection: $page) {
                    // The article menu sits on the header only: a long press on
                    // the body selects text, which can then go to chat.
                    ReaderPage(
                        article: article,
                        isLoading: isLoading,
                        hasTextSelection: $hasReaderSelection,
                        onAskAboutSelection: { presentArticleChat(quote: $0) },
                        headerMenu: { detailContextMenu },
                        headerMenuPreview: { contextMenuPreview }
                    )
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
            model.readerOpened(articleID: articleID)
            if let article {
                let signal = model.tasteStore.signal(for: article.id)
                currentPriorityOverride = signal?.priorityOverride ?? .none
            }
        }
        .onDisappear {
            recordDwell()
            model.readerClosed(articleID: articleID)
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
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(SkimStyle.chrome)
            .onAppear(perform: prewarmLocalModel)
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
                .onAppear(perform: prewarmLocalModel)
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
            title: article.title,
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
        // Seven 42pt targets fit a 375pt-wide iPhone only with tight spacing.
        HStack(spacing: 4) {
            BorderlessIconButton(systemName: "chevron.left", title: "Back", size: 24, tapSize: 42) {
                dismiss()
            }

            Spacer(minLength: 4)

            BorderlessIconButton(systemName: SkimIcon.reader, title: "Reader", isActive: page == .reader, size: 24, tapSize: 42) {
                page = .reader
            }
            BorderlessIconButton(systemName: SkimIcon.web, title: "Web", isActive: page == .web, size: 24, tapSize: 42) {
                page = .web
            }
            BorderlessIconButton(systemName: SkimIcon.summarize, title: "Summarize", size: 24, tapSize: 42) {
                presentSummary()
            }
            BorderlessIconButton(systemName: SkimIcon.chat, title: "Chat", size: 24, tapSize: 42) {
                presentArticleChat()
            }
            BorderlessIconButton(systemName: article?.isStarred == true ? SkimIcon.starFilled : SkimIcon.star, title: article?.isStarred == true ? "Unstar" : "Star", isActive: article?.isStarred == true, size: 24, tapSize: 42) {
                Task { await toggleStar() }
            }
            if let article, let shareURL = article.externalURL ?? article.url {
                // A link post shares the story it points at, not the aggregator page.
                ShareLink(item: shareURL, subject: Text(article.title), preview: SharePreview(article.title)) {
                    Image(systemName: SkimIcon.share)
                        .font(.system(size: 24, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(SkimStyle.secondary)
                .accessibilityLabel("Share")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 76)
    }

    private var readerBackGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard page == .reader,
                      !hasReaderSelection,
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
            Button(article.isRead ? "Mark as Unread" : "Mark as Read", systemImage: article.isRead ? SkimIcon.markUnread : SkimIcon.markRead) {
                Task { await toggleRead() }
            }

            Button(article.isStarred ? "Unstar" : "Star", systemImage: article.isStarred ? SkimIcon.unstar : SkimIcon.star) {
                Task { await toggleStar() }
            }

            Divider()

            Button(
                currentPriorityOverride == .pin ? "Unpin" : "Pin to Top",
                systemImage: currentPriorityOverride == .pin ? SkimIcon.unpin : SkimIcon.pin
            ) {
                applyPriorityOverride(.pin)
            }

            Divider()

            Button("Summarize", systemImage: SkimIcon.summarize) {
                presentSummary()
            }

            Button("Chat with Article", systemImage: SkimIcon.chat) {
                presentArticleChat()
            }

            if let url = article.url {
                Divider()

                Button("Open in Browser", systemImage: SkimIcon.openExternal) {
                    openURL(url)
                }

                ShareLink(item: article.externalURL ?? url, subject: Text(article.title), preview: SharePreview(article.title)) {
                    Label("Share", systemImage: SkimIcon.share)
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

    /// Starts reading the on-device model's weights while the person is
    /// still choosing options or typing, so the first answer starts sooner.
    private func prewarmLocalModel() {
        guard model.settings.ai.provider == "mlx" else { return }
        NativeMLX.prewarm(settings: model.settings.ai)
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
                        snapshot: webSnapshot,
                        store: model.store
                    )
                    let text = try await NativeAI.summarize(article: contextArticle, settings: settings)
                    return AIResultAnswer(text: text, articles: [contextArticle])
                },
                streamAction: { onToken in
                    let contextArticle = try await WebAIContext.article(
                        base: article,
                        preferWeb: useWebContext,
                        snapshot: webSnapshot,
                        store: model.store
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
                    summaryContextBySession[chatSessionKey(base: article, preferWeb: useWebContext, snapshot: webSnapshot)] = summaryText
                    activeAIChat = AIChatRequest(
                        sessionKey: chatSessionKey(base: article, preferWeb: useWebContext, snapshot: webSnapshot),
                        title: "Chat with Article",
                        placeholder: WebAIContext.subtitle(base: article, preferWeb: useWebContext, snapshot: webSnapshot),
                        generatedSummaryContext: summaryText
                    ) { conversation in
                        await model.recordChatMessage(about: article)
                        let contextArticle = try await WebAIContext.article(
                            base: article,
                            preferWeb: useWebContext,
                            snapshot: webSnapshot,
                            store: model.store
                        )
                        let (text, citations) = try await NativeAI.chat(conversation: conversation, article: contextArticle, settings: model.settings)
                        return AIChatAnswer(text: text, articles: [contextArticle], webCitations: citations)
                    }
                }
            )
        }
    }

    private func chatMessagesBinding(for sessionKey: String) -> Binding<[AIChatMessage]> {
        Binding(
            get: { chatMessagesBySession[sessionKey] ?? [] },
            set: { messages in
                chatMessagesBySession[sessionKey] = messages
                if messages.isEmpty { summaryContextBySession.removeValue(forKey: sessionKey) }
            }
        )
    }

    private func chatSessionKey(base article: Article, preferWeb: Bool, snapshot: WebViewSnapshot) -> String {
        WebAIContext.articleID(base: article, preferWeb: preferWeb, snapshot: snapshot)
    }
}

struct SummaryConfigurationSheet: View {
    var article: Article
    var defaults: AISettings
    var onRun: (AISettings) -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAISettings = false
    @State private var style: SummaryStyleOption
    @State private var wordCount: Int
    @State private var customPrompt: String
    @State private var ai: AISettings
    @State private var isCustomizing = false
    @State private var isEditingFocus: Bool
    @FocusState private var isFocusFieldActive: Bool

    /// The settings the last summary ran with (they become the defaults on
    /// every run), offered as the first preset.
    private let lastUsed: SummaryPreset

    init(article: Article, defaults: AISettings, onRun: @escaping (AISettings) -> Void) {
        self.article = article
        self.defaults = defaults
        self.onRun = onRun
        let style = SummaryStyleOption(tone: defaults.summaryTone)
        let wordCount = AIRequestPolicy.summaryWordCount(defaults)
        let prompt = defaults.summaryCustomPrompt ?? ""
        lastUsed = SummaryPreset(id: "again", name: "Again", style: style, wordCount: wordCount, systemImage: "arrow.counterclockwise")
        _style = State(initialValue: style)
        _wordCount = State(initialValue: wordCount)
        _customPrompt = State(initialValue: prompt)
        _ai = State(initialValue: defaults)
        _isEditingFocus = State(initialValue: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// "Again" only shows when the last run differs from every standard preset.
    private var presets: [SummaryPreset] {
        let standard = SummaryPreset.standard
        let repeatsStandard = standard.contains { $0.style == lastUsed.style && $0.wordCount == lastUsed.wordCount }
        return repeatsStandard ? standard : [lastUsed] + standard
    }

    /// First preset matching the current choices; "Again" wins a tie.
    private var selectedPreset: SummaryPreset? {
        presets.first { $0.style == style && $0.wordCount == wordCount }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(article.title)
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(SkimStyle.secondary)
                                .lineLimit(2)

                            SummaryPreviewCard(style: style, wordCount: wordCount)

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Presets")
                                    .summaryControlLabel()
                                presetRow
                            }

                            customizeCard

                            Text("These choices, including the model, are saved as your new defaults when you run.")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(SkimStyle.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 16)
                    }
                    .onChange(of: isFocusFieldActive) { _, isActive in
                        guard isActive else { return }
                        Task { @MainActor in
                            // Wait for the keyboard and the field's reveal to settle,
                            // then lift the whole field clear of the Summarize button.
                            try? await Task.sleep(for: .milliseconds(350))
                            withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(Self.focusFieldID, anchor: .bottom) }
                        }
                    }
                    .onChange(of: customPrompt) {
                        guard isFocusFieldActive else { return }
                        proxy.scrollTo(Self.focusFieldID, anchor: .bottom)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollContentBackground(.hidden)

                    // Outside the ScrollView so content always ends above it,
                    // rather than sliding underneath an inset overlay.
                    runButton
                }
                .background(SkimStyle.chrome.ignoresSafeArea())
                .toolbarBackground(SkimStyle.chrome, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .navigationTitle("Summarize")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    private static let focusFieldID = "summary-focus-field"

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets) { preset in
                    SummaryPresetTile(
                        preset: preset,
                        isSelected: selectedPreset?.id == preset.id,
                        isCompact: isCustomizing
                    ) {
                        withAnimation(.smooth(duration: 0.2)) {
                            style = preset.style
                            wordCount = preset.wordCount
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, -20)
        .sensoryFeedback(.selection, trigger: selectedPreset?.id)
    }

    private var customizeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { isCustomizing.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Customize")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(SkimStyle.text)
                    Spacer(minLength: 8)
                    if !isCustomizing {
                        Text(customizeSummary)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(SkimStyle.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SkimStyle.secondary)
                        .rotationEffect(.degrees(isCustomizing ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isCustomizing ? "Hides style, length, model and focus" : "Shows style, length, model and focus")

            if isCustomizing {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 6) {
                        ForEach(SummaryStyleOption.allCases) { option in
                            SummaryStyleChip(option: option, isSelected: style == option) {
                                withAnimation(.smooth(duration: 0.2)) { style = option }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Length")
                                .summaryControlLabel()
                            Spacer()
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(wordCount)")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(SkimStyle.text)
                                    .monospacedDigit()
                                Text("words")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(SkimStyle.secondary)
                            }
                        }
                        SummaryLengthRuler(wordCount: $wordCount)
                            .padding(.horizontal, -14)
                    }

                    HStack(spacing: 8) {
                        ModelPickerMenu(ai: $ai, onOpenSettings: { showAISettings = true })
                            .sheet(isPresented: $showAISettings, onDismiss: {
                                // Pick up a provider or model changed in settings;
                                // style, length and focus live in their own state.
                                ai = model.settings.ai
                            }) {
                                SettingsSheet(isPresented: $showAISettings, aiOnly: true)
                            }
                        if !isEditingFocus {
                            Button {
                                withAnimation(.smooth(duration: 0.2)) { isEditingFocus = true }
                                isFocusFieldActive = true
                            } label: {
                                Label("Focus", systemImage: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SkimStyle.accent)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 36)
                                    .background(SkimStyle.surface, in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }

                    if isEditingFocus {
                        TextField("Focus on tradeoffs, risks, key takeaways...", text: $customPrompt, axis: .vertical)
                            .focused($isFocusFieldActive)
                            .lineLimit(3...6)
                            .textInputAutocapitalization(.sentences)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(SkimStyle.text)
                            .padding(12)
                            .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(SkimStyle.separator, lineWidth: 1)
                            }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(SkimStyle.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SkimStyle.separator, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Scroll target for the Focus field: the whole card plus a gap, so the
        // card's bottom edge stays visible above the Summarize button instead
        // of the field sitting flush against it. The negative padding keeps
        // the gap out of the layout.
        .padding(.bottom, 12)
        .id(Self.focusFieldID)
        .padding(.bottom, -12)
    }

    private var customizeSummary: String {
        let model = ModelCatalog.currentLabel(ai)
        return customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? model : "\(model) · Focus"
    }

    private var runCaption: String {
        if let preset = selectedPreset, preset.id != lastUsed.id { return preset.name }
        return "\(style.label) · \(wordCount) words"
    }

    private var runButton: some View {
        Button {
            onRun(configuredSettings)
        } label: {
            HStack(spacing: 6) {
                Text("Summarize")
                    .fontWeight(.bold)
                Text("· \(runCaption)")
                    .fontWeight(.medium)
                    .opacity(0.72)
                    .lineLimit(1)
            }
            .font(.system(size: 17))
            .foregroundStyle(Color(red: 0.02, green: 0.06, blue: 0.12))
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(SkimStyle.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Summarize, \(style.label), \(wordCount) words")
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(SkimStyle.chrome)
    }

    private var configuredSettings: AISettings {
        var next = AIRequestPolicy.summarySettings(ai, wordCount: wordCount)
        next.summaryTone = style.rawValue
        next.summaryCustomPrompt = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return next
    }
}

// MARK: - Summary configuration parts

private enum SummaryStyleOption: String, CaseIterable, Identifiable {
    case concise, descriptive, casual, technical

    init(tone: String?) {
        self = SummaryStyleOption(rawValue: tone ?? "") ?? .concise
    }

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// What the voice reads like. Illustrative copy, not generated, so the
    /// preview never spends tokens.
    var sample: String {
        switch self {
        case .concise: "Straight to the point: the main claim, the evidence, and why it matters."
        case .descriptive: "A fuller account that walks through the context, the argument and the details behind it."
        case .casual: "Here's the deal in plain words, like a friend catching you up over coffee."
        case .technical: "Precise terms, figures and mechanisms kept intact, with nothing simplified away."
        }
    }
}

private struct SummaryPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let style: SummaryStyleOption
    let wordCount: Int
    var systemImage: String? = nil

    static let standard: [SummaryPreset] = [
        SummaryPreset(id: "gist", name: "Gist", style: .concise, wordCount: 30),
        SummaryPreset(id: "briefing", name: "Briefing", style: .concise, wordCount: 150),
        SummaryPreset(id: "explainer", name: "Explainer", style: .descriptive, wordCount: 300),
        SummaryPreset(id: "deep-dive", name: "Deep dive", style: .technical, wordCount: 600),
    ]

    var detail: String { "\(style.label) · \(wordCount)" }

    /// 1–4 bars, a glanceable sense of length.
    var level: Int {
        switch wordCount {
        case ..<100: 1
        case ..<250: 2
        case ..<500: 3
        default: 4
        }
    }
}

private struct SummaryPresetTile: View {
    var preset: SummaryPreset
    var isSelected: Bool
    var isCompact: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                if !isCompact {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<4, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(index < preset.level ? SkimStyle.accent : SkimStyle.separator)
                                .frame(width: 4, height: 5 + CGFloat(index) * 4.3)
                        }
                    }
                    .frame(height: 18, alignment: .bottom)
                    Spacer(minLength: 6)
                }
                HStack(spacing: 4) {
                    if let systemImage = preset.systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text(preset.name)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(SkimStyle.text)
                Text(preset.detail)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.top, 1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(width: 124, height: isCompact ? 56 : 92, alignment: .leading)
            .background(
                isSelected
                    ? AnyShapeStyle(LinearGradient(colors: [SkimStyle.accent.opacity(0.18), SkimStyle.accent.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(SkimStyle.surface),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? SkimStyle.accent : SkimStyle.separator, lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name), \(preset.style.label), \(preset.wordCount) words")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SummaryStyleChip: View {
    var option: SummaryStyleOption
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(option.label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isSelected ? Color(red: 0.02, green: 0.06, blue: 0.12) : SkimStyle.text)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(isSelected ? SkimStyle.accent : SkimStyle.surface, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Shows the shape of the summary before it runs: the chosen voice and a
/// rough length. Nothing here is generated.
private struct SummaryPreviewCard: View {
    var style: SummaryStyleOption
    var wordCount: Int

    private static let visibleLines = 4
    private static let widths: [CGFloat] = [0.96, 0.88, 0.93, 0.74]

    /// About one skeleton line per 75 words.
    private var lineCount: Int { max(1, Int((Double(wordCount) / 75).rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Preview")
                    .summaryControlLabel()
                Spacer()
                Text("\(style.label) · \(wordCount) words")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(SkimStyle.accent)
                    .monospacedDigit()
            }
            Text(style.sample)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(SkimStyle.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0..<min(lineCount, Self.visibleLines), id: \.self) { index in
                        let isLast = index == lineCount - 1
                        Capsule()
                            .fill(SkimStyle.separator)
                            .frame(width: geo.size.width * (isLast ? 0.55 : Self.widths[index]), height: 8)
                    }
                }
            }
            .frame(height: CGFloat(Self.visibleLines) * 15 - 7, alignment: .top)
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: 0.6), .init(color: .black.opacity(lineCount > Self.visibleLines ? 0 : 1), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SkimStyle.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(SkimStyle.separator, lineWidth: 1)
        }
        .animation(.smooth(duration: 0.2), value: lineCount)
        .accessibilityElement(children: .combine)
    }
}

/// A scrubbable ruler: drag sideways to set any length in 25-word steps
/// across `AIRequestPolicy.summaryWordRange`.
private struct SummaryLengthRuler: View {
    @Binding var wordCount: Int
    @State private var dragStart: Int?

    private let step = 25
    private let spacing: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            let mid = size.width / 2
            let baseline = size.height - 16
            let span = Int(mid / spacing) + 2
            var word = (wordCount / step - span) * step
            while word <= wordCount + span * step {
                defer { word += step }
                guard AIRequestPolicy.summaryWordRange.contains(word) else { continue }
                let x = mid + CGFloat(word - wordCount) / CGFloat(step) * spacing
                guard x > 2, x < size.width - 2 else { continue }
                let isMajor = word % 100 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: baseline))
                tick.addLine(to: CGPoint(x: x, y: baseline - (isMajor ? 20 : 10)))
                context.stroke(tick, with: .color(Color(red: 0.23, green: 0.26, blue: 0.31)), lineWidth: 2)
                if isMajor, word != AIRequestPolicy.summaryWordRange.upperBound, abs(x - mid) > 18 {
                    context.draw(
                        Text("\(word)").font(.system(size: 11)).foregroundStyle(SkimStyle.secondary),
                        at: CGPoint(x: x, y: size.height - 6)
                    )
                }
            }
            // End stops mark the shortest and longest allowed lengths, so the
            // empty stretch past either end reads as the edge of the scale.
            for bound in [AIRequestPolicy.summaryWordRange.lowerBound, AIRequestPolicy.summaryWordRange.upperBound] {
                let x = mid + CGFloat(bound - wordCount) / CGFloat(step) * spacing
                guard x > 2, x < size.width - 2 else { continue }
                var stop = Path()
                stop.move(to: CGPoint(x: x, y: baseline))
                stop.addLine(to: CGPoint(x: x, y: baseline - 26))
                context.stroke(stop, with: .color(SkimStyle.secondary), lineWidth: 2)
                if abs(x - mid) > 18 {
                    context.draw(
                        Text(bound == AIRequestPolicy.summaryWordRange.lowerBound ? "min" : "max")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(SkimStyle.secondary),
                        at: CGPoint(x: x, y: size.height - 6)
                    )
                }
            }
            let indicator = Path(roundedRect: CGRect(x: mid - 1.5, y: baseline - 34, width: 3, height: 38), cornerRadius: 1.5)
            context.fill(indicator, with: .color(SkimStyle.accent))
        }
        .frame(height: 52)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let start = dragStart ?? wordCount
                    if dragStart == nil { dragStart = start }
                    let steps = Int((-value.translation.width / spacing).rounded())
                    guard steps != 0 else { return }
                    wordCount = Self.clamped(start + steps * step, step: step)
                }
                .onEnded { _ in dragStart = nil }
        )
        .sensoryFeedback(.selection, trigger: wordCount)
        .accessibilityElement()
        .accessibilityLabel("Length")
        .accessibilityValue("\(wordCount) words")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: wordCount = Self.clamped(wordCount + step, step: step)
            case .decrement: wordCount = Self.clamped(wordCount - step, step: step)
            @unknown default: break
            }
        }
    }

    /// Snap to the 25-word grid, then keep inside the allowed range.
    private static func clamped(_ value: Int, step: Int) -> Int {
        let range = AIRequestPolicy.summaryWordRange
        let snapped = Int((Double(value) / Double(step)).rounded()) * step
        return min(range.upperBound, max(range.lowerBound, snapped))
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
    /// Opens the article chat. `quote` is a passage highlighted in the reader;
    /// the chat then opens with it quoted, ready for a question about it.
    func presentArticleChat(quote: String? = nil) {
        guard let article else { return }
        let useWebContext = quote == nil && page == .web
        let webSnapshot = webSnapshot
        gatedAI {
            activeAIChat = AIChatRequest(
                sessionKey: chatSessionKey(base: article, preferWeb: useWebContext, snapshot: webSnapshot),
                title: useWebContext ? "Chat with Web Page" : "Chat with Article",
                placeholder: WebAIContext.subtitle(base: article, preferWeb: useWebContext, snapshot: webSnapshot),
                generatedSummaryContext: summaryContextBySession[chatSessionKey(base: article, preferWeb: useWebContext, snapshot: webSnapshot)],
                initialArticleQuote: quote
            ) { conversation in
                await model.recordChatMessage(about: article)
                let contextArticle = try await WebAIContext.article(
                    base: article,
                    preferWeb: useWebContext,
                    snapshot: webSnapshot,
                    store: model.store
                )
                let (text, citations) = try await NativeAI.chat(conversation: conversation, article: contextArticle, settings: model.settings)
                return AIChatAnswer(text: text, articles: [contextArticle], webCitations: citations)
            }
        }
    }
}

private extension AggregatorKind {
    var siteName: String {
        switch self {
        case .hackerNews: "Hacker News"
        case .reddit: "Reddit"
        case .lobsters: "Lobsters"
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

private struct ReaderPage<HeaderMenu: View, HeaderMenuPreview: View>: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    var article: Article?
    var isLoading: Bool
    @Binding var hasTextSelection: Bool
    var onAskAboutSelection: (String) -> Void
    @ViewBuilder var headerMenu: () -> HeaderMenu
    @ViewBuilder var headerMenuPreview: () -> HeaderMenuPreview

    @State private var comments: [AggregatorComment] = []
    @State private var commentsState: ArticleLoadState = .idle
    // Top-level threads shown; "Show more comments" reveals the next page.
    @State private var visibleThreadCount = ReaderPage.threadsPerPage
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
                        .contentShape(Rectangle())
                        .contextMenu(menuItems: headerMenu, preview: headerMenuPreview)
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
            visibleThreadCount = ReaderPage.threadsPerPage
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
                Text(article.aggregatorSourceLabel ?? article.displayFeedTitle)
                    .foregroundStyle(SkimStyle.accent)

                HStack(spacing: 7) {
                    if let author = article.aggregatorSubmitter ?? article.displayAuthor {
                        Text(author)
                    }
                    if (article.aggregatorSubmitter ?? article.displayAuthor) != nil, article.publishedAt != nil {
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

    /// Purpose-built layout for Reddit, Hacker News and Lobsters: the post's own
    /// text, the story it links to (a full card until a reader copy is ready,
    /// then a one-line source row above it), and the discussion. Raw feed HTML
    /// and extraction errors never show here.
    @ViewBuilder
    private func aggregatorSection(_ article: Article) -> some View {
        let externalURL = article.externalURL ?? resolvedExternalURL

        VStack(alignment: .leading, spacing: 24) {
            if let selftext = redditSelftext {
                readerText(selftext)
            }

            if redditSelftext == nil, let externalURL {
                if case .loaded(let text) = extractedBody {
                    linkSourceRow(url: externalURL)
                    readerText(text)
                } else {
                    linkCard(url: externalURL, article: article)
                }
            } else if redditSelftext == nil, case .loaded(let text) = extractedBody {
                // A self post's text saved for offline reading.
                readerText(text)
            }

            discussionSection(article)
        }
    }

    private func linkPath(_ url: URL) -> String? {
        var path = url.path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? nil : path
    }

    private func linkDomain(_ url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func siteBadge(_ url: URL) -> some View {
        Text(linkDomain(url).prefix(1).uppercased())
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(SkimStyle.secondary)
            .frame(width: 24, height: 24)
            .background(SkimStyle.separator, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Compact row shown above the extracted story.
    private func linkSourceRow(url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                siteBadge(url)
                VStack(alignment: .leading, spacing: 2) {
                    Text(linkDomain(url))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SkimStyle.text)
                    if let path = linkPath(url) {
                        Text(path)
                            .font(.system(size: 12))
                            .foregroundStyle(SkimStyle.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Label("Original", systemImage: SkimIcon.openExternal)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SkimStyle.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(SkimStyle.separator, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open the original on \(linkDomain(url))")
    }

    /// The linked story as the page's centerpiece while no reader copy exists.
    private func linkCard(url: URL, article: Article) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let imageURL = article.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 190)
                            .clipped()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    siteBadge(url)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(linkDomain(url))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SkimStyle.text)
                        if let path = linkPath(url) {
                            Text(path)
                                .font(.system(size: 12))
                                .foregroundStyle(SkimStyle.secondary)
                        }
                    }
                    .lineLimit(1)
                }

                Button {
                    openURL(url)
                } label: {
                    Label("Read on \(linkDomain(url))", systemImage: SkimIcon.openExternal)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(SkimStyle.background)
                        .background(SkimStyle.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                switch extractedBody {
                case .failed:
                    HStack(spacing: 12) {
                        Text("This site doesn't offer a reader copy, so it opens in your browser.")
                            .font(.system(size: 13))
                            .foregroundStyle(SkimStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Try again") {
                            Task { await loadExternalArticle(url: url, articleID: article.id) }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SkimStyle.accent)
                    }
                case .loaded:
                    EmptyView()
                case .idle, .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Getting a reader copy…")
                            .font(.system(size: 13))
                            .foregroundStyle(SkimStyle.secondary)
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SkimStyle.separator, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func discussionSection(_ article: Article) -> some View {
        let discussionURL = article.commentsURL ?? article.url
        let siteName = article.aggregatorKind?.siteName ?? "the web"

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Discussion")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(SkimStyle.text)
                Spacer()
                if let discussionURL {
                    Button {
                        openURL(discussionURL)
                    } label: {
                        Label("Open on \(siteName)", systemImage: SkimIcon.openExternal)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(SkimStyle.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .overlay {
                                Capsule().stroke(SkimStyle.separator, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)

            Rectangle().fill(SkimStyle.separator).frame(height: 1)

            switch commentsState {
            case .idle, .loading:
                VStack(alignment: .leading, spacing: 18) {
                    ForEach([0.9, 0.7, 0.8], id: \.self) { width in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(SkimStyle.separator).frame(width: 90, height: 9)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 3).fill(SkimStyle.surface).frame(width: proxy.size.width * width, height: 11)
                            }
                            .frame(height: 11)
                        }
                    }
                }
                .padding(.top, 16)
                .accessibilityLabel("Loading comments")
            case .failed:
                if let discussionURL {
                    Button {
                        openURL(discussionURL)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: SkimIcon.discussion)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(SkimStyle.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Read the conversation on \(siteName)")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(SkimStyle.text)
                                Text("Comments open in your browser")
                                    .font(.system(size: 13))
                                    .foregroundStyle(SkimStyle.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: SkimIcon.openExternal)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SkimStyle.secondary)
                        }
                        .padding(14)
                        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(SkimStyle.separator, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                }
            case .loaded:
                let threads = AggregatorCommentThread.threads(from: comments)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(threads.prefix(visibleThreadCount).enumerated()), id: \.element.id) { index, thread in
                        if index > 0 {
                            Rectangle().fill(SkimStyle.separator.opacity(0.6)).frame(height: 0.5)
                        }
                        CommentThreadView(thread: thread, onAsk: onAskAboutSelection, onSelectionChange: { if hasTextSelection != $0 { hasTextSelection = $0 } })
                            .padding(.vertical, 14)
                    }
                }
                if threads.count > visibleThreadCount {
                    Button {
                        visibleThreadCount += ReaderPage.threadsPerPage
                    } label: {
                        Text("Show more comments")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(SkimStyle.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(SkimStyle.separator, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                }
                if let discussionURL {
                    Button {
                        openURL(discussionURL)
                    } label: {
                        Label("Join the discussion on \(siteName)", systemImage: SkimIcon.openExternal)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(SkimStyle.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            }
        }
    }

    // MARK: - Standard body

    /// Article text a reader can highlight; "Ask in Chat" in the selection
    /// menu sends the passage to the article chat.
    private func readerText(_ text: String) -> some View {
        ReaderSelectableText(
            text: text,
            fontSize: 19,
            lineSpacing: 7,
            onAsk: onAskAboutSelection,
            onSelectionChange: { if hasTextSelection != $0 { hasTextSelection = $0 } }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func articleBody(_ article: Article) -> some View {
        let rssFeedBody = ArticleReaderContentLoader.displayBody(for: article)

        // Determine the body to display:
        // 1. Use a cached extracted body if one exists.
        // 2. Use the RSS body if it meets the threshold and isn't boilerplate.
        // 3. Otherwise, show state based on auto-extract progress.
        if case .loaded(let text) = extractedBody {
            readerText(text)
        } else if ArticleReaderContentLoader.isSufficientRSSBody(article) {
            readerText(rssFeedBody)
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

    /// Top-level threads fetched per discussion, shown a page at a time.
    static var commentFetchLimit: Int { 30 }
    static var threadsPerPage: Int { 8 }

    private func loadComments(for article: Article) async {
        commentsState = .loading
        let service = AggregatorService()
        // For Reddit self-posts, fetch the post body alongside comments
        if article.aggregatorKind == .reddit {
            async let selftextTask = service.fetchRedditSelftext(for: article)
            async let commentsTask = service.fetchComments(for: article, limit: ReaderPage.commentFetchLimit)
            let (fetchedSelftext, fetched) = await (selftextTask, commentsTask)
            redditSelftext = fetchedSelftext
            if let text = ArticleReaderContentLoader.sanitizedText(fetchedSelftext) {
                await model.cacheReaderText(articleID: article.id, url: article.commentsURL ?? article.url, text: text)
            }
            comments = fetched
            commentsState = fetched.isEmpty ? .failed("No comments returned.") : .loaded("")
        } else {
            let fetched = await service.fetchComments(for: article, limit: ReaderPage.commentFetchLimit)
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

/// A comment and its replies. Top-level comments open with their direct
/// replies showing; deeper levels stay folded behind a "N replies" toggle so a
/// long thread doesn't bury the next top-level comment.
private struct CommentThreadView: View {
    var thread: AggregatorCommentThread
    var onAsk: ((String) -> Void)? = nil
    var onSelectionChange: (Bool) -> Void = { _ in }
    @State private var expanded: Bool

    init(thread: AggregatorCommentThread, onAsk: ((String) -> Void)? = nil, onSelectionChange: @escaping (Bool) -> Void = { _ in }) {
        self.thread = thread
        self.onAsk = onAsk
        self.onSelectionChange = onSelectionChange
        _expanded = State(initialValue: thread.comment.depth == 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CommentRow(comment: thread.comment, onAsk: onAsk, onSelectionChange: onSelectionChange)
            if !thread.replies.isEmpty {
                if expanded {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(thread.replies) { reply in
                            // AnyView breaks the recursive opaque type.
                            AnyView(CommentThreadView(thread: reply, onAsk: onAsk, onSelectionChange: onSelectionChange))
                        }
                    }
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(SkimStyle.separator).frame(width: 2)
                    }
                } else {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { expanded = true }
                    } label: {
                        Label(thread.replyCount == 1 ? "1 reply" : "\(thread.replyCount) replies", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(SkimStyle.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommentRow: View {
    var comment: AggregatorComment
    var onAsk: ((String) -> Void)? = nil
    var onSelectionChange: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(comment.author)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SkimStyle.secondary)
                if let score = comment.score {
                    Label("\(score)", systemImage: "arrowshape.up.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SkimStyle.secondary.opacity(0.8))
                }
            }
            ReaderSelectableText(
                text: comment.body,
                fontSize: 16,
                lineSpacing: 4,
                onAsk: onAsk,
                onSelectionChange: onSelectionChange
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Selectable reader text

/// Reader text on a UITextView: on iOS, SwiftUI `Text` with text selection can
/// only copy a whole block, while this lets the reader highlight any passage.
/// The selection menu leads with "Ask in Chat", which hands the passage over.
private struct ReaderSelectableText: UIViewRepresentable {
    var text: String
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var onAsk: ((String) -> Void)?
    var onSelectionChange: (Bool) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.dataDetectorTypes = []
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onAsk = onAsk
        context.coordinator.onSelectionChange = onSelectionChange
        let style = "\(fontSize)/\(lineSpacing)"
        guard view.text != text || context.coordinator.renderedStyle != style else { return }
        context.coordinator.renderedStyle = style
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        view.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor(SkimStyle.text),
            .paragraphStyle: paragraph,
        ])
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onAsk: onAsk, onSelectionChange: onSelectionChange) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onAsk: ((String) -> Void)?
        var onSelectionChange: (Bool) -> Void
        var renderedStyle = ""

        init(onAsk: ((String) -> Void)?, onSelectionChange: @escaping (Bool) -> Void) {
            self.onAsk = onAsk
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            onSelectionChange(textView.selectedRange.length > 0)
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            menu(for: textView, suggestedActions: suggestedActions)
        }

        func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue], suggestedActions: [UIMenuElement]) -> UIMenu? {
            menu(for: textView, suggestedActions: suggestedActions)
        }

        private func menu(for textView: UITextView, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let onAsk, textView.selectedRange.length > 0 else { return UIMenu(children: suggestedActions) }
            let ask = UIAction(title: "Ask in Chat", image: UIImage(systemName: SkimIcon.chat)) { [weak textView] _ in
                guard let textView, let selection = textView.selectedTextRange,
                      let quote = textView.text(in: selection)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !quote.isEmpty else { return }
                textView.selectedTextRange = nil
                self.onSelectionChange(false)
                onAsk(quote)
            }
            return UIMenu(children: [ask] + suggestedActions)
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

enum WebAIContext {
    private static let minimumUsefulTextLength = 200

    static func article(base: Article, preferWeb: Bool, snapshot: WebViewSnapshot, store: SkimStore) async throws -> Article {
        guard preferWeb else {
            return try await ArticleReaderContentLoader.aiEvidence(for: base, store: store)
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

    /// "r/technology" for Reddit posts, the site name for other aggregators.
    var aggregatorSourceLabel: String? {
        guard let kind = aggregatorKind else { return nil }
        if kind == .reddit {
            for candidate in [commentsURL, url].compactMap({ $0 }) {
                let parts = candidate.pathComponents
                if let index = parts.firstIndex(where: { $0.lowercased() == "r" }), index + 1 < parts.count {
                    return "r/\(parts[index + 1])"
                }
            }
        }
        return kind.siteName
    }

    /// "u/name" on Reddit; the plain user name elsewhere.
    var aggregatorSubmitter: String? {
        guard let kind = aggregatorKind, var name = displayAuthor else { return nil }
        for prefix in ["/u/", "u/"] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        guard !name.isEmpty else { return nil }
        return kind == .reddit ? "u/\(name)" : name
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
