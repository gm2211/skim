import Foundation

/// How far back a catch-up reaches. `.anything` is the whole list the reader
/// was already looking at, which is what catch-up did before the choice existed.
public enum CatchUpRange: Int, CaseIterable, Identifiable, Sendable {
    case sixHours = 6
    case day = 24
    case threeDays = 72
    case week = 168
    case anything = 0

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .sixHours: return "Last 6 hours"
        case .day: return "Last 24 hours"
        case .threeDays: return "Last 3 days"
        case .week: return "Last week"
        case .anything: return "Anything unread"
        }
    }

    /// The oldest publication date still on the page, or `nil` for no bound.
    public func cutoff(now: Date = Date()) -> Date? {
        guard rawValue > 0 else { return nil }
        return now.addingTimeInterval(-Double(rawValue) * 3600)
    }

    /// The articles this range keeps. An article with no publication date is
    /// kept: dropping it would silently hide feeds that omit the field.
    public func filter(_ articles: [Article], now: Date = Date()) -> [Article] {
        guard let cutoff = cutoff(now: now) else { return articles }
        return articles.filter { article in
            guard let published = article.publishedAt else { return true }
            return published >= cutoff
        }
    }
}
