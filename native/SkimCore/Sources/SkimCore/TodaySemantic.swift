import Foundation
import SkimStoryPolicy

public enum TodayLedePolicy {
    public static var instructions: String { String(cString: skim_today_lede_prompt()) }
    public static var retryInstructions: String { String(cString: skim_today_lede_retry_prompt()) }
    public static var maxArticles: Int { Int(skim_today_lede_max_articles()) }
    public static var textCharacters: Int { Int(skim_today_lede_text_characters()) }
    public static var evidenceVersion: Int { Int(skim_today_lede_evidence_version()) }

    public struct Selection: Sendable, Equatable {
        public let excerpt: String
        public let sourceIndex: Int
        public let evidenceHash: String
    }

    public static func selection(candidate: String, sources: [String]) -> Selection? {
        let excerpt = candidate.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let bytes = Array(excerpt.utf8)
        var joined: [UInt8] = []
        var offsets = [0]
        for source in sources { joined.append(contentsOf: source.utf8); offsets.append(joined.count) }
        let index = joined.withUnsafeBufferPointer { body in
            offsets.withUnsafeBufferPointer { spans in
                bytes.withUnsafeBufferPointer { passage in
                    skim_today_lede_source_index(body.baseAddress, body.count, spans.baseAddress, sources.count, passage.baseAddress, passage.count)
                }
            }
        }
        guard index >= 0, sources.indices.contains(Int(index)) else { return nil }
        return Selection(excerpt: excerpt, sourceIndex: Int(index), evidenceHash: StoryClusterer.sha256(sources[Int(index)]))
    }

    public static func validatedExcerpt(candidate: String, sources: [String]) -> String? {
        selection(candidate: candidate, sources: sources)?.excerpt
    }

    public static func generateSelection(
        sources: [String],
        request: @Sendable (_ instructions: String, _ jsonMode: Bool) async throws -> String
    ) async throws -> Selection? {
        try Task.checkCancellation()
        let primary = try await request(instructions, true)
        try Task.checkCancellation()
        if let excerpt = excerpt(from: primary, sources: sources) {
            return selection(candidate: excerpt, sources: sources)
        }
        let plain = try await request(retryInstructions, false)
        try Task.checkCancellation()
        return selection(candidate: plain, sources: sources)
    }

    /// Retry only a returned but invalid selection, never a failed provider request.
    public static func generateExcerpt(
        sources: [String],
        request: @Sendable (_ instructions: String, _ jsonMode: Bool) async throws -> String
    ) async throws -> String {
        try await generateSelection(sources: sources, request: request)?.excerpt ?? ""
    }

