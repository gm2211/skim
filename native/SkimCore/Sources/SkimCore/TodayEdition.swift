import Foundation

public enum EditionSectionRole: String, Codable, CaseIterable, Hashable, Sendable {
    case topStories = "top_stories"
    case widelyCovered = "widely_covered"
    case uniqueFinds = "unique_finds"
    case updates = "updates"
}

public struct TodayEditionSourceArticle: Codable, Hashable, Sendable {
    public var articleID: String
    public var feedID: String
    public var feedTitle: String
    public var articleTitle: String
    public var url: URL?
    public var publishedAt: Date?
    public var membershipType: StoryMembershipType
    public var confidence: Double?
    public var position: Int
    public var isRepresentative: Bool
    public var liveArticle: Article?

    public init(
        articleID: String,
        feedID: String,
        feedTitle: String,
        articleTitle: String,
        url: URL?,
        publishedAt: Date?,
        membershipType: StoryMembershipType,
        confidence: Double?,
        position: Int,
        isRepresentative: Bool,
        liveArticle: Article?
    ) {
        self.articleID = articleID
        self.feedID = feedID
        self.feedTitle = feedTitle
        self.articleTitle = articleTitle
        self.url = url
        self.publishedAt = publishedAt
        self.membershipType = membershipType
        self.confidence = confidence
        self.position = position
        self.isRepresentative = isRepresentative
        self.liveArticle = liveArticle
    }

    enum CodingKeys: String, CodingKey {
        case articleID = "article_id"
        case feedID = "feed_id"
        case feedTitle = "feed_title"
        case articleTitle = "article_title"
        case url
        case publishedAt = "published_at"
        case membershipType = "membership_type"
        case confidence
        case position
        case isRepresentative = "is_representative"
        case liveArticle = "live_article"
    }
}

/// A frozen edition item plus the immutable revision and source identities it
/// referenced when Today was generated.
public struct TodayEditionItem: Identifiable, Codable, Hashable, Sendable {
    public var snapshot: EditionItem
    public var revision: StoryRevision
    public var representativeArticleID: String?
    public var memberArticleIDs: [String]
    public var sourceArticles: [TodayEditionSourceArticle]

    public var id: String { snapshot.id }

    public init(
        snapshot: EditionItem,
        revision: StoryRevision,
        representativeArticleID: String?,
        memberArticleIDs: [String],
        sourceArticles: [TodayEditionSourceArticle]
    ) {
        self.snapshot = snapshot
        self.revision = revision
        self.representativeArticleID = representativeArticleID
        self.memberArticleIDs = memberArticleIDs
        self.sourceArticles = sourceArticles
    }

    enum CodingKeys: String, CodingKey {
        case snapshot
        case revision
        case representativeArticleID = "representative_article_id"
        case memberArticleIDs = "member_article_ids"
        case sourceArticles = "source_articles"
    }
}

public struct TodayEditionSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var edition: Edition
    public var items: [TodayEditionItem]
    public var consumedItemCount: Int
    public var totalItemCount: Int
    public var progress: Double

    public var id: String { edition.id }

    public init(
        edition: Edition,
        items: [TodayEditionItem],
        consumedItemCount: Int,
        totalItemCount: Int
    ) {
        self.edition = edition
        self.items = items
        self.consumedItemCount = consumedItemCount
        self.totalItemCount = totalItemCount
        self.progress = totalItemCount == 0
            ? (edition.status == .completed ? 1 : 0)
            : Double(consumedItemCount) / Double(totalItemCount)
    }

    enum CodingKeys: String, CodingKey {
        case edition
        case items
        case consumedItemCount = "consumed_item_count"
        case totalItemCount = "total_item_count"
        case progress
    }
}

struct TodayEditionCandidate: Sendable {
    var ranking: StoryRankingCandidate
    var revision: StoryRevision
    var sourceArticles: [TodayEditionCandidateSource]
}

struct TodayEditionCandidateSource: Sendable {
    var article: Article
    var membership: StoryArticleMembership
}

struct GeneratedTodayEditionItem: Sendable {
    var item: EditionItem
    var sourceArticles: [TodayEditionSourceArticle]
}

enum TodayEditionBuilder {
    static let supportedStoryLimits = [5, 10, 20]

    static func stableID(
        startsAt: Date,
        endsAt: Date,
        storyLimit: Int
    ) -> String {
        let start = Int64(floor(startsAt.timeIntervalSince1970))
        let end = Int64(floor(endsAt.timeIntervalSince1970))
        return "today-\(start)-\(end)-\(storyLimit)"
    }

