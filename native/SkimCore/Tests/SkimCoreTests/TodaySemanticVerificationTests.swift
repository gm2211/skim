import Foundation
import Testing
import SkimStoryPolicy
@testable import SkimCore

private func reports(_ count: Int) -> [TodaySemanticCandidate] {
    (0..<count).map { TodaySemanticCandidate(index: $0, title: "Report \($0)", excerpt: "Event evidence", timestamp: 1723593600, baseScore: 3) }
}
private func group(_ members: [Double]) -> TodaySemanticGroup {
    TodaySemanticGroup(members: members, importance: 4, confidence: 0.95, reason: "Initial proposed event")
}

// Historical model captures used numeric pair decisions. Translate their recorded
// judgments explicitly to current single-pair verdicts; this is a partition/rating
// regression, not evidence that the current wire request produced those outputs.
func verifyHistoricalDecisions(_ response: String, plan: TodaySemanticPolicy.VerificationPlan) throws -> [TodaySemanticGroup] {
    let raw = try JSONSerialization.jsonObject(with: Data(response.utf8))
    let decisions = try #require((raw as? [[String: Any]]) ?? (raw as? [String: Any])?["pairs"] as? [[String: Any]])
    let responses = try plan.pairs.map { pair -> String in
        let decision = try #require(decisions.first { (($0["members"] ?? $0["pair"]) as? [Int])?.sorted() == pair })
        let positive = decision["same_event"] as? Bool == true && (decision["confidence"] as? Double ?? 0) >= 0.8
        return positive ? #"{"relation":"same_event"}"# : #"{"relation":"different_event"}"#
    }
    return try TodaySemanticPolicy.verify(responses: responses, plan: plan)
}

@Test func verificationPayloadUsesOriginalEvidenceAndNoNumericIdentities() throws {
    var candidates = reports(3)
    let fact = "The actual hearing is October 12."
    candidates[0].evidence = String(repeating: "Background ", count: 40) + fact
    candidates[2].evidence = String(repeating: "🙂", count: 2200)
    let plan = try TodaySemanticPolicy.verificationPlan(groups: [group([2, 0])], candidates: candidates)
    let batch = try #require(try TodaySemanticPolicy.verificationBatches(plan: plan).first)
    #expect(batch.pairs == [[0, 2]])
    let payload = try #require(JSONSerialization.jsonObject(with: Data(batch.payload.utf8)) as? [String: Any])
    #expect(Set(payload.keys) == ["report_a", "report_b"])
    let first = try #require(payload["report_a"] as? [String: String])
    let second = try #require(payload["report_b"] as? [String: String])
    #expect(Set(first.keys) == ["title", "excerpt", "activity_date"])
    #expect(first["excerpt"]?.contains(fact) == true)
    #expect(second["excerpt"]?.unicodeScalars.count == 2048)
    let primary = try TodaySemanticPolicy.primaryPayload(candidates: candidates)
    let primaryRows = try #require(JSONSerialization.jsonObject(with: Data(primary.utf8)) as? [[String: Any]])
    #expect(primaryRows.allSatisfy { $0["evidence"] == nil })
    #expect(!primary.contains(fact))
    #expect(TodaySemanticPolicy.boundedEvidence(" ", fallback: fact) == fact)
    #expect(TodaySemanticPolicy.boundedEvidence("  Original text \n", fallback: fact) == "  Original text \n")
}

@Test func verificationMatchesSharedVerdictFixture() throws {
    struct Fixture: Decodable { let name: String; let response: String; let relation: Int }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/semantic-pair-verdicts.json")))
    let plan = try TodaySemanticPolicy.verificationPlan(groups: [group([0, 1])], candidates: reports(2))
    for fixture in fixtures {
        if fixture.relation < 0 {
            #expect(throws: (any Error).self) { try TodaySemanticPolicy.verify(response: fixture.response, plan: plan) }
        } else {
            let result = try TodaySemanticPolicy.verify(response: fixture.response, plan: plan)
            #expect(result.count == (fixture.relation == 1 ? 1 : 2), Comment(rawValue: fixture.name))
        }
    }
}