    public static func excerpt(from response: String, sources: [String]) -> String? {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json") || text.hasPrefix("```") {
            let body = String(text.dropFirst(text.hasPrefix("```json") ? 7 : 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasSuffix("```") { text = String(body.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let envelope = object as? [String: Any], Set(envelope.keys) == ["excerpt"],
              let excerpt = envelope["excerpt"] as? String else { return nil }
        return validatedExcerpt(candidate: excerpt, sources: sources)
    }

}

public struct TodaySemanticCandidate: Codable, Sendable {
    public var index: Int
    public var title: String
    public var excerpt: String
    public var timestamp: Double
    public var baseScore: Double
    public var evidence: String? = nil
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
        let object = try JSONSerialization.jsonObject(with: Data(unfenced(text).utf8))
        let groups: [Any]
        if let array = object as? [Any] {
            groups = array
        } else if let response = object as? [String: Any], let array = response["groups"] as? [Any] {
            groups = array
        } else {
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
        public let pairs: [[Int]]
        fileprivate let groups: [TodaySemanticGroup]
        fileprivate let candidateCount: Int
        fileprivate let candidates: [TodaySemanticCandidate]
    }

    public struct VerificationBatch: Sendable {
        public let payload: String
        public let pairs: [[Int]]
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
            accepted.append(group)
            for index in indexes { assigned[index] = 1 }
        }
        return VerificationPlan(pairs: pairs,
            groups: accepted, candidateCount: candidates.count, candidates: candidates)
    }

    public static func verificationBatches(plan: VerificationPlan) throws -> [VerificationBatch] {
        var batches: [VerificationBatch] = []
        var offset = 0
        while offset < plan.pairs.count {
            let length = Int(skim_semantic_pair_batch_length(plan.pairs.count, offset))
            guard length > 0, length <= plan.pairs.count - offset else {
                throw SkimCoreError.database("Invalid semantic pair batch length")
            }
            let pairs = Array(plan.pairs[offset..<(offset + length)])
            let referenced = Set(pairs.flatMap { $0 })
            let reports = plan.candidates.filter { referenced.contains($0.index) }
            batches.append(VerificationBatch(payload: try verificationPayload(pairs: pairs, candidates: reports), pairs: pairs))
            offset += length
        }
        return batches
    }

    public static var evidenceCharacters: Int { Int(skim_semantic_evidence_characters()) }
    public static var pairOutputTokens: Int { Int(skim_semantic_pair_output_tokens()) }

    public static func primaryPayload(candidates: [TodaySemanticCandidate]) throws -> String {
        let primary = candidates.map { candidate in
            var copy = candidate
            copy.evidence = nil
            return copy
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(primary), as: UTF8.self)
    }

    private static func verificationPayload(pairs: [[Int]], candidates: [TodaySemanticCandidate]) throws -> String {
        guard pairs.count == 1, let pair = pairs.first else { throw SkimCoreError.database("Expected one semantic pair") }
        struct Report: Encodable { let title: String; let excerpt: String; let activity_date: String }
        struct Payload: Encodable { let report_a: Report; let report_b: Report }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        func report(_ index: Int) throws -> Report {
            guard let candidate = candidates.first(where: { $0.index == index }) else { throw SkimCoreError.database("Missing semantic pair report") }
            let text = candidate.evidence.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? candidate.excerpt
            return Report(title: candidate.title, excerpt: String(text.unicodeScalars.prefix(evidenceCharacters)),
                activity_date: formatter.string(from: Date(timeIntervalSince1970: candidate.timestamp)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(Payload(report_a: report(pair[0]), report_b: report(pair[1]))), as: UTF8.self)
    }

    /// Validate each completed request before spending another provider call.
    /// This never partitions or publishes groups; final verification remains atomic.
    public static func validateVerificationResponse(_ response: String, batch: VerificationBatch, plan: VerificationPlan) throws {
        _ = try verifiedPairs(response: response, pairs: batch.pairs, candidateCount: plan.candidateCount)
    }

    public static func verify(response: String, plan: VerificationPlan) throws -> [TodaySemanticGroup] {
        try verify(responses: plan.pairs.isEmpty ? [] : [response], plan: plan)
    }

    public static func verify(responses: [String], plan: VerificationPlan) throws -> [TodaySemanticGroup] {
        let batches = try verificationBatches(plan: plan)
        guard responses.count == batches.count else { throw SkimCoreError.database("Incomplete semantic verification batches") }
        var verified = [UInt8](repeating: 0, count: plan.candidateCount * plan.candidateCount)
        for (batch, response) in zip(batches, responses) {
            let matrix = try verifiedPairs(response: response, pairs: batch.pairs, candidateCount: plan.candidateCount)
            for index in matrix.indices where matrix[index] == 1 { verified[index] = 1 }
        }
        return try partition(plan: plan, verified: verified)
    }

    private static func verifiedPairs(response: String, pairs: [[Int]], candidateCount: Int) throws -> [UInt8] {
        guard pairs.count == 1 else { throw SkimCoreError.database("Expected one semantic pair verdict") }
        let bytes = Array(response.utf8)
        let value = bytes.withUnsafeBufferPointer { skim_semantic_pair_verdict($0.baseAddress, $0.count) }
        guard value >= 0 else { throw SkimCoreError.database("Unknown semantic relation") }
        var verified = [UInt8](repeating: 0, count: candidateCount * candidateCount)
        if value == 1 {
            let pair = pairs[0]
            verified[pair[0] * candidateCount + pair[1]] = 1
            verified[pair[1] * candidateCount + pair[0]] = 1
        }
        return verified
    }

    private static func partition(plan: VerificationPlan, verified: [UInt8]) throws -> [TodaySemanticGroup] {
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

    static func boundedEvidence(_ content: String?, fallback: String) -> String {
        let text = content.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? fallback
        return String(text.unicodeScalars.prefix(evidenceCharacters))
    }

    static func inputs(_ candidates: [TodayEditionCandidate], at date: Date) -> [TodaySemanticCandidate] {
        candidates.enumerated().map { index, candidate in
            let ranked = StoryClusterer().rank([candidate.ranking], asOf: date)
            let score = (ranked.topStories + ranked.uniqueFinds).first?.score ?? 0
            return TodaySemanticCandidate(index: index, title: String(candidate.revision.title.prefix(240)),
                excerpt: String(candidate.revision.summary.prefix(240)),
                timestamp: candidate.ranking.story.lastActivityAt.timeIntervalSince1970, baseScore: score,
                evidence: boundedEvidence(candidate.sourceArticles.first(where: { $0.article.id == candidate.revision.representativeArticleID })?.article.contentText,
                    fallback: candidate.revision.summary))
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
