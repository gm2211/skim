import Foundation
import SkimCore

// MARK: - Taste Signal Types

enum ArticleFeedbackRating: String, Codable {
    case positive
    case negative
    case neutral
}

enum ArticlePriorityOverride: String, Codable {
    case pin
    case hide
    case none
}

struct ArticleTasteSignal: Codable {
    var articleID: String
    var feedID: String
    var feedTitle: String
    var dwellSeconds: Double
    var rating: ArticleFeedbackRating
    var priorityOverride: ArticlePriorityOverride
    var recordedAt: Date

    init(articleID: String, feedID: String, feedTitle: String) {
        self.articleID = articleID
        self.feedID = feedID
        self.feedTitle = feedTitle
        self.dwellSeconds = 0
        self.rating = .neutral
        self.priorityOverride = .none
        self.recordedAt = Date()
    }
}

struct PreferenceProfile {
    /// Feed weights: feedID → normalized score [-1.0, +1.0]
    var feedWeights: [String: Double]
    /// Feed display titles for reference
    var feedTitles: [String: String]
    /// Number of signals used to build the profile
    var signalCount: Int

    static let empty = PreferenceProfile(feedWeights: [:], feedTitles: [:], signalCount: 0)
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

    func recordReadingTime(articleID: String, feedID: String, feedTitle: String, dwellSeconds: Double) {
        var signal = signals[articleID] ?? ArticleTasteSignal(articleID: articleID, feedID: feedID, feedTitle: feedTitle)
        // Accumulate dwell time (user may open article multiple times)
        signal.dwellSeconds = max(signal.dwellSeconds, dwellSeconds)
        signal.recordedAt = Date()
        signals[articleID] = signal
        save()
    }

    func setFeedback(articleID: String, feedID: String, feedTitle: String, rating: ArticleFeedbackRating) {
        var signal = signals[articleID] ?? ArticleTasteSignal(articleID: articleID, feedID: feedID, feedTitle: feedTitle)
        signal.rating = rating
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

    func signal(for articleID: String) -> ArticleTasteSignal? {
        signals[articleID]
    }

    func getPreferenceProfile() -> PreferenceProfile {
        guard !signals.isEmpty else { return .empty }

        // Per-feed aggregate score
        var feedScoreSum: [String: Double] = [:]
        var feedCount: [String: Int] = [:]
        var feedTitles: [String: String] = [:]

        for signal in signals.values {
            let id = signal.feedID
            feedTitles[id] = signal.feedTitle

            var score: Double = 0
            // Dwell time: >60s = strong positive, 10-60s = mild positive, <5s = mild negative
            let dwell = signal.dwellSeconds
            if dwell >= 60 { score += 1.0 }
            else if dwell >= 10 { score += 0.5 }
            else if dwell > 0 && dwell < 5 { score -= 0.3 }

            // Explicit rating
            switch signal.rating {
            case .positive: score += 1.5
            case .negative: score -= 1.5
            case .neutral: break
            }

            // Priority override
            switch signal.priorityOverride {
            case .pin: score += 2.0
            case .hide: score -= 2.0
            case .none: break
            }

            feedScoreSum[id, default: 0] += score
            feedCount[id, default: 0] += 1
        }

        // Normalize to [-1, +1]
        var feedWeights: [String: Double] = [:]
        for (id, sum) in feedScoreSum {
            let count = Double(feedCount[id] ?? 1)
            let avg = sum / count
            // Clamp and scale
            feedWeights[id] = max(-1.0, min(1.0, avg / 3.0))
        }

        return PreferenceProfile(
            feedWeights: feedWeights,
            feedTitles: feedTitles,
            signalCount: signals.count
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
