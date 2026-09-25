import Foundation
import CryptoKit
import SkimStoryPolicy

public struct TodayPreparationStatus: Codable, Sendable {
    public var scopeKey: String
    public var eligibleCount: Int
    public var assessedCount: Int
    public var assessmentFailedCount: Int
    public var proposalWindowCount: Int
    public var proposalCompletedCount: Int
    public var proposalFailedCount: Int
    public var proposedPairCount: Int
    public var verifiedPairCount: Int
    public var verificationFailedCount: Int
    public var state: String
    public var manifest: String
    public var canPublish: Bool
    public var activeEditionID: String?
}

public struct TodayPreparationRequest: Sendable {
    public let instructions: String
    public let payload: String
    public let maxTokens: Int
}

public typealias TodayPreparationInference = @Sendable (TodayPreparationRequest) async throws -> String

public enum TodayPreparationPolicy {
    public static var version: UInt32 { skim_preparation_version() }
    public static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    struct Report: Codable, Sendable {
        let activity_date: String
        let excerpt: String
        let title: String
    }
    static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    static func report(_ candidate: TodayEditionCandidate, formatter: DateFormatter? = nil) -> Report {
        let formatter = formatter ?? dateFormatter()
        let article = candidate.sourceArticles.first { $0.article.id == candidate.revision.representativeArticleID }?.article
        return Report(activity_date: formatter.string(from: candidate.ranking.story.lastActivityAt),
            excerpt: TodaySemanticPolicy.boundedEvidence(article?.contentText, fallback: candidate.revision.summary),
            title: String(candidate.revision.title.unicodeScalars.prefix(240)))
    }
    static func assessment(_ report: Report) throws -> TodayPreparationRequest {
        TodayPreparationRequest(instructions: String(cString: skim_preparation_assessment_prompt()), payload: try json(report), maxTokens: Int(skim_preparation_assessment_output_tokens()))
    }
    static func proposal(_ reports: [Report]) throws -> TodayPreparationRequest {
        struct Indexed: Encodable { let index: Int; let activity_date: String; let excerpt: String; let title: String }
        struct Payload: Encodable { let reports: [Indexed] }
        return TodayPreparationRequest(instructions: String(cString: skim_preparation_proposal_prompt()),
            payload: try json(Payload(reports: reports.enumerated().map { Indexed(index: $0.offset, activity_date: $0.element.activity_date, excerpt: $0.element.excerpt, title: $0.element.title) })), maxTokens: Int(skim_preparation_proposal_output_tokens()))
    }
    static func pair(_ a: Report, _ b: Report) throws -> TodayPreparationRequest {
        struct Payload: Encodable { let report_a: Report; let report_b: Report }
        return TodayPreparationRequest(instructions: TodaySemanticPolicy.pairPrompt, payload: try json(Payload(report_a: a, report_b: b)), maxTokens: TodaySemanticPolicy.pairOutputTokens)
    }
    static func taskKey(_ request: TodayPreparationRequest, inference: String) -> String {
        hash("\(version)\n\(inference)\n\(request.instructions)\n\(request.payload)\n\(request.maxTokens)")
    }
    static func validate(_ response: String, kind: String, count: Int) throws -> [Int32] {
        let bytes = Array(response.utf8)
        if kind == "proposal" {
            var labels = [Int32](repeating: -1, count: count)
            let result = bytes.withUnsafeBufferPointer { input in labels.withUnsafeMutableBufferPointer { output in
                skim_preparation_proposal_labels(input.baseAddress, input.count, count, output.baseAddress, output.count)
            } }
            guard result > 0 else { throw SkimCoreError.database("Invalid related-report response") }
            return labels
        }
        let value = bytes.withUnsafeBufferPointer { input in
            kind == "assessment" ? skim_preparation_assessment_verdict(input.baseAddress, input.count)
                : skim_semantic_pair_verdict(input.baseAddress, input.count)
        }
        guard value >= 0 else { throw SkimCoreError.database("Invalid preparation response") }
        return [value]
    }
}
