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
    @State private var activeSummaryConfiguration: Article?
    @State private var showAIDisclaimerGate = false
    @State private var pendingAIAction: (() -> Void)?

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
                        .contextMenu { detailContextMenu }
                        .tag(DetailPage.reader)

                    WebPage(article: article)
                        .contextMenu { detailContextMenu }
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
            AIChatSheet(request: request)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
            await model.setRead(loaded, isRead: true)
            loaded.isRead = true
        }
        article = loaded

        // Sync taste state from persisted signals
        let signal = model.tasteStore.signal(for: loaded.id)
        currentPriorityOverride = signal?.priorityOverride ?? .none
    }

    private func toggleRead() async {
        guard var article else { return }
        let next = !article.isRead
        await model.setRead(article, isRead: next)
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

        Task {
            await model.saveSettings(settings)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            activeAIResult = AIResultRequest(
                title: "AI Summary",
                subtitle: article.title,
                statusLabel: NativeAI.loadingStatusLabel(for: settings.ai),
                action: {
                    let text = try await NativeAI.summarize(article: article, settings: settings)
                    return AIResultAnswer(text: text, articles: [article])
                },
                clearAction: {
                    NativeAI.clearSummaryCache(articleID: article.id, ai: settings.ai)
                }
            )
        }
    }
}

private struct SummaryConfigurationSheet: View {
    var article: Article
    var defaults: AISettings
    var onRun: (AISettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var style: String
    @State private var length: String
    @State private var maxWords: String
    @State private var customPrompt: String

    init(article: Article, defaults: AISettings, onRun: @escaping (AISettings) -> Void) {
        self.article = article
        self.defaults = defaults
        self.onRun = onRun
        _style = State(initialValue: defaults.summaryTone ?? "concise")
        _length = State(initialValue: defaults.summaryLength ?? "short")
        _maxWords = State(initialValue: defaults.summaryCustomWordCount.map(String.init) ?? "")
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
                        Picker("Length", selection: $length) {
                            Text("Tiny").tag("tiny")
                            Text("Short").tag("short")
                            Text("Medium").tag("medium")
                            Text("Long").tag("long")
                        }
                        .pickerStyle(.segmented)

                        TextField("Optional max words", text: $maxWords)
                            .keyboardType(.numberPad)
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(SkimStyle.text)
                            .padding(.horizontal, 14)
                            .frame(height: 46)
                            .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(SkimStyle.separator, lineWidth: 1)
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
        next.summaryLength = length
        next.summaryCustomWordCount = normalizedWordCount
        next.summaryCustomPrompt = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return next
    }

    private var normalizedWordCount: Int? {
        let trimmed = maxWords.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let words = Int(trimmed), words > 0 else { return nil }
        return min(words, 900)
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
        gatedAI {
            activeAIChat = AIChatRequest(
                title: "Chat with Article",
                placeholder: article.title
            ) { question in
                let text = try await NativeAI.chat(question: question, article: article, settings: model.settings)
                return AIChatAnswer(text: text, articles: [article])
            }
        }
    }
}

private struct ReaderPage: View {
    var article: Article?
    var isLoading: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if isLoading && article == nil {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else if let article {
                    articleHeader(article)
                    articleBody(article)
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
    }

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

    @ViewBuilder
    private func articleBody(_ article: Article) -> some View {
        let body = article.displayBody

        if body.isEmpty {
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
        } else {
            Text(body)
                .font(.system(size: 19, weight: .regular))
                .lineSpacing(7)
                .foregroundStyle(SkimStyle.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WebPage: View {
    var article: Article?

    var body: some View {
        if let url = article?.url {
            WebView(url: url)
                .ignoresSafeArea(edges: .bottom)
        } else {
            ContentUnavailableView("Web page unavailable", systemImage: "globe.badge.chevron.backward")
                .foregroundStyle(SkimStyle.text)
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
        return body
            .unescapingLiteralEscapes
            .removingReaderBoilerplate
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
}