@Test func verificationPartitionsNontransitiveTriangleConservatively() throws {
    let plan = try TodaySemanticPolicy.verificationPlan(groups: [group([2, 0, 1])], candidates: reports(3))
    let result = try TodaySemanticPolicy.verify(responses: [#"{"relation":"same_event"}"#, #"{"relation":"different_event"}"#, #"{"relation":"same_event"}"#], plan: plan)
    #expect(result.map { Set($0.members) } == [Set([0.0, 1.0]), Set([2.0])])
    #expect(result.allSatisfy { $0.reason == "From your feeds" && $0.importance == 3 && $0.needsRating })
}

@Test func uncertainPairsSplitAndSingletonsNeedNoSecondCall() throws {
    let single = try TodaySemanticPolicy.verificationPlan(groups: [group([0])], candidates: reports(2))
    #expect(try TodaySemanticPolicy.verificationBatches(plan: single).isEmpty)
    #expect(try TodaySemanticPolicy.verify(response: "", plan: single).count == 1)
    let pair = try TodaySemanticPolicy.verificationPlan(groups: [group([0, 1])], candidates: reports(2))
    #expect(try TodaySemanticPolicy.verify(response: #"{"relation":"uncertain"}"#, plan: pair).count == 2)
}

@Test func verificationRejectsOverlappingInitialGroups() throws {
    let plan = try TodaySemanticPolicy.verificationPlan(groups: [group([0, 99]), group([0, 1]), group([1, 2])], candidates: reports(3))
    #expect(plan.pairs == [[0, 1]])
}

@Test func recordedModelResponsesPreserveEventsCoverageAndImportance() throws {
    struct Constraint: Decodable { let higher: [Int]; let lower: [Int] }
    struct Fixture: Decodable {
        let name: String
        let candidates: [TodaySemanticCandidate]
        let primary_response: String
        let verification_response: String
        let rating_responses: [String]
        let expected_groups: [[Int]]
        let importance_constraints: [Constraint]
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/semantic-verification-responses.json")))
    for fixture in fixtures {
        let primary = try TodaySemanticPolicy.decode(fixture.primary_response)
        let plan = try TodaySemanticPolicy.verificationPlan(groups: primary, candidates: fixture.candidates)
        var verified = try verifyHistoricalDecisions(fixture.verification_response, plan: plan)
        #expect(verified.filter(\.needsRating).allSatisfy { $0.importance == 3 && $0.reason == "From your feeds" })
        let ratingIDs = verified.indices.filter { verified[$0].needsRating }
        try #require(fixture.rating_responses.count == ratingIDs.count)
        for (groupID, response) in zip(ratingIDs, fixture.rating_responses) {
            let ratingPlan = try #require(try TodaySemanticPolicy.ratingPlan(groups: verified, candidates: fixture.candidates, groupID: groupID))
            verified = try TodaySemanticPolicy.rate(response: response, plan: ratingPlan)
        }
        #expect(verified.allSatisfy { !$0.needsRating })
        let actual = verified.map { $0.members.map(Int.init).sorted() }.sorted { $0.lexicographicallyPrecedes($1) }
        let expected = fixture.expected_groups.map { $0.sorted() }.sorted { $0.lexicographicallyPrecedes($1) }
        #expect(actual == expected, Comment(rawValue: fixture.name))
        let allHandles = actual.flatMap { $0 }
        #expect(allHandles.sorted() == fixture.candidates.map(\.index).sorted())
        #expect(Set(allHandles).count == allHandles.count)
        for constraint in fixture.importance_constraints {
            for high in constraint.higher {
                for low in constraint.lower {
                    let highGroup = try #require(verified.first { $0.members.contains(Double(high)) })
                    let lowGroup = try #require(verified.first { $0.members.contains(Double(low)) })
                    #expect(highGroup.importance > lowGroup.importance, Comment(rawValue: fixture.name))
                }
            }
        }
    }
}

@Test func splitStoriesReceiveIndependentRatingsWithoutChangingMembership() throws {
    let verification = try TodaySemanticPolicy.verificationPlan(groups: [group([0, 1]), group([2])], candidates: reports(3))
    let neutral = try TodaySemanticPolicy.verify(response: #"{"relation":"different_event"}"#, plan: verification)
    #expect(neutral.map(\.importance) == [3, 3, 4])
    let plan = try #require(try TodaySemanticPolicy.ratingPlan(groups: neutral, candidates: reports(3)))
    let payload = try #require(JSONSerialization.jsonObject(with: Data(plan.payload.utf8)) as? [String: Any])
    let groups = try #require(payload["groups"] as? [[String: Any]])
    #expect(groups.count == 2)
    #expect(groups.compactMap { $0["group_id"] as? Int } == [0, 1])
    #expect(groups.allSatisfy { Set($0.keys) == ["group_id", "reports"] })
    let source = try #require((groups[0]["reports"] as? [[String: Any]])?.first)
    #expect(Set(source.keys) == ["index", "title", "excerpt", "activity_date"])
    let rated = try TodaySemanticPolicy.rate(response: #"{"ratings":[{"group_id":1,"importance":1,"confidence":0.9,"reason":" Routine report "},{"group_id":0,"importance":5,"confidence":1,"reason":"Urgent public warning"}]}"#, plan: plan)
    let encodedRatings = #"{"ratings":[{"group_id":0,"importance":5,"confidence":1,"reason":"Urgent"},{"group_id":1,"importance":1,"confidence":1,"reason":"Routine"}]}"#
    let fenced = try TodaySemanticPolicy.rate(response: "```json\n\(encodedRatings)\n```", plan: plan)
    #expect(fenced.map(\.importance) == [5, 1, 4])
    #expect(rated.map(\.members) == neutral.map(\.members))
    #expect(rated.map(\.importance) == [5, 1, 4])
    #expect(rated.map(\.reason) == ["Urgent public warning", "Routine report", "Initial proposed event"])
    #expect(rated.allSatisfy { !$0.needsRating })
    #expect(try TodaySemanticPolicy.ratingPlan(groups: rated, candidates: reports(3)) == nil)
}

@Test func malformedRatingsRejectAtomicallyAndCannotInjectRatingMarker() throws {
    let verification = try TodaySemanticPolicy.verificationPlan(groups: [group([0, 1])], candidates: reports(2))
    let neutral = try TodaySemanticPolicy.verify(response: #"{"relation":"different_event"}"#, plan: verification)
    let plan = try #require(try TodaySemanticPolicy.ratingPlan(groups: neutral, candidates: reports(2)))
    let valid = #"{"group_id":0,"importance":5,"confidence":1,"reason":"Urgent"}"#
    for invalid in [
        #"{"group_id":0,"importance":1,"confidence":1,"reason":"Duplicate"}"#,
        #"{"group_id":2,"importance":1,"confidence":1,"reason":"Foreign"}"#,
        #"{"group_id":1.5,"importance":1,"confidence":1,"reason":"Fractional"}"#,
        #"{"group_id":true,"importance":1,"confidence":1,"reason":"Boolean"}"#,
        #"{"group_id":1,"importance":6,"confidence":1,"reason":"Range"}"#,
        #"{"group_id":1,"importance":true,"confidence":1,"reason":"Boolean"}"#,
        #"{"group_id":1,"importance":1,"confidence":0.79,"reason":"Uncertain"}"#,
        #"{"group_id":1,"importance":1,"confidence":1.1,"reason":"Range"}"#,
        #"{"group_id":1,"importance":1,"confidence":true,"reason":"Boolean"}"#,
        #"{"group_id":1,"importance":1,"confidence":1,"reason":"  "}"#,
        "{\"group_id\":1,\"importance\":1,\"confidence\":1,\"reason\":\"\(String(repeating: "x", count: 281))\"}"
    ] {
        #expect(throws: (any Error).self) { try TodaySemanticPolicy.rate(response: "{\"ratings\":[\(valid),\(invalid)]}", plan: plan) }
    }
    for response in ["{\"ratings\":[\(valid)]}", "[]", "Prose {\"ratings\":[]}"] {
        #expect(throws: (any Error).self) { try TodaySemanticPolicy.rate(response: response, plan: plan) }
    }
    #expect(neutral.allSatisfy { $0.importance == 3 && $0.reason == "From your feeds" && $0.needsRating })
    let injected = try TodaySemanticPolicy.decode(#"{"groups":[{"members":[0],"importance":4,"confidence":1,"reason":"Existing","needsRating":true}]}"#)
    #expect(injected[0].needsRating == false)
    #expect(try TodaySemanticPolicy.ratingPlan(groups: injected, candidates: reports(2)) == nil)
}

@Test func isolatedRatingRequestsContainOnlyTheSelectedEventAndRetainAccumulatedResults() throws {
    let verification = try TodaySemanticPolicy.verificationPlan(groups: [group([0, 1]), group([2])], candidates: reports(3))
    let neutral = try TodaySemanticPolicy.verify(response: #"{"relation":"different_event"}"#, plan: verification)
    var accumulated = neutral
    for index in [0, 1] {
        let plan = try #require(try TodaySemanticPolicy.ratingPlan(groups: accumulated, candidates: reports(3), groupID: index))
        let payload = try #require(JSONSerialization.jsonObject(with: Data(plan.payload.utf8)) as? [String: Any])
        let groups = try #require(payload["groups"] as? [[String: Any]])
        #expect(groups.count == 1)
        #expect(groups[0]["group_id"] as? Int == index)
        let included = try #require(groups[0]["reports"] as? [[String: Any]])
        #expect(included.compactMap { $0["index"] as? Int } == [index])
        let importance = index == 0 ? 5 : 1
        accumulated = try TodaySemanticPolicy.rate(response: "{\"ratings\":[{\"group_id\":\(index),\"importance\":\(importance),\"confidence\":1,\"reason\":\"Independent rating\"}]}", plan: plan)
    }
    #expect(accumulated.map(\.importance) == [5, 1, 4])
    #expect(accumulated.map(\.members) == neutral.map(\.members))
    #expect(neutral.map(\.importance) == [3, 3, 4])
    #expect(try TodaySemanticPolicy.ratingPlan(groups: neutral, candidates: reports(3), groupID: 2) == nil)
}

@Test func verificationBatchesPreserveAllPairsAndPartitionOnlyAfterCompleteValidation() throws {
    let plan = try TodaySemanticPolicy.verificationPlan(groups: [group((0..<12).map(Double.init)), group([12])], candidates: reports(13))
    let batches = try TodaySemanticPolicy.verificationBatches(plan: plan)
    #expect(batches.count == 66)
    #expect(batches.allSatisfy { $0.pairs.count == 1 })
    #expect(batches.flatMap(\.pairs) == plan.pairs)
    let responses = Array(repeating: #"{"relation":"same_event"}"#, count: 66)
    let verified = try TodaySemanticPolicy.verify(responses: responses, plan: plan)
    #expect(verified.map(\.members) == [(0..<12).map(Double.init), [12]])
    #expect(verified.allSatisfy { !$0.needsRating })
    var badLast = responses
    badLast[65] = #"{"relation":"invented"}"#
    for invalid in [Array(responses.prefix(65)), responses + [responses[0]], badLast] {
        #expect(throws: (any Error).self) { try TodaySemanticPolicy.verify(responses: invalid, plan: plan) }
    }
}

@Test func verificationBatchLengthMatchesSharedFixture() throws {
    struct Case: Decodable { let pair_count: Int; let offset: Int; let length: Int }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/semantic-pair-batches.json")))
    for item in cases { #expect(skim_semantic_pair_batch_length(item.pair_count, item.offset) == item.length) }
}

@Test func semanticInputsRetainOriginalRepresentativeEvidenceBeyondGeneratedSummary() throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let fact = "The hearing is on October 12, not October 19."
    let body = String(repeating: "Background. ", count: 40) + fact
    let article = Article(id: "article", feedID: "feed", feedTitle: "Feed", title: "Report", contentText: body, fetchedAt: date)
    let story = Story(id: "story", title: "Report", firstSeenAt: date, lastActivityAt: date, createdAt: date, updatedAt: date)
    let revision = StoryRevision(storyID: story.id, revisionNumber: 1, title: "Report", summary: "Short generated summary",
        representativeArticleID: article.id, sourceCount: 1, contentFingerprint: "fixture", isMaterialChange: true, createdAt: date)
    var candidate = TodayEditionCandidate(ranking: StoryRankingCandidate(story: story, representativeFeedID: "feed", distinctFeedCount: 1, articleCount: 1),
        revision: revision, sourceArticles: [TodayEditionCandidateSource(article: article, membership: StoryArticleMembership(storyID: story.id, articleID: article.id, membershipType: .update, addedAt: date))])
    let input = try #require(TodaySemanticPolicy.inputs([candidate], at: date).first)
    #expect(input.evidence?.contains(fact) == true)
    #expect(!input.excerpt.contains(fact))
    candidate.sourceArticles[0].article.contentText = " \n "
    #expect(TodaySemanticPolicy.inputs([candidate], at: date).first?.evidence == revision.summary)
}

@Test func verificationRetainsSharedCliquePartitionCases() throws {
    struct Fixture: Decodable { let candidate_count: Int; let members: [Double]; let positive_pairs: [[Int]]; let expected_labels: [Int] }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/semantic-pairs.json")))
    for fixture in fixtures {
        let plan = try TodaySemanticPolicy.verificationPlan(groups: [group(fixture.members)], candidates: reports(fixture.candidate_count))
        let positives = Set(fixture.positive_pairs.map { $0.sorted().map(String.init).joined(separator: ":") })
        let responses = plan.pairs.map { positives.contains($0.map(String.init).joined(separator: ":")) ? #"{"relation":"same_event"}"# : #"{"relation":"different_event"}"# }
        let result = try TodaySemanticPolicy.verify(responses: responses, plan: plan)
        let labels = fixture.members.map { member in result.firstIndex { $0.members.contains(member) }! }
        #expect(labels == fixture.expected_labels)
    }
}
