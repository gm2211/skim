import SkimCore
import SwiftUI

// MARK: - Ranked Inbox Item

struct InboxRankedArticle: Identifiable {
    var id: String { article.id }
    var article: Article
    /// nil until the AI has rated the article.
    var rating: InboxAIScore?
    var score: Double
}

// MARK: - AI Inbox

/// Unread articles ranked most relevant and important first. The AI rates each
/// article once on importance and relevance; taste learned on this device from
/// reading time, saves, pins and dismissals re-ranks on every visit.
struct AIInboxView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Most articles rated per visit, so a big backlog doesn't stall the page.
    private static let ratingsPerVisit = 60

    @State private var items: [InboxRankedArticle] = []
    @State private var isLoading = true
    @State private var ratingStatus: String?
    @State private var errorMessage: String?
    @State private var ratingTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header

            if isLoading && items.isEmpty {
                ProgressView()
                    .tint(SkimStyle.accent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Inbox zero",
                    systemImage: "tray",
                    description: Text("No unread articles. Refresh your feeds to fill the AI Inbox.")
                )
                .foregroundStyle(SkimStyle.secondary)
                .frame(maxHeight: .infinity)
            } else {
                articleList
            }
        }
        .background(SkimStyle.background.ignoresSafeArea())
        .foregroundStyle(SkimStyle.text)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        // Re-rank on every return (e.g. from an article) so new taste shows up.
        .onAppear { Task { await rank() } }
        .task { await rateNewArticles() }
        .onDisappear { ratingTask?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Articles", systemImage: "chevron.left")
                    .frame(minHeight: 44)
            }
            Spacer()
            Text("AI Inbox").font(.headline)
            Spacer()
            Menu {
                Button("Rate new articles", systemImage: "sparkles") {
                    Task { await rateNewArticles() }
                }
                Button("Re-rate everything", systemImage: "arrow.clockwise") {
                    Task { await rateNewArticles(rerateAll: true) }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Rate articles")
            .disabled(ratingStatus != nil)
        }
        .padding(.horizontal, 16)
        .background(SkimStyle.chrome)
    }

    // MARK: List

    private var articleList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if let ratingStatus {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(SkimStyle.accent)
                            Text(ratingStatus)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(SkimStyle.secondary)
                        }
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(SkimStyle.secondary)
                    }
                    AIDisclaimerLabel()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                NavigationLink {
                    ArticleDetailView(articleID: item.article.id)
                } label: {
                    InboxArticleRow(rank: index + 1, item: item)
                }
                .listRowBackground(SkimStyle.chrome)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 12))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        dismissArticle(item.article)
                    } label: {
                        Label("Dismiss", systemImage: "checkmark")
                    }
                    .tint(SkimStyle.secondary)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        Task { await model.toggleStar(item.article); await rank() }
                    } label: {
                        Label(item.article.isStarred ? "Unsave" : "Save",
                              systemImage: item.article.isStarred ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                }
                .contextMenu {
                    Button("Dismiss", systemImage: "checkmark") { dismissArticle(item.article) }
                    Button(item.article.isStarred ? "Unsave" : "Save",
                           systemImage: item.article.isStarred ? "star.slash" : "star") {
                        Task { await model.toggleStar(item.article); await rank() }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await rateNewArticles() }
    }

    private func dismissArticle(_ article: Article) {
        withAnimation { items.removeAll { $0.id == article.id } }
        Task { await model.dismissFromInbox(article) }
    }

    // MARK: Ranking

    /// Rank unread articles from stored ratings and current taste; no AI call.
    private func rank() async {
        do {
            let candidates = try await model.inboxCandidates()
            let starred = await model.starredForTaste()
            let taste = model.tasteStore.inboxTaste(starred: starred)
            let strength = taste.strength
            let now = Date()
            let ranked = candidates.map { article -> InboxRankedArticle in
                let rating = model.inboxScores.score(for: article.id)
                let published = article.publishedAt ?? article.fetchedAt
                let score = InboxRanking.score(
                    importance: rating?.importance,
                    relevance: rating?.relevance,
                    affinity: taste.affinity(feedID: article.feedID, title: article.title),
                    strength: strength,
                    pinned: model.tasteStore.signal(for: article.id)?.priorityOverride == .pin,
                    ageHours: max(0, now.timeIntervalSince(published)) / 3600
                )
                return InboxRankedArticle(article: article, rating: rating, score: score)
            }
            items = ranked.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return ($0.article.publishedAt ?? $0.article.fetchedAt) > ($1.article.publishedAt ?? $1.article.fetchedAt)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Rate unrated unread articles in small batches, re-ranking after each.
    private func rateNewArticles(rerateAll: Bool = false) async {
        ratingTask?.cancel()
        let task = Task { await performRating(rerateAll: rerateAll) }
        ratingTask = task
        await task.value
    }

    private func performRating(rerateAll: Bool) async {
        await rank()
        errorMessage = nil
        guard model.settings.ai.provider != "none" else {
            errorMessage = "Choose an AI model in Settings to rate importance and relevance. Until then the inbox ranks by what you read."
            return
        }
        guard AIBootDisclaimerView.isAccepted else { return }

        var pending = items.map(\.article)
        if !rerateAll {
            pending = pending.filter { model.inboxScores.score(for: $0.id) == nil }
        }
        pending = Array(pending.prefix(Self.ratingsPerVisit))
        guard !pending.isEmpty else { return }

        let provider = model.settings.ai.provider
        let batchSize = (provider == "mlx" || provider == "foundation-models") ? 10 : 20
        let readerContext = NativeAI.inboxReaderContext(
            interests: model.settings.ai.triageUserPrompt,
            likedTitles: model.tasteStore.likedTitles()
        )
        var rated = 0
        defer { ratingStatus = nil }
        for start in stride(from: 0, to: pending.count, by: batchSize) {
            guard !Task.isCancelled else { return }
            let batch = Array(pending[start..<min(start + batchSize, pending.count)])
            ratingStatus = "Rating \(rated + 1)–\(rated + batch.count) of \(pending.count)…"
            do {
                let ratings = try await NativeAI.inboxRatings(
                    articles: batch, readerContext: readerContext, settings: model.settings)
                let now = Date()
                var stored: [String: InboxAIScore] = [:]
                for (handle, rating) in ratings {
                    stored[batch[handle - 1].id] = InboxAIScore(
                        importance: rating.importance, relevance: rating.relevance,
                        reason: rating.reason, scoredAt: now)
                }
                model.inboxScores.set(stored)
                rated += batch.count
                await rank()
            } catch {
                if Task.isCancelled { return }
                errorMessage = error.localizedDescription
                return
            }
        }
    }
}

// MARK: - Inbox Article Row

private struct InboxArticleRow: View {
    var rank: Int
    var item: InboxRankedArticle

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
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

                if let reason = item.rating?.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Text(item.article.feedTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SkimStyle.accent)
                        .lineLimit(1)
                    if let publishedAt = item.article.publishedAt {
                        Text("·").foregroundStyle(SkimStyle.secondary)
                        Text(publishedAt, style: .relative)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(SkimStyle.secondary)
                            .lineLimit(1)
                    }
                    if item.article.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.yellow)
                    }
                }

                if let rating = item.rating {
                    HStack(spacing: 14) {
                        RatingDots(label: "Importance", value: rating.importance)
                        RatingDots(label: "For you", value: rating.relevance)
                    }
                } else {
                    Text("Not rated yet")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SkimStyle.secondary.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// Five-dot rating; filled dots carry the value, the label carries the axis.
private struct RatingDots: View {
    var label: String
    var value: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SkimStyle.secondary)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { n in
                    Circle()
                        .fill(n <= value ? SkimStyle.accent : SkimStyle.secondary.opacity(0.3))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) of 5")
    }
}
