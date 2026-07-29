import CryptoKit
import Foundation

/// Cached, deterministic lexical representation of an article.
///
/// The cache is deliberately inspectable and portable. Desktop and native use
/// the same normalized strings, sorted tokens, entities, and SHA-256
/// fingerprint rather than platform-specific embeddings.
public struct StoryArticleFeature: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var articleID: String
    public var canonicalURL: String?
    public var normalizedTitle: String
    public var normalizedLead: String
    public var tokens: [String]
    public var entities: [String]
    public var contentFingerprint: String
    public var featureVersion: Int
    public var computedAt: Date

    public init(
        articleID: String,
        canonicalURL: String?,
        normalizedTitle: String,
        normalizedLead: String,
        tokens: [String],
        entities: [String],
        contentFingerprint: String,
        featureVersion: Int = StoryArticleFeature.currentVersion,
        computedAt: Date
    ) {
        self.articleID = articleID
        self.canonicalURL = canonicalURL
        self.normalizedTitle = normalizedTitle
        self.normalizedLead = normalizedLead
        self.tokens = tokens
        self.entities = entities
        self.contentFingerprint = contentFingerprint
        self.featureVersion = featureVersion
        self.computedAt = computedAt
    }

    enum CodingKeys: String, CodingKey {
        case articleID = "article_id"
        case canonicalURL = "canonical_url"
        case normalizedTitle = "normalized_title"
        case normalizedLead = "normalized_lead"
        case tokens
        case entities
        case contentFingerprint = "content_fingerprint"
        case featureVersion = "feature_version"
        case computedAt = "computed_at"
    }
}

public struct StoryClusteringConfiguration: Codable, Hashable, Sendable {
    public static let defaultRollingWindow: TimeInterval = 96 * 60 * 60
    public static let defaultDuplicateThreshold = 0.88
    public static let defaultCoverageThreshold = 0.68
    public static let defaultBorderlineThreshold = 0.58

    public var rollingWindow: TimeInterval
    public var duplicateThreshold: Double
    public var coverageThreshold: Double
    public var borderlineThreshold: Double

    public init(
        rollingWindow: TimeInterval = StoryClusteringConfiguration.defaultRollingWindow,
        duplicateThreshold: Double = StoryClusteringConfiguration.defaultDuplicateThreshold,
        coverageThreshold: Double = StoryClusteringConfiguration.defaultCoverageThreshold,
        borderlineThreshold: Double = StoryClusteringConfiguration.defaultBorderlineThreshold
    ) {
        self.rollingWindow = rollingWindow
        self.duplicateThreshold = duplicateThreshold
        self.coverageThreshold = coverageThreshold
        self.borderlineThreshold = borderlineThreshold
    }

    enum CodingKeys: String, CodingKey {
        case rollingWindow = "rolling_window"
        case duplicateThreshold = "duplicate_threshold"
        case coverageThreshold = "coverage_threshold"
        case borderlineThreshold = "borderline_threshold"
    }
}

public struct StoryClusterCandidate: Hashable, Sendable {
    public var storyID: String
    public var article: Article
    public var feature: StoryArticleFeature

    public init(storyID: String, article: Article, feature: StoryArticleFeature) {
        self.storyID = storyID
        self.article = article
        self.feature = feature
    }
}

public struct StoryClusterMatch: Codable, Hashable, Sendable {
    public var storyID: String
    public var membershipType: StoryMembershipType
    public var confidence: Double
    public var matchedArticleID: String

    public init(
        storyID: String,
        membershipType: StoryMembershipType,
        confidence: Double,
        matchedArticleID: String
    ) {
        self.storyID = storyID
        self.membershipType = membershipType
        self.confidence = confidence
        self.matchedArticleID = matchedArticleID
    }

    enum CodingKeys: String, CodingKey {
        case storyID = "story_id"
        case membershipType = "membership_type"
        case confidence
        case matchedArticleID = "matched_article_id"
    }
}

/// A deliberately unmerged candidate for future local-model arbitration.
public struct StoryBorderlineMatch: Codable, Hashable, Sendable {
    public var candidateStoryID: String
    public var articleID: String
    public var matchedArticleID: String
    public var confidence: Double
    public var reason: String
    public var featureVersion: Int
    public var createdAt: Date

