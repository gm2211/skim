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
    public var needsRating: Bool

    enum CodingKeys: String, CodingKey { case members, importance, confidence, reason }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        members = try values.decode([Double].self, forKey: .members)
        importance = try values.decode(Double.self, forKey: .importance)
        confidence = try values.decode(Double.self, forKey: .confidence)
        reason = try values.decode(String.self, forKey: .reason)
        needsRating = false
    }

    public init(members: [Double], importance: Double, confidence: Double, reason: String, needsRating: Bool = false) {
        self.members = members
        self.importance = importance
        self.confidence = confidence
        self.reason = reason
        self.needsRating = needsRating
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

    public struct VerificationPlan: Sendable {
        public let payload: String
        public let pairs: [[Int]]
        fileprivate let groups: [TodaySemanticGroup]
        fileprivate let candidateCount: Int
    }

    public static var pairPrompt: String { String(cString: skim_semantic_pair_prompt()) }

    public static func verificationPlan(groups: [TodaySemanticGroup], candidates: [TodaySemanticCandidate]) throws -> VerificationPlan {
        guard !candidates.isEmpty, candidates.count <= maximumCandidates,
              candidates.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.timestamp.isFinite })
        else { throw SkimCoreError.database("Invalid semantic verification candidates") }
        var assigned = [UInt8](repeating: 0, count: candidates.count)
        var accepted: [TodaySemanticGroup] = []
        var pairs: [[Int]] = []
        for group in groups {
            let valid = group.members.withUnsafeBufferPointer { members in
                assigned.withUnsafeBufferPointer { used in
                    skim_semantic_group_valid(members.baseAddress, members.count, candidates.count,
                        used.baseAddress, used.count, group.importance, group.confidence) != 0
                }
            }
            guard valid, !group.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  group.reason.count <= 280 else { continue }
            let indexes = group.members.map(Int.init).sorted()
            for (offset, left) in indexes.enumerated() {
                for right in indexes.dropFirst(offset + 1) { pairs.append([left, right]) }
            }
            guard pairs.count <= Int(skim_semantic_max_pairs()) else {
                throw SkimCoreError.database("Semantic verification pair budget exceeded")
            }
            accepted.append(group)
            for index in indexes { assigned[index] = 1 }
        }
        struct Report: Encodable {
            let index: Int
            let title: String
            let excerpt: String
            let activity_date: String
        }
        struct Payload: Encodable { let reports: [Report]; let pairs: [[Int]] }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let reports = candidates.map { candidate in
            Report(index: candidate.index, title: candidate.title, excerpt: candidate.excerpt,
                activity_date: formatter.string(from: Date(timeIntervalSince1970: candidate.timestamp)))
        }
        let data = try JSONEncoder().encode(Payload(reports: reports, pairs: pairs))
        return VerificationPlan(payload: String(decoding: data, as: UTF8.self), pairs: pairs,
            groups: accepted, candidateCount: candidates.count)
    }

    public static func verify(response: String, plan: VerificationPlan) throws -> [TodaySemanticGroup] {
        guard !plan.pairs.isEmpty else { return plan.groups }
        struct Decision: Decodable {
            let members: [Double]
            let same_event: Bool
            let confidence: Double

            enum CodingKeys: String, CodingKey { case members, pair, same_event, confidence }
            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                guard values.contains(.members) != values.contains(.pair) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                        debugDescription: "Exactly one pair identity key is required"))
                }
                members = try values.decode([Double].self, forKey: values.contains(.members) ? .members : .pair)
                same_event = try values.decode(Bool.self, forKey: .same_event)
                confidence = try values.decode(Double.self, forKey: .confidence)
            }
        }
        struct Envelope: Decodable { let pairs: [Decision] }
        let text = unfenced(response)
        let data = Data(text.utf8)
        let decisions: [Decision]
        if text.hasPrefix("[") {
            decisions = try JSONDecoder().decode([Decision].self, from: data)
        } else {
            decisions = try JSONDecoder().decode(Envelope.self, from: data).pairs
        }
        let requested = Set(plan.pairs.map { $0[0] * plan.candidateCount + $0[1] })
        var answered = Set<Int>()
        var verified = [UInt8](repeating: 0, count: plan.candidateCount * plan.candidateCount)
        for decision in decisions {
            guard decision.members.count == 2,
                  decision.members.allSatisfy({ $0.isFinite && $0.rounded(.towardZero) == $0 && $0 >= 0 && $0 < Double(plan.candidateCount) }),
                  decision.confidence.isFinite, (0...1).contains(decision.confidence)
            else { throw SkimCoreError.database("Invalid semantic pair response") }
            let pair = decision.members.map(Int.init).sorted()
            let key = pair[0] * plan.candidateCount + pair[1]
            guard pair[0] != pair[1], requested.contains(key), answered.insert(key).inserted else {
                throw SkimCoreError.database("Unknown or duplicate semantic pair")
            }
            if decision.same_event && decision.confidence >= 0.8 {
                verified[key] = 1
                verified[pair[1] * plan.candidateCount + pair[0]] = 1
            }
        }
        guard answered == requested else { throw SkimCoreError.database("Incomplete semantic pair response") }
        return try plan.groups.flatMap { group in
            var labels = [Int32](repeating: -1, count: group.members.count)
            let count = group.members.withUnsafeBufferPointer { members in
                verified.withUnsafeBufferPointer { matrix in
                    labels.withUnsafeMutableBufferPointer { output in
                        skim_semantic_partition(members.baseAddress, members.count, plan.candidateCount,
                            matrix.baseAddress, matrix.count, output.baseAddress, output.count)
                    }
                }
            }
            guard count > 0 else { throw SkimCoreError.database("Invalid semantic partition") }
            return (0..<count).map { label in
                TodaySemanticGroup(members: group.members.enumerated().filter { labels[$0.offset] == label }.map(\.element),
                    importance: count > 1 ? 3 : group.importance, confidence: group.confidence,
                    reason: count > 1 ? "From your feeds" : group.reason, needsRating: count > 1)
            }
        }
    }

    private static func unfenced(_ response: String) -> String {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json") || text.hasPrefix("```") {
            let body = String(text.dropFirst(text.hasPrefix("```json") ? 7 : 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasSuffix("```") {
                return String(body.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    public struct RatingPlan: Sendable {
        public let payload: String
        fileprivate let groups: [TodaySemanticGroup]
        fileprivate let expected: Set<Int>
    }

    public static var ratingPrompt: String { String(cString: skim_semantic_rating_prompt()) }

    public static func ratingPlan(groups: [TodaySemanticGroup], candidates: [TodaySemanticCandidate], groupID: Int? = nil) throws -> RatingPlan? {
        let expected = Set(groups.indices.filter { groups[$0].needsRating && (groupID == nil || $0 == groupID) })
        guard !expected.isEmpty else { return nil }
        guard candidates.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.timestamp.isFinite }) else {
            throw SkimCoreError.database("Invalid semantic rating candidates")
        }
        struct Report: Encodable { let index: Int; let title: String; let excerpt: String; let activity_date: String }
        struct Group: Encodable { let group_id: Int; let reports: [Report] }
        struct Payload: Encodable { let groups: [Group] }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let entries = try expected.sorted().map { index in
            let reports = try groups[index].members.map { member in
                guard member.isFinite, member.rounded(.towardZero) == member, member >= 0, member < Double(candidates.count) else {
                    throw SkimCoreError.database("Invalid semantic rating member")
                }
                let candidate = candidates[Int(member)]
                return Report(index: candidate.index, title: candidate.title, excerpt: candidate.excerpt,
                    activity_date: formatter.string(from: Date(timeIntervalSince1970: candidate.timestamp)))
            }
            return Group(group_id: index, reports: reports)
        }
        let data = try JSONEncoder().encode(Payload(groups: entries))
        return RatingPlan(payload: String(decoding: data, as: UTF8.self), groups: groups, expected: expected)
    }

    public static func rate(response: String, plan: RatingPlan) throws -> [TodaySemanticGroup] {
        struct Rating: Decodable { let group_id: Double; let importance: Double; let confidence: Double; let reason: String }
        struct Envelope: Decodable { let ratings: [Rating] }
        let ratings = try JSONDecoder().decode(Envelope.self, from: Data(unfenced(response).utf8)).ratings
        var seen = Set<Int>()
        var result = plan.groups
        for rating in ratings {
            let reason = rating.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rating.group_id.isFinite, rating.group_id.rounded(.towardZero) == rating.group_id,
                  rating.group_id >= 0, rating.group_id < Double(result.count),
                  skim_semantic_rating_valid(rating.importance, rating.confidence) != 0,
                  !reason.isEmpty, reason.count <= 280 else { throw SkimCoreError.database("Invalid semantic rating") }
            let index = Int(rating.group_id)
            guard plan.expected.contains(index), seen.insert(index).inserted else {
                throw SkimCoreError.database("Unknown or duplicate semantic rating")
            }
            result[index].importance = rating.importance
            result[index].confidence = rating.confidence
            result[index].reason = reason
            result[index].needsRating = false
        }
        guard seen == plan.expected else { throw SkimCoreError.database("Incomplete semantic ratings") }
        return result
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
