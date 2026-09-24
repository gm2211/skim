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

@Test func verificationPayloadIncludesEveryReportAndExplicitPairIdentity() throws {
    let plan = try TodaySemanticPolicy.verificationPlan(groups: [group([2, 0])], candidates: reports(4))
    #expect(plan.pairs == [[0, 2]])
    let payload = try #require(JSONSerialization.jsonObject(with: Data(plan.payload.utf8)) as? [String: Any])
    let entries = try #require(payload["reports"] as? [[String: Any]])
    #expect(entries.count == 4)
    #expect(entries[0]["activity_date"] as? String == "2024-08-14")
    #expect(Set(entries[0].keys) == ["index", "title", "excerpt", "activity_date"])
}

@Test func verificationPartitionsNontransitiveTriangleConservatively() throws {
    let plan = try TodaySemanticPolicy.verificationPlan(groups: [group([2, 0, 1])], candidates: reports(3))
    let response = #"[{"members":[2,1],"same_event":true,"confidence":0.95},{"members":[0,2],"same_event":false,"confidence":1},{"members":[1,0],"same_event":true,"confidence":0.9}]"#
    let result = try TodaySemanticPolicy.verify(response: response, plan: plan)
    #expect(result.map { Set($0.members) } == [Set([0.0, 1.0]), Set([2.0])])
    #expect(result.allSatisfy { $0.reason == "From your feeds" && $0.importance == 3 && $0.needsRating })
}

@Test func verificationRequiresEveryRequestedPairExactlyOnceAndStrictBoolean() throws {
    let plan = try TodaySemanticPolicy.verificationPlan(groups: [group([0, 1])], candidates: reports(3))
    for response in [
        #"{"pairs":[]}"#,
        #"{"pairs":[{"members":[0,1],"same_event":1,"confidence":1}]}"#,
        #"{"pairs":[{"members":[true,1],"same_event":true,"confidence":1}]}"#,
        #"{"pairs":[{"members":[0,2],"same_event":true,"confidence":1}]}"#,
        #"{"pairs":[{"members":[0.5,1],"same_event":true,"confidence":1}]}"#,
        #"{"pairs":[{"members":[0,1],"same_event":true,"confidence":1.1}]}"#,
        #"{"pairs":[{"members":[0,1],"same_event":true,"confidence":1},{"members":[1,0],"same_event":true,"confidence":1}]}"#,
        #"[true]"#
    ] {
        #expect(throws: (any Error).self) { try TodaySemanticPolicy.verify(response: response, plan: plan) }
    }
}

@Test func verificationAcceptsOneFenceWithoutExtractingJSONFromProse() throws {
    let plan = try TodaySemanticPolicy.verificationPlan(groups: [group([0, 1])], candidates: reports(2))
    let array = #"[{"pair":[0,1],"same_event":true,"confidence":0.9}]"#
    for fence in ["```json", "```"] {
        let result = try TodaySemanticPolicy.verify(response: " \n\(fence)\n\(array)\n``` \n", plan: plan)
        #expect(result.count == 1)
        #expect(Set(result[0].members) == [0, 1])
    }
    for response in ["Here is the answer: \(array)", "```json\n\(array)", "```json\n\(array)\n```\nDone."] {
        #expect(throws: (any Error).self) { try TodaySemanticPolicy.verify(response: response, plan: plan) }
    }
}