    public init(
        candidateStoryID: String,
        articleID: String,
        matchedArticleID: String,
        confidence: Double,
        reason: String,
        featureVersion: Int,
        createdAt: Date
    ) {
        self.candidateStoryID = candidateStoryID
        self.articleID = articleID
        self.matchedArticleID = matchedArticleID
        self.confidence = confidence
        self.reason = reason
        self.featureVersion = featureVersion
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case candidateStoryID = "candidate_story_id"
        case articleID = "article_id"
        case matchedArticleID = "matched_article_id"
        case confidence
        case reason
        case featureVersion = "feature_version"
        case createdAt = "created_at"
    }
}

public struct StoryClusterDecision: Hashable, Sendable {
    public var match: StoryClusterMatch?
    public var borderline: StoryBorderlineMatch?

    public init(match: StoryClusterMatch? = nil, borderline: StoryBorderlineMatch? = nil) {
        self.match = match
        self.borderline = borderline
    }
}

public struct StoryRankingCandidate: Hashable, Sendable {
    public var story: Story
    public var representativeFeedID: String
    public var distinctFeedCount: Int
    public var articleCount: Int
    public var preferenceSignal: Double
    public var isHidden: Bool

    public init(
        story: Story,
        representativeFeedID: String,
        distinctFeedCount: Int,
        articleCount: Int,
        preferenceSignal: Double = 0,
        isHidden: Bool = false
    ) {
        self.story = story
        self.representativeFeedID = representativeFeedID
        self.distinctFeedCount = distinctFeedCount
        self.articleCount = articleCount
        self.preferenceSignal = preferenceSignal
        self.isHidden = isHidden
    }
}

public struct RankedStory: Codable, Hashable, Sendable {
    public var storyID: String
    public var score: Double
    public var distinctFeedCount: Int
    public var rawArticleCount: Int
    public var isUniqueFind: Bool
    public var reason: String

    public init(
        storyID: String,
        score: Double,
        distinctFeedCount: Int,
        rawArticleCount: Int,
        isUniqueFind: Bool,
        reason: String
    ) {
        self.storyID = storyID
        self.score = score
        self.distinctFeedCount = distinctFeedCount
        self.rawArticleCount = rawArticleCount
        self.isUniqueFind = isUniqueFind
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case storyID = "story_id"
        case score
        case distinctFeedCount = "distinct_feed_count"
        case rawArticleCount = "raw_article_count"
        case isUniqueFind = "is_unique_find"
        case reason
    }
}

public struct StoryRankingResult: Codable, Hashable, Sendable {
    public var topStories: [RankedStory]
    public var uniqueFinds: [RankedStory]

    public init(topStories: [RankedStory], uniqueFinds: [RankedStory]) {
        self.topStories = topStories
        self.uniqueFinds = uniqueFinds
    }

    enum CodingKeys: String, CodingKey {
        case topStories = "top_stories"
        case uniqueFinds = "unique_finds"
    }
}

public struct StoryRankingConfiguration: Codable, Hashable, Sendable {
    public static let defaultRecencyWindow: TimeInterval = 96 * 60 * 60

    public var topStoryLimit: Int
    public var uniqueFindLimit: Int
    public var maximumStoriesPerRepresentativeFeed: Int
    public var recencyWindow: TimeInterval

    public init(
        topStoryLimit: Int = 10,
        uniqueFindLimit: Int = 2,
        maximumStoriesPerRepresentativeFeed: Int = 2,
        recencyWindow: TimeInterval = StoryRankingConfiguration.defaultRecencyWindow
    ) {
        self.topStoryLimit = topStoryLimit
        self.uniqueFindLimit = uniqueFindLimit
        self.maximumStoriesPerRepresentativeFeed = maximumStoriesPerRepresentativeFeed
        self.recencyWindow = recencyWindow
    }

    enum CodingKeys: String, CodingKey {
        case topStoryLimit = "top_story_limit"
        case uniqueFindLimit = "unique_find_limit"
        case maximumStoriesPerRepresentativeFeed = "maximum_stories_per_representative_feed"
        case recencyWindow = "recency_window"
    }
}

public struct StoryClusterer: Sendable {
    public let configuration: StoryClusteringConfiguration

    public init(configuration: StoryClusteringConfiguration = StoryClusteringConfiguration()) {
        self.configuration = configuration
    }

