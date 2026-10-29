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

// MARK: - For you

/// The article list sorted For you (formerly the AI Inbox): unread articles in
/// the selected scope, most relevant and important first. The AI rates each
/// article once on importance and relevance; taste learned on this device from
/// reading time, chats, saves, pins and dismissals re-ranks on every visit.
struct AIInboxView: View {
    @EnvironmentObject private var model: AppModel
    var onSummarize: (Article) -> Void = { _ in }

    @State private var items: [InboxRankedArticle] = []
    /// The unread articles last loaded, newest first, so re-ranking after a
    /// rated batch doesn't reload the whole window from the store.
    @State private var candidates: [Article] = []
    @State private var isLoading = true
    @State private var ratingStatus: String?
    @State private var errorMessage: String?
    @State private var ratingTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && items.isEmpty {
                ProgressView()
                    .tint(SkimStyle.accent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Nothing unread",
                    systemImage: SkimIcon.aiInbox,
                    description: Text("Smart sorting ranks unread articles. Refresh your feeds, or turn it off to see read ones.")
                )
                .foregroundStyle(SkimStyle.secondary)
                .frame(maxHeight: .infinity)
            } else {
                articleList
            }
        }
        .background(SkimStyle.chrome)
        .foregroundStyle(SkimStyle.text)
        // Re-rank on every return (e.g. from an article) so new taste shows up.
        .onAppear { Task { await rank() } }
        .task { await rateNewArticles() }
        .onDisappear { ratingTask?.cancel() }
    }

    // MARK: List

    /// The usual article rows, only in ranked order: smart sorting changes
    /// the order, not the look. A status line shows only while rating runs
    /// or after it failed.
    private var articleList: some View {
        let visible = items.map(\.article)
        return List {
            if ratingStatus != nil || errorMessage != nil {
                VStack(alignment: .leading, spacing: 6) {
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
                            .fixedSize(horizontal: false, vertical: true)
                        AISettingsButton(titled: true, font: .system(size: 13, weight: .semibold), color: SkimStyle.accent,
                                         onDismiss: { Task { await rateNewArticles() } })
                    }
                }
                // Lines up with the row titles, like the list's date headers.
                .padding(.leading, 64)
                .padding(.trailing, 18)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets())
                .listRowBackground(SkimStyle.chrome)
                .listRowSeparator(.hidden)
            }

            ForEach(items) { item in
                NavigationLink {
                    ArticleDetailView(articleID: item.article.id)
                } label: {
                    ArticleRow(
                        article: item.article,
                        feed: model.feeds.first(where: { $0.id == item.article.feedID }),
                        visibleArticles: visible,
                        onSummarize: onSummarize
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(SkimStyle.chrome)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        dismissArticle(item.article)
                    } label: {
                        Label("Dismiss", systemImage: "checkmark")
                    }
                    .tint(SkimStyle.secondary)
                }
            }

            if let note = InboxRatingQueue.windowNote(loaded: candidates.count, unread: model.currentUnreadCount) {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(SkimStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 64)
                    .padding(.trailing, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(SkimStyle.chrome)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .scrollContentBackground(.hidden)
        .refreshable { await rateNewArticles() }
    }

    private func dismissArticle(_ article: Article) {
        withAnimation { items.removeAll { $0.id == article.id } }
        candidates.removeAll { $0.id == article.id }
        Task { await model.dismissFromInbox(article) }
    }

    // MARK: Ranking

    /// Rank unread articles from stored ratings and current taste; no AI call.
    /// `reload` re-reads the unread window from the store; without it the
    /// articles already loaded are re-ordered with their new ratings.
    private func rank(reload: Bool = true) async {
        do {
            if reload || candidates.isEmpty {
                candidates = try await model.inboxCandidates(limit: InboxRatingQueue.window)
            }
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
            errorMessage = NativeAI.userFacingMessage(error)
        }
        isLoading = false
    }

    /// Rate unrated unread articles in small batches, newest first, re-ranking
    /// as ratings come in.
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

        let pending = InboxRatingQueue.pending(candidates, rerateAll: rerateAll) {
            model.inboxScores.score(for: $0) != nil
        }
        guard !pending.isEmpty else { return }

        let provider = model.settings.ai.provider
        let batchSize = (provider == "mlx" || provider == "foundation-models") ? 10 : 20
        // Smart sort's learned layer keeps learning: rewrite the note first
        // when enough new reading has come in. A failure never blocks ranking.
        do {
            try await model.learnPreferences()
        } catch {
            print("[AIInbox] Learning smart sort preferences failed: \(error.localizedDescription)")
        }
        let readerContext = NativeAI.inboxReaderContext(
            interests: model.settings.ai.triageUserPrompt,
            learned: model.learnedPreferences.value.text
        )
        var rated = 0
        var unrated = 0
        var firstError: Error?
        var failedInARow = 0
        var batchIndex = 0
        defer { ratingStatus = nil }
        for start in stride(from: 0, to: pending.count, by: batchSize) {
            guard !Task.isCancelled else { return }
            // A provider that keeps failing (rate-limited, signed out, down)
            // won't recover mid-run; stop rather than spend the rest of the
            // backlog's requests against it.
            if failedInARow >= InboxRatingQueue.maxFailedBatchesInARow { break }
            let batch = Array(pending[start..<min(start + batchSize, pending.count)])
            ratingStatus = InboxRatingQueue.status(done: rated + unrated, batch: batch.count, unrated: pending.count)
            let ratedBefore = rated
            // A batch that fails is retried as two halves, so one bad response
            // costs at most that batch, never the rest of the visit.
            var parts: [(articles: [Article], canSplit: Bool)] = [(batch, true)]
            while !parts.isEmpty {
                let (part, canSplit) = parts.removeFirst()
                do {
                    let ratings = try await NativeAI.inboxRatings(
                        articles: part, readerContext: readerContext, settings: model.settings)
                    store(ratings, for: part)
                    rated += ratings.count
                    unrated += part.count - ratings.count
                } catch {
                    if Task.isCancelled { return }
                    if canSplit, part.count > 1 {
                        let half = part.count / 2
                        parts = [(Array(part[..<half]), false), (Array(part[half...]), false)] + parts
                    } else {
                        firstError = firstError ?? error
                        unrated += part.count
                    }
                }
            }
            failedInARow = rated > ratedBefore ? 0 : failedInARow + 1
            // Re-order early so the newest show up ranked fast, then every few
            // batches so a long backlog doesn't keep reshuffling the list.
            if rated > ratedBefore, InboxRatingQueue.shouldReRank(afterBatch: batchIndex) {
                await rank(reload: false)
            }
            batchIndex += 1
        }
        await rank(reload: false)
        let left = pending.count - rated
        if let firstError, rated == 0 {
            errorMessage = NativeAI.userFacingMessage(firstError)
        } else if left > 0 {
            let reason = firstError.map { " " + NativeAI.userFacingMessage($0) } ?? ""
            errorMessage = "Rated \(rated) of \(pending.count) unrated articles.\(reason) The rest stay ranked by what you read; pull to refresh to rate them."
        }
    }

    private func store(_ ratings: [Int: NativeAI.InboxRating], for batch: [Article]) {
        let now = Date()
        var stored: [String: InboxAIScore] = [:]
        for (handle, rating) in ratings {
            stored[batch[handle - 1].id] = InboxAIScore(
                importance: rating.importance, relevance: rating.relevance,
                reason: rating.reason, scoredAt: now)
        }
        model.inboxScores.set(stored)
    }
}