    static func buildItems(
        editionID: String,
        candidates: [TodayEditionCandidate],
        storyLimit: Int,
        generatedAt: Date
    ) -> [GeneratedTodayEditionItem] {
        guard storyLimit > 0, !candidates.isEmpty else { return [] }
        let clusterer = StoryClusterer()
        var choices = candidates.compactMap {
            candidate -> (RankedStory, TodayEditionCandidate, EditionSectionRole)? in
            let ranking = clusterer.rank(
                [candidate.ranking],
                asOf: generatedAt,
                configuration: StoryRankingConfiguration(
                    topStoryLimit: 1,
                    uniqueFindLimit: 1,
                    maximumStoriesPerRepresentativeFeed: 1
                )
            )
            guard let rankedStory = (ranking.topStories + ranking.uniqueFinds).first else {
                return nil
            }
            return (
                rankedStory,
                candidate,
                section(for: rankedStory, revision: candidate.revision)
            )
        }
        choices.sort {
            if $0.0.score != $1.0.score { return $0.0.score > $1.0.score }
            return $0.0.storyID < $1.0.storyID
        }

        var selectedIDs = Set<String>()
        var selected: [(RankedStory, TodayEditionCandidate, EditionSectionRole)] = []
        let reservationOrder: [EditionSectionRole] = [
            .updates, .widelyCovered, .uniqueFinds, .topStories
        ]
        for role in reservationOrder {
            guard selected.count < storyLimit,
                  let choice = choices.first(where: { $0.2 == role })
            else { continue }
            if selectedIDs.insert(choice.0.storyID).inserted {
                selected.append(choice)
            }
        }
        let feedCap = max(1, storyLimit / 2)
        var feedCounts: [String: Int] = [:]
        for choice in selected {
            feedCounts[choice.1.ranking.representativeFeedID, default: 0] += 1
        }
        for choice in choices {
            guard selected.count < storyLimit else { break }
            if choice.2 == .uniqueFinds,
               selected.filter({ $0.2 == .uniqueFinds }).count >= 2
            {
                continue
            }
            let feedID = choice.1.ranking.representativeFeedID
            guard feedCounts[feedID, default: 0] < feedCap else { continue }
            if selectedIDs.insert(choice.0.storyID).inserted {
                selected.append(choice)
                feedCounts[feedID, default: 0] += 1
            }
        }
        // Relax diversity only when needed to avoid a needlessly short edition.
        for choice in choices {
            guard selected.count < storyLimit else { break }
            if choice.2 == .uniqueFinds,
               selected.filter({ $0.2 == .uniqueFinds }).count >= 2
            {
                continue
            }
            if selectedIDs.insert(choice.0.storyID).inserted {
                selected.append(choice)
            }
        }

        let sectionOrder: [EditionSectionRole: Int] = [
            .topStories: 0,
            .widelyCovered: 1,
            .updates: 2,
            .uniqueFinds: 3
        ]
        selected.sort {
            let leftSection = sectionOrder[$0.2]!
            let rightSection = sectionOrder[$1.2]!
            if leftSection != rightSection { return leftSection < rightSection }
            if $0.0.score != $1.0.score { return $0.0.score > $1.0.score }
            return $0.0.storyID < $1.0.storyID
        }

        return selected.enumerated().map { position, choice in
            let rankedStory = choice.0
            let candidate = choice.1
            let role = choice.2
            let representativeID = candidate.revision.representativeArticleID
            let orderedArticles = candidate.sourceArticles.sorted {
                if $0.article.id == representativeID { return true }
                if $1.article.id == representativeID { return false }
                let leftDate = $0.article.publishedAt ?? $0.article.fetchedAt
                let rightDate = $1.article.publishedAt ?? $1.article.fetchedAt
                if leftDate != rightDate { return leftDate > rightDate }
                return $0.article.id < $1.article.id
            }
            return GeneratedTodayEditionItem(
                item: EditionItem(
                    editionID: editionID,
                    storyID: rankedStory.storyID,
                    storyRevisionNumber: candidate.revision.revisionNumber,
                    position: position,
                    section: role.rawValue,
                    snapshotTitle: candidate.revision.title,
                    snapshotSummary: candidate.revision.summary,
                    snapshotDeltaSummary: candidate.revision.deltaSummary,
                    snapshotSourceCount: candidate.revision.sourceCount,
                    snapshotReason: reason(
                        for: role,
                        sourceCount: candidate.revision.sourceCount
                    ),
                    isUniqueFind: role == .uniqueFinds
                ),
                sourceArticles: orderedArticles.enumerated().map { sourcePosition, source in
                    TodayEditionSourceArticle(
                        articleID: source.article.id,
                        feedID: source.article.feedID,
                        feedTitle: source.article.feedTitle,
                        articleTitle: source.article.title,
                        url: source.article.externalURL ?? source.article.url,
                        publishedAt: source.article.publishedAt,
                        membershipType: source.membership.membershipType,
                        confidence: source.membership.confidence,
                        position: sourcePosition,
                        isRepresentative: source.article.id == representativeID,
                        liveArticle: source.article
                    )
                }
            )
        }
    }

    private static func section(
        for ranked: RankedStory,
        revision: StoryRevision
    ) -> EditionSectionRole {
        if revision.deltaSummary == StoryMembershipType.update.rawValue {
            return .updates
        }
        if ranked.isUniqueFind {
            return .uniqueFinds
        }
        if ranked.distinctFeedCount >= 3 {
            return .widelyCovered
        }
        return .topStories
    }

    private static func reason(
        for section: EditionSectionRole,
        sourceCount: Int
    ) -> String {
        switch section {
        case .topStories:
            "high_rank_recent"
        case .widelyCovered:
            "widely_covered:\(sourceCount)"
        case .updates:
            "updated_story"
        case .uniqueFinds:
            "unique_singleton"
        }
    }
}