    public func feature(for article: Article) -> StoryArticleFeature {
        let normalizedTitle = Self.normalizeTitle(article.title)
        let lead = String(
            (article.contentText ?? article.contentHTML ?? "").prefix(700)
        )
        let normalizedLead = Self.normalizeText(lead)
        let titleTerms = Self.significantTerms(normalizedTitle)
        var tokens = titleTerms + titleTerms
        tokens.append(contentsOf: Self.significantTerms(normalizedLead))
        tokens.sort()
        let entities = Self.entities(in: article.title)
        let canonicalURL = Self.canonicalArticleURL(
            article.externalURL ?? article.url
        )
        let fingerprintSeed = [
            canonicalURL ?? "",
            normalizedTitle,
            normalizedLead
        ].joined(separator: "\n")
        return StoryArticleFeature(
            articleID: article.id,
            canonicalURL: canonicalURL,
            normalizedTitle: normalizedTitle,
            normalizedLead: normalizedLead,
            tokens: tokens,
            entities: entities,
            contentFingerprint: Self.sha256(fingerprintSeed),
            computedAt: article.fetchedAt
        )
    }

    public func stableStoryID(
        for article: Article,
        feature: StoryArticleFeature
    ) -> String {
        let eventDate = article.publishedAt ?? article.fetchedAt
        let bucket = Int(floor(
            eventDate.timeIntervalSince1970 / configuration.rollingWindow
        ))
        let identity = feature.canonicalURL.flatMap { $0.isEmpty ? nil : $0 }
            ?? feature.normalizedTitle
        let seed = "\(identity)\n\(bucket)"
        return "story-\(Self.fnv1a64(seed))"
    }

    public func decide(
        article: Article,
        feature: StoryArticleFeature,
        candidates: [StoryClusterCandidate]
    ) -> StoryClusterDecision {
        let eventDate = article.publishedAt ?? article.fetchedAt
        let eligible = candidates.filter {
            let candidateDate = $0.article.publishedAt ?? $0.article.fetchedAt
            return abs(eventDate.timeIntervalSince(candidateDate)) <= configuration.rollingWindow
        }

        var bestMatch: (StoryClusterCandidate, StoryMembershipType, Double)?
        var bestBorderline: (StoryClusterCandidate, Double)?
        for candidate in eligible {
            let exact = exactMatch(feature, candidate.feature)
            if exact {
                if shouldReplace(
                    candidate: candidate,
                    confidence: 1,
                    current: bestMatch.map { ($0.0, $0.2) }
                ) {
                    bestMatch = (candidate, .duplicate, 1)
                }
                continue
            }

            let titleSimilarity = Self.jaccard(
                Self.significantTerms(feature.normalizedTitle),
                Self.significantTerms(candidate.feature.normalizedTitle)
            )
            let lexicalSimilarity = Self.cosine(
                feature.tokens,
                candidate.feature.tokens
            )
            let confidence = min(
                1,
                max(0, (0.65 * lexicalSimilarity) + (0.35 * titleSimilarity))
            )
            guard entityGuard(feature, candidate.feature) else { continue }

            let membershipType: StoryMembershipType?
            if confidence >= configuration.duplicateThreshold,
               titleSimilarity >= 0.78
            {
                membershipType = .duplicate
            } else if confidence >= configuration.coverageThreshold,
                      titleSimilarity >= 0.45
            {
                membershipType = isUpdate(
                    article: article,
                    feature: feature,
                    candidate: candidate
                ) ? .update : .coverage
            } else {
                membershipType = nil
            }

            if let membershipType {
                if shouldReplace(
                    candidate: candidate,
                    confidence: confidence,
                    current: bestMatch.map { ($0.0, $0.2) }
                ) {
                    bestMatch = (candidate, membershipType, confidence)
                }
            } else if confidence >= configuration.borderlineThreshold,
                      shouldReplace(
                        candidate: candidate,
                        confidence: confidence,
                        current: bestBorderline
                      )
            {
                bestBorderline = (candidate, confidence)
            }
        }

        if let (candidate, membershipType, confidence) = bestMatch {
            return StoryClusterDecision(match: StoryClusterMatch(
                storyID: candidate.storyID,
                membershipType: membershipType,
                confidence: confidence,
                matchedArticleID: candidate.article.id
            ))
        }
        if let (candidate, confidence) = bestBorderline {
            return StoryClusterDecision(borderline: StoryBorderlineMatch(
                candidateStoryID: candidate.storyID,
                articleID: article.id,
                matchedArticleID: candidate.article.id,
                confidence: confidence,
                reason: "lexical_similarity_requires_arbitration",
                featureVersion: feature.featureVersion,
                createdAt: article.publishedAt ?? article.fetchedAt
            ))
        }
        return StoryClusterDecision()
    }

