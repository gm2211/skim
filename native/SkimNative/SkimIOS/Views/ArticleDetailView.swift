import SkimCore
import SwiftUI

private enum DetailPage: String, CaseIterable {
    case reader
    case web
}

struct ArticleDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let articleID: String

    @State private var article: Article?
    @State private var page: DetailPage = .reader
    @State private var isLoading = true
    @State private var activeAIResult: AIResultRequest?
    @State private var activeAIChat: AIChatRequest?

    var body: some View {
        ZStack {
            SkimStyle.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                TabView(selection: $page) {
                    ReaderPage(article: article, isLoading: isLoading)
                        .tag(DetailPage.reader)

                    WebPage(article: article)
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
        .sheet(item: $activeAIChat) { request in
            AIChatSheet(request: request)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
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
            BorderlessIconButton(systemName: "sparkles", title: "Summary", size: 22, tapSize: 40) {
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

    private func load(markRead: Bool) async {
        isLoading = true
        defer { isLoading = false }

        guard var loaded = await model.updatedArticle(id: articleID) else { return }
        if markRead, !loaded.isRead {
            await model.setRead(loaded, isRead: true)
            loaded.isRead = true
        }
        article = loaded
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
        activeAIResult = AIResultRequest(
            title: "AI Summary",
            subtitle: article.title
        ) {
            try await NativeAI.summarize(article: article)
        }
    }

    private func presentArticleChat() {
        guard let article else { return }
        activeAIChat = AIChatRequest(
            title: "Chat with Article",
            placeholder: article.title
        ) { question in
            try await NativeAI.chat(question: question, article: article)
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
            .padding(.horizontal, 38)
            .padding(.top, 16)
            .padding(.bottom, 56)
        }
        .scrollIndicators(.visible)
    }

    private func articleHeader(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(article.title)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(SkimStyle.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 9) {
                Text(article.feedTitle)
                    .foregroundStyle(SkimStyle.accent)
                if let author = article.author, !author.isEmpty {
                    Text("·")
                    Text(author)
                }
                if let publishedAt = article.publishedAt {
                    Text("·")
                    Text(publishedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute()))
                }
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(SkimStyle.secondary)
            .lineLimit(2)
        }
    }

    @ViewBuilder
    private func articleBody(_ article: Article) -> some View {
        let body = article.contentText?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? article.contentHTML?.skimPlainText.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

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
                .font(.system(size: 20, weight: .regular))
                .lineSpacing(8)
                .foregroundStyle(SkimStyle.text)
                .textSelection(.enabled)
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
