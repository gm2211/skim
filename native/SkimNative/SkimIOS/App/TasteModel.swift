import Foundation
import SkimCore

// MARK: - Taste Signal Types

enum ArticlePriorityOverride: String, Codable {
    case pin
    case none

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Legacy "hide" values (feature removed) decode as .none.
        self = ArticlePriorityOverride(rawValue: raw) ?? .none
    }
}

struct ArticleTasteSignal: Codable {
    var articleID: String
    var feedID: String
    var feedTitle: String
    var dwellSeconds: Double
    var priorityOverride: ArticlePriorityOverride
    var recordedAt: Date
    /// Optional so signals saved before the AI Inbox learned titles still decode.
    var title: String?
    /// Dismissed from the AI Inbox without being opened.
    var dismissed: Bool?
    /// Questions asked about the article in chat; each counts as a minute of reading.
    var chatMessages: Int?

    init(articleID: String, feedID: String, feedTitle: String, title: String? = nil) {
        self.articleID = articleID
        self.feedID = feedID
        self.feedTitle = feedTitle
        self.title = title
        self.dwellSeconds = 0
        self.priorityOverride = .none
        self.recordedAt = Date()
    }
}

// MARK: - Taste Store

/// Lightweight in-memory + UserDefaults persistence for taste signals.
/// Intentionally simple: no SQLite dependency, no Core Data.
final class TasteStore {
    private static let defaultsKey = "skim.tasteSignals"
    private var signals: [String: ArticleTasteSignal] = [:] // keyed by articleID

    init() {
        load()
    }

    // MARK: API

    func recordReadingTime(articleID: String, feedID: String, feedTitle: String, title: String? = nil, dwellSeconds: Double) {
        var signal = signals[articleID] ?? ArticleTasteSignal(articleID: articleID, feedID: feedID, feedTitle: feedTitle)
        // Accumulate dwell time (user may open article multiple times)
        signal.dwellSeconds = max(signal.dwellSeconds, dwellSeconds)
        if let title { signal.title = title }
        signal.dismissed = nil
        signal.recordedAt = Date()
        signals[articleID] = signal
        save()
    }

    func setPriorityOverride(articleID: String, feedID: String, feedTitle: String, override: ArticlePriorityOverride) {
        var signal = signals[articleID] ?? ArticleTasteSignal(articleID: articleID, feedID: feedID, feedTitle: feedTitle)
        signal.priorityOverride = override
        signal.recordedAt = Date()
        signals[articleID] = signal
        save()
    }

    /// The reader asked about this article in chat, as desktop counts chats.
    func recordChatMessage(articleID: String, feedID: String, feedTitle: String, title: String) {
        var signal = signals[articleID] ?? ArticleTasteSignal(articleID: articleID, feedID: feedID, feedTitle: feedTitle)
        signal.title = title
        signal.chatMessages = (signal.chatMessages ?? 0) + 1
        signal.dismissed = nil
        signal.recordedAt = Date()
        signals[articleID] = signal
        save()
    }

    /// The reader cleared this article from the AI Inbox without opening it.
    func recordDismissal(articleID: String, feedID: String, feedTitle: String, title: String) {
        var signal = signals[articleID] ?? ArticleTasteSignal(articleID: articleID, feedID: feedID, feedTitle: feedTitle)
        guard signal.dwellSeconds == 0 else { return }
        signal.title = title
        signal.dismissed = true
        signal.recordedAt = Date()
        signals[articleID] = signal
        save()
    }

    func signal(for articleID: String) -> ArticleTasteSignal? {
        signals[articleID]
    }

    /// Titles the reader spent real time on, most recent first.
    func likedTitles(limit: Int = 15) -> [String] {
        signals.values
            .filter { $0.dwellSeconds >= 30 || $0.priorityOverride == .pin || ($0.chatMessages ?? 0) > 0 }
            .sorted { $0.recordedAt > $1.recordedAt }
            .compactMap(\.title)
            .prefix(limit)
            .map { $0 }
    }

    /// On-device taste for the AI Inbox: reading time, pins, dismissals and
    /// saved (starred) articles, weighted by the policy shared with desktop.
    func inboxTaste(starred: [Article]) -> InboxTaste {
        var taste = InboxTaste()
        var seen = Set<String>()
        let starredIDs = Set(starred.map(\.id))
        for signal in signals.values {
            seen.insert(signal.articleID)
            taste.learn(
                feedID: signal.feedID,
                title: signal.title ?? "",
                signal: .init(
                    dwellSeconds: signal.dwellSeconds + Double(signal.chatMessages ?? 0) * 60,
                    opened: signal.dwellSeconds > 0 || (signal.chatMessages ?? 0) > 0,
                    starred: starredIDs.contains(signal.articleID),
                    pinned: signal.priorityOverride == .pin,
                    readUnopened: signal.dismissed == true
                )
            )
        }
        for article in starred where !seen.contains(article.id) {
            taste.learn(feedID: article.feedID, title: article.title, signal: .init(starred: true))
        }
        return taste
    }

    /// Supply the AI Inbox's taste to the shared edition builder once, at generation.
    func todayRankingPreferences(starred: [Article]) -> TodayRankingPreferences {
        TodayRankingPreferences(
            taste: inboxTaste(starred: starred),
            pinnedArticleIDs: Set(signals.values.filter {
                $0.priorityOverride == .pin
            }.map(\.articleID))
        )
    }

    // MARK: Private

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ArticleTasteSignal].self, from: data)
        else { return }
        signals = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(signals) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - AI Inbox Ratings

/// The model's two-axis rating of one article for the AI Inbox.
struct InboxAIScore: Codable, Equatable {
    /// Significance for anyone following the area, 1-5.
    var importance: Int
    /// Fit with this reader's interests, 1-5.
    var relevance: Int
    var reason: String
    var scoredAt: Date
}

/// Persists AI Inbox ratings so each article is rated once, not on every visit.
/// UserDefaults-backed like `TasteStore`; old entries are pruned.
final class InboxScoreStore {
    private static let defaultsKey = "skim.inboxScores"
    private static let maxEntries = 3000
    private static let maxAge: TimeInterval = 30 * 24 * 3600
    private var scores: [String: InboxAIScore] = [:]

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: InboxAIScore].self, from: data)
        else { return }
        scores = decoded
    }

    func score(for articleID: String) -> InboxAIScore? {
        scores[articleID]
    }

    func set(_ batch: [String: InboxAIScore]) {
        guard !batch.isEmpty else { return }
        scores.merge(batch) { _, new in new }
        prune()
        save()
    }

    func removeAll() {
        scores = [:]
        save()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        scores = scores.filter { $0.value.scoredAt >= cutoff }
        if scores.count > Self.maxEntries {
            let keep = scores.sorted { $0.value.scoredAt > $1.value.scoredAt }.prefix(Self.maxEntries)
            scores = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(scores) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