    public func rank(
        _ candidates: [StoryRankingCandidate],
        asOf: Date,
        configuration: StoryRankingConfiguration = StoryRankingConfiguration()
    ) -> StoryRankingResult {
        let scored = candidates
            .filter { !$0.isHidden }
            .map { candidate -> (StoryRankingCandidate, RankedStory) in
                let age = max(0, asOf.timeIntervalSince(candidate.story.lastActivityAt))
                let recency = max(
                    0,
                    1 - (age / max(1, configuration.recencyWindow))
                ) * 4
                let sourceScore = log(
                    Double(max(0, candidate.distinctFeedCount)) + 1
                ) * 3
                let score = sourceScore + recency + candidate.preferenceSignal
                let unique = candidate.distinctFeedCount == 1
                    && candidate.articleCount == 1
                let reason = unique
                    ? "unique_single_source"
                    : "\(candidate.distinctFeedCount)_independent_sources"
                return (candidate, RankedStory(
                    storyID: candidate.story.id,
                    score: score,
                    distinctFeedCount: candidate.distinctFeedCount,
                    rawArticleCount: candidate.articleCount,
                    isUniqueFind: unique,
                    reason: reason
                ))
            }
            .sorted {
                if $0.1.score != $1.1.score { return $0.1.score > $1.1.score }
                if $0.0.story.lastActivityAt != $1.0.story.lastActivityAt {
                    return $0.0.story.lastActivityAt > $1.0.story.lastActivityAt
                }
                return $0.0.story.id < $1.0.story.id
            }

        var feedCounts: [String: Int] = [:]
        var topStories: [RankedStory] = []
        for (candidate, ranked) in scored
        where !(candidate.distinctFeedCount == 1 && candidate.articleCount == 1) {
            let count = feedCounts[candidate.representativeFeedID, default: 0]
            guard count < configuration.maximumStoriesPerRepresentativeFeed else { continue }
            topStories.append(ranked)
            feedCounts[candidate.representativeFeedID] = count + 1
            if topStories.count == configuration.topStoryLimit { break }
        }

        let uniqueFinds = scored
            .filter {
                $0.0.distinctFeedCount == 1 && $0.0.articleCount == 1
            }
            .prefix(max(0, configuration.uniqueFindLimit))
            .map(\.1)

        return StoryRankingResult(topStories: topStories, uniqueFinds: uniqueFinds)
    }