@Test func uncertainPairsSplitAndSingletonsNeedNoSecondCall() throws {
    let single = try TodaySemanticPolicy.verificationPlan(groups: [group([0])], candidates: reports(2))
    #expect(single.pairs.isEmpty)
    #expect(try TodaySemanticPolicy.verify(response: "", plan: single).count == 1)
    let pair = try TodaySemanticPolicy.verificationPlan(groups: [group([0, 1])], candidates: reports(2))
    let split = try TodaySemanticPolicy.verify(response: #"{"pairs":[{"members":[0,1],"same_event":true,"confidence":0.79}]}"#, plan: pair)
    #expect(split.count == 2)
}

@Test func verificationBoundsPairWorkAndRejectsOverlappingInitialGroups() throws {
    let plan = try TodaySemanticPolicy.verificationPlan(groups: [group([0, 99]), group([0, 1]), group([1, 2])], candidates: reports(3))
    #expect(plan.pairs == [[0, 1]])
}

@Test func verificationMatchesSharedPartitionFixtures() throws {
    struct Fixture: Decodable {
        let name: String
        let candidate_count: Int
        let members: [Double]
        let positive_pairs: [[Int]]
        let expected_labels: [Int]
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/semantic-pairs.json")))
    for fixture in fixtures {
        let plan = try TodaySemanticPolicy.verificationPlan(groups: [group(fixture.members)], candidates: reports(fixture.candidate_count))
        let positives = Set(fixture.positive_pairs.map { $0.sorted().map(String.init).joined(separator: ":") })
        let decisions: [[String: Any]] = plan.pairs.map { pair in
            ["members": pair, "same_event": positives.contains(pair.map(String.init).joined(separator: ":")), "confidence": 1.0]
        }
        let response = String(decoding: try JSONSerialization.data(withJSONObject: decisions), as: UTF8.self)
        let actual = try TodaySemanticPolicy.verify(response: response, plan: plan)
        let labels = Set(fixture.expected_labels).sorted()
        let expected = labels.map { label in
            Set(fixture.members.enumerated().filter { fixture.expected_labels[$0.offset] == label }.map(\.element))
        }
        #expect(actual.map { Set($0.members) } == expected, Comment(rawValue: fixture.name))
    }
}

@Test func verificationAcceptsOneExplicitIdentityAliasAndRejectsConflicts() throws {
    let plan = try TodaySemanticPolicy.verificationPlan(groups: [group([0, 1])], candidates: reports(2))
    let alias = try TodaySemanticPolicy.verify(response: #"[{"pair":[1,0],"same_event":true,"confidence":0.9}]"#, plan: plan)
    #expect(alias.count == 1)
    #expect(Set(alias[0].members) == [0, 1])
    for response in [
        #"[{"members":[0,1],"pair":[0,1],"same_event":true,"confidence":1}]"#,
        #"[{"members":[0,1],"pair":null,"same_event":true,"confidence":1}]"#,
        #"[{"same_event":true,"confidence":1}]"#,
        #"[{"pair":[true,1],"same_event":true,"confidence":1}]"#
    ] {
        #expect(throws: (any Error).self) { try TodaySemanticPolicy.verify(response: response, plan: plan) }
    }
    let uncertain = try TodaySemanticPolicy.verify(response: #"[{"pair":[0,1],"same_event":true,"confidence":0.79}]"#, plan: plan)
    #expect(uncertain.count == 2)
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
        var verified = try TodaySemanticPolicy.verify(response: fixture.verification_response, plan: plan)
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
    let neutral = try TodaySemanticPolicy.verify(response: #"[{"pair":[0,1],"same_event":false,"confidence":1}]"#, plan: verification)
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
    let neutral = try TodaySemanticPolicy.verify(response: #"[{"pair":[0,1],"same_event":false,"confidence":1}]"#, plan: verification)
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
    let neutral = try TodaySemanticPolicy.verify(response: #"[{"pair":[0,1],"same_event":false,"confidence":1}]"#, plan: verification)
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
    #expect(batches.map { $0.pairs.count } == [64, 2])
    #expect(batches.flatMap(\.pairs) == plan.pairs)
    for batch in batches {
        let payload = try #require(JSONSerialization.jsonObject(with: Data(batch.payload.utf8)) as? [String: Any])
        let entries = try #require(payload["reports"] as? [[String: Any]])
        #expect(Set(entries.compactMap { $0["index"] as? Int }) == Set(batch.pairs.flatMap { $0 }))
        #expect(!entries.contains { $0["index"] as? Int == 12 })
    }
    func response(_ pairs: [[Int]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: pairs.map {
            ["members": $0, "same_event": true, "confidence": 0.99] as [String: Any]
        }), as: UTF8.self)
    }
    let responses = try batches.map { try response($0.pairs) }
    for (batch, raw) in zip(batches, responses) {
        try TodaySemanticPolicy.validateVerificationResponse(raw, batch: batch, plan: plan)
        #expect(throws: (any Error).self) { try TodaySemanticPolicy.validateVerificationResponse("[]", batch: batch, plan: plan) }
    }
    let verified = try TodaySemanticPolicy.verify(responses: responses, plan: plan)
    #expect(verified.map(\.members) == [(0..<12).map(Double.init), [12]])
    #expect(verified.allSatisfy { !$0.needsRating })
    for invalid in [Array(responses.prefix(1)), responses + [responses[0]], [responses[0], "[]"],
                    [responses[0], responses[0]], [responses[0], try response([[0, 12]])]] {
        #expect(throws: (any Error).self) { try TodaySemanticPolicy.verify(responses: invalid, plan: plan) }
    }
    #expect(throws: (any Error).self) { try TodaySemanticPolicy.verify(response: responses[0], plan: plan) }
}

@Test func verificationBatchLengthMatchesSharedFixture() throws {
    struct Case: Decodable { let pair_count: Int; let offset: Int; let length: Int }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/semantic-pair-batches.json")))
    for item in cases { #expect(skim_semantic_pair_batch_length(item.pair_count, item.offset) == item.length) }
}