// MARK: - Rating queue

/// What smart sort loads and how it works through the unrated backlog. Pure,
/// so the choices are testable without a model.
enum InboxRatingQueue {
    /// Most unread articles smart sort loads, ranks and rates: the newest
    /// ones, matching desktop's per-run triage cap.
    static let window = 1_000
    /// Batches that rate nothing, back to back, before a run gives up.
    static let maxFailedBatchesInARow = 2

    /// Articles still to rate, newest first, so a backlog rates what's fresh
    /// before what's old.
    static func pending(_ articles: [Article], rerateAll: Bool = false, isRated: (String) -> Bool) -> [Article] {
        let todo = rerateAll ? articles : articles.filter { !isRated($0.id) }
        return todo.sorted { ($0.publishedAt ?? $0.fetchedAt) > ($1.publishedAt ?? $1.fetchedAt) }
    }

    /// "Rating 21–40 of 940 unrated…": the count is every unrated article
    /// being worked through, not a per-visit slice.
    static func status(done: Int, batch: Int, unrated: Int) -> String {
        "Rating \((done + 1).formatted())–\((done + batch).formatted()) of \(unrated.formatted()) unrated…"
    }

    /// Re-rank after the first two batches, then every fifth.
    static func shouldReRank(afterBatch index: Int) -> Bool {
        index < 2 || (index + 1) % 5 == 0
    }

    /// Says so when the list holds fewer articles than are unread, so a
    /// 6,024 unread title over a shorter list isn't a mystery.
    static func windowNote(loaded: Int, unread: Int) -> String? {
        guard loaded > 0, unread > loaded else { return nil }
        return "Smart sort ranks your \(loaded.formatted()) newest unread articles. Turn it off to see all \(unread.formatted())."
    }
}
