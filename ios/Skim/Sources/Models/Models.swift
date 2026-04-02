import Foundation
import SwiftData

@Model
final class Feed: Identifiable {
    @Attribute(.unique) var id: String
    var title: String
    var url: String
    var siteUrl: String?
    var feedDescription: String?
    var iconUrl: String?
    var feedlyId: String?
    var createdAt: Date
    var updatedAt: Date
    var lastFetchedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Article.feed)
    var articles: [Article] = []

    var unreadCount: Int {
        articles.filter { !$0.isRead }.count
    }

    init(id: String = UUID().uuidString, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
final class Article: Identifiable {
    @Attribute(.unique) var id: String
    var feed: Feed?
    var title: String
    var url: String?
    var author: String?
    var contentHtml: String?
    var contentText: String?
    var publishedAt: Date?
    var fetchedAt: Date
    var isRead: Bool
    var isStarred: Bool

    // Triage fields
    var triagePriority: Int?
    var triageReason: String?

    // Learning fields
    var readingTimeSec: Int = 0
    var chatMessages: Int = 0
    var feedback: String? // "more" | "less"

    var displayDate: Date {
        publishedAt ?? fetchedAt
    }

    init(id: String = UUID().uuidString, title: String, feedId: String) {
        self.id = id
        self.title = title
        self.fetchedAt = Date()
        self.isRead = false
        self.isStarred = false
    }
}

// Priority labels matching the desktop app
enum TriagePriority: Int, CaseIterable {
    case mustRead = 5
    case important = 4
    case worthReading = 3
    case routine = 2
    case skip = 1

    var label: String {
        switch self {
        case .mustRead: return "MUST READ"
        case .important: return "IMPORTANT"
        case .worthReading: return "WORTH READING"
        case .routine: return "ROUTINE"
        case .skip: return "SKIP"
        }
    }

    var color: String {
        switch self {
        case .mustRead: return "red"
        case .important: return "orange"
        case .worthReading: return "blue"
        case .routine: return "gray"
        case .skip: return "gray"
        }
    }
}
