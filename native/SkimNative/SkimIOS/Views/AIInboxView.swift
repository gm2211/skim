import SkimCore
import SwiftUI

// MARK: - Ranked Inbox Item

struct InboxRankedArticle: Identifiable {
    var id: String { article.id }
    var article: Article
    var aiReason: String
    var blendedScore: Double
}

// MARK: - AI Inbox Sheet

/// Replaces the old text-sheet AI Inbox with a navigable ranked article list.
/// Ranking = AI scoring (LLM picks + ordering) blended with taste signals.
struct AIInboxSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var sourceArticles: [Article]

    @State private var isLoading = true
    @State private var rankedItems: [InboxRankedArticle] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else if let errorMessage {
                    errorView(errorMessage)
                } else if rankedItems.isEmpty {
                    emptyView
                } else {
                    articleList
                }
            }
            .background(SkimStyle.chrome.ignoresSafeArea())
            .navigationTitle("AI Inbox")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { articleID in
                ArticleDetailView(articleID: articleID)
                    .environmentObject(model)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await run() }
                    } label: {
                        Label("Run Again", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(isLoading)
                }
            }
            .task { await run() }
        }
    }

    // MARK: - Sub-views

    private var loadingView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .tint(SkimStyle.accent)
                .controlSize(.large)
            Text(NativeAI.loadingStatusLabel(for: model.settings.ai))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SkimStyle.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(SkimStyle.secondary)

            Text(message)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(SkimStyle.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Button("Try Again") {
                Task { await run() }
            }
            .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No articles ranked",
            systemImage: "tray",
            description: Text("Add RSS feeds or refresh to populate AI Inbox.")
        )
        .foregroundStyle(SkimStyle.secondary)
    }

    private var articleList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rankedItems.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: item.article.id) {
                        InboxArticleRow(rank: index + 1, item: item)
                    }
                    .buttonStyle(.plain)

                    if index < rankedItems.count - 1 {
                        Divider()
                            .padding(.leading, 70)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Ranking Logic

    private func run() async {
        isLoading = true
        errorMessage = nil
        rankedItems = []

        do {
            let context = try await model.articlesForAIContext(preferred: sourceArticles)
            guard !context.isEmpty else {
                errorMessage = "No articles available yet. Add RSS feeds or refresh before opening AI Inbox."
                isLoading = false
                return
            }

            // Ask the LLM to rank articles; it returns a text with [N] references in priority order
            let rawText = try await NativeAI.aiInbox(articles: context, settings: model.settings)

            // Parse the LLM output into a ranked id list + reasons
            let parsed = parseInboxResponse(rawText, articles: context)

            // Blend with taste signals
            let profile = model.getPreferenceProfile()
            rankedItems = blendWithTaste(parsed, profile: profile)

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Parse the LLM markdown output: find [N] handles and extract per-article reason lines.
    private func parseInboxResponse(_ text: String, articles: [Article]) -> [InboxRankedArticle] {
        var results: [InboxRankedArticle] = []
        var seenIDs: Set<String> = []

        // Split into lines; each bullet/line may reference one article
        let lines = text.components(separatedBy: .newlines)
        let handlePattern = #"\[(\d{1,3})\]"#
        guard let regex = try? NSRegularExpression(pattern: handlePattern) else {
            return fallbackRanking(articles)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            let matches = regex.matches(in: trimmed, range: nsRange)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: trimmed),
                      let idx = Int(trimmed[range])
                else { continue }
                let zeroBased = idx - 1
                guard articles.indices.contains(zeroBased) else { continue }
                let article = articles[zeroBased]
                guard seenIDs.insert(article.id).inserted else { continue }

                // Extract reason: strip the [N] handle(s) and leading bullets/dashes
                let reason = trimmed
                    .replacingOccurrences(of: #"\[\d{1,3}\]"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^[\-\*\•]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                results.append(InboxRankedArticle(
                    article: article,
                    aiReason: reason.isEmpty ? "Recommended by AI" : reason,
                    blendedScore: Double(articles.count - zeroBased) // LLM order = initial score
                ))
            }
        }

        // If parsing found nothing, fall back to all articles
        return results.isEmpty ? fallbackRanking(articles) : results
    }

    private func fallbackRanking(_ articles: [Article]) -> [InboxRankedArticle] {
        articles.prefix(12).enumerated().map { idx, article in
            InboxRankedArticle(
                article: article,
                aiReason: "Recommended by AI",
                blendedScore: Double(articles.count - idx)
            )
        }
    }

    /// Blend AI scores with taste profile feed weights.
    /// Final score = aiScore * 0.7 + tasteBoost * 0.3
    private func blendWithTaste(_ items: [InboxRankedArticle], profile: PreferenceProfile) -> [InboxRankedArticle] {
        guard profile.signalCount > 0 else { return items }

        let maxAI = items.map(\.blendedScore).max() ?? 1
        return items
            .map { item -> InboxRankedArticle in
                var copy = item
                let aiNorm = maxAI > 0 ? item.blendedScore / maxAI : 0

                // Feed weight in [-1, +1]
                let feedWeight = profile.feedWeights[item.article.feedID] ?? 0

                // Per-article signal if available
                var articleBoost: Double = 0
                if let signal = model.tasteStore.signal(for: item.article.id) {
                    switch signal.priorityOverride {
                    case .pin: articleBoost += 1.5
                    case .hide: articleBoost -= 10 // effectively remove
                    case .none: break
                    }
                    switch signal.rating {
                    case .positive: articleBoost += 0.5
                    case .negative: articleBoost -= 0.5
                    case .neutral: break
                    }
                }

                copy.blendedScore = aiNorm * 0.7 + feedWeight * 0.3 + articleBoost
                return copy
            }
            .filter { $0.blendedScore > -5 } // remove hard-hidden items
            .sorted { $0.blendedScore > $1.blendedScore }
    }
}

// MARK: - Inbox Article Row

private struct InboxArticleRow: View {
    var rank: Int
    var item: InboxRankedArticle

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Rank badge
            Text("\(rank)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(SkimStyle.accent)
                .frame(width: 26, height: 26)
                .background(SkimStyle.accent.opacity(0.12), in: Circle())
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.article.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SkimStyle.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(item.article.feedTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SkimStyle.accent)
                        .lineLimit(1)

                    if let publishedAt = item.article.publishedAt {
                        Text("·")
                            .foregroundStyle(SkimStyle.secondary)
                        Text(publishedAt, style: .relative)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(SkimStyle.secondary)
                    }
                }

                if !item.aiReason.isEmpty {
                    Text(item.aiReason)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SkimStyle.secondary.opacity(0.6))
                .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(SkimStyle.chrome)
        .contentShape(Rectangle())
    }
}
