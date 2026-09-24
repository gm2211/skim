import Foundation
import SkimStoryPolicy

public struct TodaySemanticCandidate: Codable, Sendable {
    public var index: Int
    public var title: String
    public var excerpt: String
    public var timestamp: Double
    public var baseScore: Double
}

public struct TodaySemanticGroup: Codable, Sendable {
    public var members: [Double]
    public var importance: Double
    public var confidence: Double
    public var reason: String

    public init(members: [Double], importance: Double, confidence: Double, reason: String) {
        self.members = members
        self.importance = importance
        self.confidence = confidence
        self.reason = reason
    }
}

public typealias TodaySemanticEvaluator = @Sendable ([TodaySemanticCandidate]) async throws -> [TodaySemanticGroup]

struct TodayStoryRevisionReference: Sendable {
    var storyID: String
    var revisionNumber: Int
}

public enum TodaySemanticPolicy {
    public static var prompt: String { String(cString: skim_semantic_prompt()) }
    public static var maximumCandidates: Int { Int(skim_semantic_max_candidates()) }

    public static func decode(_ text: String) throws -> [TodaySemanticGroup] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let objectText: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
            objectText = String(trimmed[start...end])
        } else { objectText = trimmed }
        let object = try JSONSerialization.jsonObject(with: Data(objectText.utf8))
        guard let response = object as? [String: Any], let groups = response["groups"] as? [Any] else {
            throw SkimCoreError.database("Invalid semantic Today response")
        }
        return groups.compactMap { value in
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  var group = try? JSONDecoder().decode(TodaySemanticGroup.self, from: data)
            else { return nil }
            group.reason = group.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !group.reason.isEmpty, group.reason.count <= 280 else { return nil }
            return group
        }
    }

    static func inputs(_ candidates: [TodayEditionCandidate], at date: Date) -> [TodaySemanticCandidate] {
        candidates.enumerated().map { index, candidate in
            let ranked = StoryClusterer().rank([candidate.ranking], asOf: date)
            let score = (ranked.topStories + ranked.uniqueFinds).first?.score ?? 0
            return TodaySemanticCandidate(index: index, title: String(candidate.revision.title.prefix(240)),
                excerpt: String(candidate.revision.summary.prefix(240)),
                timestamp: candidate.ranking.story.lastActivityAt.timeIntervalSince1970, baseScore: score)
        }
    }

    static func apply(_ groups: [TodaySemanticGroup], to candidates: [TodayEditionCandidate], at date: Date) -> [TodayEditionCandidate]? {
        guard !candidates.isEmpty, candidates.count <= maximumCandidates else { return nil }
        let inputs = inputs(candidates, at: date)
        var assigned = [UInt8](repeating: 0, count: candidates.count)
        var result: [TodayEditionCandidate] = []
        for group in groups {
            let valid = group.members.withUnsafeBufferPointer { members in
                assigned.withUnsafeBufferPointer { used in
                    skim_semantic_group_valid(members.baseAddress, members.count, candidates.count,
                        used.baseAddress, used.count, group.importance, group.confidence) != 0
                }
            }
            guard valid, !group.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  group.reason.count <= 280 else { continue }
            let indexes = group.members.map(Int.init)
            // Keep identity and headline from an existing story; no model-created references.
            let anchor = indexes.sorted {
                if inputs[$0].baseScore != inputs[$1].baseScore { return inputs[$0].baseScore > inputs[$1].baseScore }
                return candidates[$0].ranking.story.id < candidates[$1].ranking.story.id
            }[0]
            var candidate = candidates[anchor]
            var seen = Set<String>()
            candidate.sourceArticles = indexes.flatMap { candidates[$0].sourceArticles }.filter { seen.insert($0.article.id).inserted }
            candidate.memberRevisions = indexes.map {
                TodayStoryRevisionReference(storyID: candidates[$0].ranking.story.id,
                    revisionNumber: candidates[$0].revision.revisionNumber)
            }
            candidate.ranking.distinctFeedCount = Set(candidate.sourceArticles.filter { $0.membership.membershipType != .duplicate }.map(\.article.feedID)).count
            candidate.ranking.articleCount = candidate.sourceArticles.count
            candidate.semanticScore = skim_semantic_score(inputs[anchor].baseScore, group.importance, group.confidence)
            candidate.semanticReason = group.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(candidate)
            for index in indexes { assigned[index] = 1 }
        }
        guard !result.isEmpty else { return nil }
        for index in candidates.indices where assigned[index] == 0 {
            var candidate = candidates[index]
            candidate.semanticScore = inputs[index].baseScore
            result.append(candidate)
        }
        return result
    }

    struct Fingerprint: Equatable {
        var ranking: StoryRankingCandidate
        var revision: StoryRevision
        var sources: [TodayEditionCandidateSource]
    }

    static func fingerprint(_ candidates: [TodayEditionCandidate]) -> [Fingerprint] {
        candidates.map { Fingerprint(ranking: $0.ranking, revision: $0.revision, sources: $0.sourceArticles) }
    }
}
