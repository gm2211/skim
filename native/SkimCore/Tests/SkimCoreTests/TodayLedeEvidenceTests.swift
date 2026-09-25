import Foundation
import Testing
@testable import SkimCore

@Test func todayExcerptMatchesSharedEvidenceCorpus() throws {
    struct Fixture: Decodable { let source: String; let excerpt: String; let valid: Bool }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/today-excerpts.json")))
    for fixture in fixtures {
        #expect((TodayLedePolicy.validatedExcerpt(candidate: fixture.excerpt, sources: [fixture.source]) != nil) == fixture.valid,
            Comment(rawValue: fixture.excerpt))
    }
}

@Test func todayExcerptRequiresStrictEnvelopeAndOneSourcePassage() {
    let source = "The mission launched on 10 September. It will reach orbit next month."
    let response = #"{"excerpt":"The mission launched on 10 September."}"#
    #expect(TodayLedePolicy.excerpt(from: response, sources: [source]) == "The mission launched on 10 September.")
    #expect(TodayLedePolicy.excerpt(from: "```json\n\(response)\n```", sources: [source]) != nil)
    #expect(TodayLedePolicy.validatedExcerpt(candidate: "The\u{00a0}mission\nlaunched on 10 September.", sources: [source]) == "The mission launched on 10 September.")
    for invalid in [
        "The mission launched on 10 September.", response + " trailing",
        #"{"excerpt":"The mission launched on 9 September."}"#,
        #"{"excerpt":true}"#, #"{"excerpt":""}"#,
        #"{"excerpt":"The mission launched on 10 September.","other":"data"}"#,
        #"[{"excerpt":"The mission launched on 10 September."}]"#
    ] { #expect(TodayLedePolicy.excerpt(from: invalid, sources: [source]) == nil) }
    #expect(TodayLedePolicy.validatedExcerpt(candidate: source, sources: ["The mission launched on 10 September.", "It will reach orbit next month."]) == nil)
    #expect(TodayLedePolicy.excerpt(from: response, sources: ["Unrelated source content."]) == nil)
}

private actor ExcerptRequests {
    var calls: [(String, Bool)] = []
    var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func request(_ instructions: String, _ json: Bool) -> String {
        calls.append((instructions, json))
        return replies.isEmpty ? "Unexpected extra request" : replies.removeFirst()
    }
}

@Test func todayExcerptRetriesInvalidJSONExactlyOnceAsVerifiedPlainText() async throws {
    let source = "The minister called the proposal \"unworkable\" on Thursday."
    let requests = ExcerptRequests([#"{"excerpt":"The minister called the proposal "unworkable" on Thursday."}"#, source])
    let result = try await TodayLedePolicy.generateExcerpt(sources: [source]) { instructions, json in
        await requests.request(instructions, json)
    }
    #expect(result == source)
    let calls = await requests.calls
    #expect(calls.map(\.1) == [true, false])
    #expect(calls.map(\.0) == [TodayLedePolicy.instructions, TodayLedePolicy.retryInstructions])
}

@Test func todayExcerptValidPrimarySkipsRetryAndPlainRewriteStillFails() async throws {
    let source = "The mission launched on 10 September."
    let valid = ExcerptRequests([#"{"excerpt":"The mission launched on 10 September."}"#])
    #expect(try await TodayLedePolicy.generateExcerpt(sources: [source]) { instructions, json in
        await valid.request(instructions, json)
    } == source)
    #expect(await valid.calls.count == 1)
    for invalid in ["The Mission launched on 10 September.", "The mission launched on 9 September.", "Here is the excerpt: " + source] {
        let requests = ExcerptRequests(["Malformed", invalid])
        #expect(try await TodayLedePolicy.generateExcerpt(sources: [source]) { instructions, json in
            await requests.request(instructions, json)
        } == "")
        #expect(await requests.calls.count == 2)
    }
}

@Test func todayExcerptProviderFailureDoesNotRetry() async throws {
    let requests = ExcerptRequests([])
    do {
        _ = try await TodayLedePolicy.generateExcerpt(sources: ["Evidence."]) { instructions, json in
            _ = await requests.request(instructions, json)
            throw URLError(.notConnectedToInternet)
        }
        Issue.record("Provider failure unexpectedly succeeded")
    } catch is URLError {}
    #expect(await requests.calls.count == 1)
}

@Test func todayExcerptStopsAfterRetryErrorOrCancellation() async throws {
    let retryFailure = ExcerptRequests(["Malformed"])
    do {
        _ = try await TodayLedePolicy.generateExcerpt(sources: ["Evidence."]) { instructions, json in
            let reply = await retryFailure.request(instructions, json)
            if !json { throw URLError(.timedOut) }
            return reply
        }
        Issue.record("Retry error unexpectedly succeeded")
    } catch is URLError {}
    #expect(await retryFailure.calls.count == 2)
    let cancelled = ExcerptRequests(["Malformed"])
    let task = Task {
        try await TodayLedePolicy.generateExcerpt(sources: ["Evidence."]) { instructions, json in
            let reply = await cancelled.request(instructions, json)
            withUnsafeCurrentTask { $0?.cancel() }
            return reply
        }
    }
    do { _ = try await task.value; Issue.record("Cancelled primary unexpectedly retried") }
    catch is CancellationError {}
    #expect(await cancelled.calls.count == 1)
}

@Test func todayPreviewProvenanceMatchesSecondSourceAndExactBoundedEvidence() throws {
    let first = "The hearing is scheduled for next week."
    let second = "The hearing ended on Thursday. The court reserved its decision."
    let passage = "The hearing ended on Thursday."
    let selection = try #require(TodayLedePolicy.selection(candidate: passage, sources: ["", first, second]))
    #expect(selection.sourceIndex == 2)
    #expect(selection.excerpt == passage)
    #expect(selection.evidenceHash == StoryClusterer.sha256(second))
    #expect(selection.evidenceHash != StoryClusterer.sha256(passage))
    #expect(TodayLedePolicy.selection(candidate: passage, sources: [second, second])?.sourceIndex == 0)
    #expect(TodayLedePolicy.selection(candidate: "The hearing ended on Friday.", sources: [first, second]) == nil)
    #expect(TodayLedePolicy.selection(candidate: passage, sources: []) == nil)
    #expect(TodayLedePolicy.evidenceVersion == 3)
}

@Test func todayPreviewSourceSelectionMatchesSharedCorpus() throws {
    struct Fixture: Decodable { let name: String; let sources: [String]; let excerpt: String; let index: Int }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/today-excerpt-sources.json")))
    for fixture in fixtures {
        #expect((TodayLedePolicy.selection(candidate: fixture.excerpt, sources: fixture.sources)?.sourceIndex ?? -1) == fixture.index, Comment(rawValue: fixture.name))
    }
}
