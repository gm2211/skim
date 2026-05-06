import SkimCore
import SwiftUI

// MARK: - Request model

struct CatchUpRequest: Identifiable {
    let id = UUID()
    var subtitle: String
    var statusLabel: String
    var action: () async throws -> CatchUpResult
}

struct CatchUpResult {
    var items: [NativeAI.CatchUpItem]
    var fallbackText: String?
    var articles: [Article]
}

// MARK: - Main sheet

struct CatchUpSheet: View {
    var request: CatchUpRequest
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var items: [NativeAI.CatchUpItem] = []
    @State private var fallbackText: String?
    @State private var articles: [Article] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AIDisclaimerLabel()
                        .padding(.bottom, 2)

                    Text(request.subtitle)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)

                    if isLoading {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(SkimStyle.accent)
                            Text(request.statusLabel)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(SkimStyle.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Color.red.opacity(0.92))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    } else if !items.isEmpty {
                        CatchUpItemList(items: items, articles: articles)

                    } else if let fallbackText {
                        // Structured parse failed — render plain AI text as before
                        CatchUpFallbackText(fallbackText)
                    }
                }
                .padding(24)
            }
            .background(SkimStyle.chrome.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("Quick Catch-up")
            .navigationDestination(for: String.self) { articleID in
                ArticleDetailView(articleID: articleID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Run Again") { Task { await run() } }
                        .disabled(isLoading)
                }
            }
            .task { await run() }
        }
    }

    private func run() async {
        isLoading = true
        errorMessage = nil
        items = []
        fallbackText = nil
        articles = []
        do {
            let result = try await request.action()
            items = result.items
            fallbackText = result.fallbackText
            articles = result.articles
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Tappable item list

private struct CatchUpItemList: View {
    var items: [NativeAI.CatchUpItem]
    var articles: [Article]

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                CatchUpItemRow(item: item, article: resolvedArticle(for: item))
            }
        }
    }

    private func resolvedArticle(for item: NativeAI.CatchUpItem) -> Article? {
        guard let index = item.articleIndex else { return nil }
        let zeroBased = index - 1
        guard articles.indices.contains(zeroBased) else { return nil }
        return articles[zeroBased]
    }
}

private struct CatchUpItemRow: View {
    var item: NativeAI.CatchUpItem
    var article: Article?

    var body: some View {
        Group {
            if let article {
                NavigationLink(value: article.id) {
                    rowContent(tappable: true)
                }
                .buttonStyle(.plain)
            } else {
                rowContent(tappable: false)
            }
        }
    }

    private func rowContent(tappable: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(SkimStyle.text)
                    .lineLimit(2)

                Text(item.summary)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineSpacing(2)
                    .lineLimit(3)

                if let feed = article?.feedTitle {
                    Text(feed)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SkimStyle.accent.opacity(0.85))
                        .lineLimit(1)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 4)

            if tappable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SkimStyle.secondary.opacity(0.6))
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SkimStyle.separator.opacity(tappable ? 0.5 : 0.3), lineWidth: 1)
        }
        .accessibilityLabel(item.title + (tappable ? ". Tap to open article." : ""))
    }
}

// MARK: - Fallback plain text

private struct CatchUpFallbackText: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(formattedText)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(SkimStyle.text)
            .lineSpacing(5)
            .textSelection(.enabled)
    }

    private var formattedText: AttributedString {
        if let parsed = try? AttributedString(markdown: text) {
            return parsed
        }
        return AttributedString(text)
    }
}