    public static func canonicalArticleURL(_ url: URL?) -> String? {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "http" && components.port == 80)
            || (components.scheme == "https" && components.port == 443)
        {
            components.port = nil
        }
        let trackingKeys = Set([
            "dclid", "fbclid", "gclid", "mc_cid", "mc_eid", "ref", "ref_src",
            "referrer", "source"
        ])
        components.queryItems = components.queryItems?
            .filter {
                let name = $0.name.lowercased()
                return !name.hasPrefix("utm_") && !trackingKeys.contains(name)
            }
            .sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return ($0.value ?? "") < ($1.value ?? "")
            }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        if components.path.count > 1 {
            while components.path.hasSuffix("/") {
                components.path.removeLast()
            }
        } else if components.path == "/" {
            components.path = ""
        }
        return components.string
    }

    public static func normalizeTitle(_ title: String) -> String {
        var titleWithoutPublisher = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let separators = [" | ", " — ", " – "]
        var trailingSeparator: Range<String.Index>?
        for separator in separators {
            if let range = titleWithoutPublisher.range(
                of: separator,
                options: .backwards
            ), trailingSeparator == nil
                || range.lowerBound > trailingSeparator!.lowerBound
            {
                trailingSeparator = range
            }
        }
        if let range = trailingSeparator {
            let suffix = titleWithoutPublisher[range.upperBound...]
            if suffix.split(separator: " ").count <= 4 {
                titleWithoutPublisher = String(
                    titleWithoutPublisher[..<range.lowerBound]
                )
            }
        }
        return normalizeText(titleWithoutPublisher)
    }

    public static func normalizeText(_ text: String) -> String {
        let lowercased = text.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
        let scalars = lowercased.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    public static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Shared desktop/native stable ID contract: FNV-1a 64, lowercase and
    /// zero-padded to exactly 16 hexadecimal digits.
    public static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func exactMatch(
        _ lhs: StoryArticleFeature,
        _ rhs: StoryArticleFeature
    ) -> Bool {
        if let leftURL = lhs.canonicalURL,
           let rightURL = rhs.canonicalURL,
           !leftURL.isEmpty,
           leftURL == rightURL
        {
            return true
        }
        return !lhs.normalizedTitle.isEmpty
            && lhs.normalizedTitle == rhs.normalizedTitle
    }

    private func entityGuard(
        _ lhs: StoryArticleFeature,
        _ rhs: StoryArticleFeature
    ) -> Bool {
        let leftEntities = Set(lhs.entities)
        let rightEntities = Set(rhs.entities)
        return leftEntities.isEmpty
            || rightEntities.isEmpty
            || !leftEntities.isDisjoint(with: rightEntities)
    }

    private func isUpdate(
        article: Article,
        feature: StoryArticleFeature,
        candidate: StoryClusterCandidate
    ) -> Bool {
        let articleDate = article.publishedAt ?? article.fetchedAt
        let candidateDate = candidate.article.publishedAt ?? candidate.article.fetchedAt
        guard articleDate >= candidateDate else { return false }
        let markers = Set([
            "after", "confirmed", "latest", "now", "update"
        ])
        let currentTokens = Set(feature.tokens)
        let previousTokens = Set(candidate.feature.tokens)
        let novelCount = currentTokens.subtracting(previousTokens).count
        let novelty = Double(novelCount) / Double(max(1, currentTokens.count))
        return !currentTokens.isDisjoint(with: markers) || novelty >= 0.30
    }

    private static func entities(in title: String) -> [String] {
        let words = title.split(whereSeparator: \.isWhitespace)
        var entities = Set<String>()
        for (index, rawWord) in words.enumerated() {
            let word = rawWord.trimmingCharacters(in: .punctuationCharacters)
            guard word.count >= 3 else { continue }
            let allUppercase = word.unicodeScalars
                .filter { CharacterSet.letters.contains($0) }
                .allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
            let capitalized = word.first?.isUppercase == true
                && (index > 0 || allUppercase)
            if capitalized {
                let normalized = normalizeText(word)
                if !normalized.isEmpty, !stopWords.contains(normalized) {
                    entities.insert(normalized)
                }
            }
        }
        return entities.sorted()
    }

    private func shouldReplace(
        candidate: StoryClusterCandidate,
        confidence: Double,
        current: (StoryClusterCandidate, Double)?
    ) -> Bool {
        guard let current else { return true }
        if confidence != current.1 { return confidence > current.1 }
        if candidate.storyID != current.0.storyID {
            return candidate.storyID < current.0.storyID
        }
        return candidate.article.id < current.0.article.id
    }

    private static func significantTerms(_ text: String) -> [String] {
        normalizeText(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    private static func cosine(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var leftCounts: [String: Int] = [:]
        var rightCounts: [String: Int] = [:]
        lhs.forEach { leftCounts[$0, default: 0] += 1 }
        rhs.forEach { rightCounts[$0, default: 0] += 1 }
        let dot = leftCounts.reduce(0.0) {
            $0 + Double($1.value * (rightCounts[$1.key] ?? 0))
        }
        let leftMagnitude = sqrt(
            leftCounts.values.reduce(0.0) { $0 + Double($1 * $1) }
        )
        let rightMagnitude = sqrt(
            rightCounts.values.reduce(0.0) { $0 + Double($1 * $1) }
        )
        return dot / (leftMagnitude * rightMagnitude)
    }

    private static func jaccard(_ lhs: [String], _ rhs: [String]) -> Double {
        let left = Set(lhs)
        let right = Set(rhs)
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(left.intersection(right).count) / Double(union)
    }

    private static let stopWords: Set<String> = [
        "about", "after", "again", "against", "also", "and", "are", "but",
        "for", "from", "has", "have", "how", "into", "its", "more", "new",
        "not", "over", "says", "that", "the", "their", "this", "was", "were",
        "what", "when", "where", "which", "who", "why", "will", "with", "you",
        "your"
    ]
}
