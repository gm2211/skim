import Foundation
import SkimCore
import Testing
@testable import Skim

private actor CatchUpDeferred<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func value() async throws -> Value {
        started = true
        waiters.forEach { $0.resume() }; waiters = []
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func untilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish(_ result: Result<Value, any Error>) {
        continuation?.resume(with: result); continuation = nil
    }
}

@MainActor
@Suite("Quick Catch-up cancellation")
struct CatchUpSessionTests {
    private func article(_ id: String, age: TimeInterval = 0) -> Article {
        Article(id: id, feedID: "feed", feedTitle: "Feed", title: id,
                contentText: "Original report \(id).", publishedAt: Date().addingTimeInterval(-age))
    }
    private func request(_ articles: [Article]) -> CatchUpRequest {
        CatchUpRequest(subtitle: "Articles", statusLabel: "Loading…", loadArticles: { articles }, settings: AppSettings())
    }
    private func page(_ headline: String, count: Int = 1) -> NativeAI.CatchUpPage {
        NativeAI.CatchUpPage(stories: (1...count).map {
            NativeAI.CatchUpStory(headline: "\(headline) \($0)", lede: "", articleIndexes: [$0])
        })
    }

    @Test func cancelledLocalCompletionDoesNotLoadModelOrGenerate() async {
        let start = CatchUpDeferred<Void>()
        let task = Task {
            try await start.value()
            return try await MLXRunner.shared.complete(messages: [["role": "user", "content": "Never generate"]], maxTokens: 8)
        }
        await start.untilStarted()
        task.cancel()
        await start.finish(.success(()))
        do {
            _ = try await task.value
            Issue.record("Cancelled completion returned an answer")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func stoppingDuringArticleLoadDoesNotStartInference() async {
        let load = CatchUpDeferred<[Article]>()
        var calls = 0
        let session = CatchUpSession(picks: { _, _ in calls += 1; return nil })
        var input = request([])
        input.loadArticles = { try await load.value() }
        let task = session.start(request: input, range: .anything)
        await load.untilStarted()
        session.cancel()
        #expect(!session.isLoading && session.wasStopped)
        await load.finish(.success([article("late")]))
        await task.value
        #expect(calls == 0 && session.articles.isEmpty && session.page.isEmpty)
        #expect(session.errorMessage == nil)
    }

    @Test func rangeChangeRejectsOldPicksAndUsesNewScope() async {
        let old = CatchUpDeferred<NativeAI.CatchUpPage?>()
        var contexts: [[String]] = []
        let session = CatchUpSession(picks: { articles, _ in
            contexts.append(articles.map(\.id))
            if contexts.count == 1 { return try await old.value() }
            return page("Fresh")
        }, lede: { _, _, _ in "Current summary" })
        let input = request([article("recent"), article("old", age: 172800)])
        let first = session.start(request: input, range: .anything)
        await old.untilStarted()
        let second = session.start(request: input, range: .sixHours)
        await second.value
        await old.finish(.success(page("Stale", count: 2)))
        await first.value
        #expect(contexts == [["recent", "old"], ["recent"]])
        #expect(session.articles.map(\.id) == ["recent"])
        #expect(session.page.stories.map(\.headline) == ["Fresh 1"])
        #expect(session.page.stories.first?.lede == "Current summary")
        #expect(!session.isLoading && !session.wasStopped && session.errorMessage == nil)
    }

    @Test func stopPreservesWrittenStoriesAndRejectsLateLede() async {
        let late = CatchUpDeferred<String>()
        var calls = 0
        let session = CatchUpSession(picks: { _, _ in page("Story", count: 3) }, lede: { _, _, _ in
            calls += 1
            return calls == 1 ? "Completed summary" : try await late.value()
        })
        let task = session.start(request: request([article("one"), article("two"), article("three")]), range: .anything)
        await late.untilStarted()
        session.cancel()
        #expect(session.page.stories[0].lede == "Completed summary")
        await late.finish(.success("Late summary"))
        await task.value
        #expect(calls == 2)
        #expect(session.page.stories.map(\.lede) == ["Completed summary", "", ""])
        #expect(!session.isLoading && session.wasStopped && session.errorMessage == nil)
    }

    @Test func oldFallbackAndErrorsCannotReplaceNewRun() async {
        for shouldFail in [false, true] {
            let old = CatchUpDeferred<String>()
            var picksCount = 0
            let session = CatchUpSession(picks: { _, _ in
                picksCount += 1
                return picksCount == 1 ? nil : page("New")
            }, fallback: { _, _ in try await old.value() }, lede: { _, _, _ in "New summary" })
            let input = request([article("one")])
            let first = session.start(request: input, range: .anything)
            await old.untilStarted()
            let second = session.start(request: input, range: .day)
            await second.value
            await old.finish(shouldFail ? .failure(URLError(.timedOut)) : .success("Old fallback"))
            await first.value
            #expect(session.page.stories.first?.headline == "New 1")
            #expect(session.fallbackText == nil && session.errorMessage == nil && !session.isLoading)
        }
    }

    @Test func currentErrorsRemainVisibleAndRunAgainCanRecover() async {
        var fail = true
        let session = CatchUpSession(picks: { _, _ in
            if fail { throw URLError(.notConnectedToInternet) }
            return page("Recovered")
        }, lede: { _, _, _ in "Recovered summary" })
        let input = request([article("one")])
        await session.start(request: input, range: .anything).value
        #expect(session.errorMessage != nil && !session.isLoading)
        fail = false
        await session.start(request: input, range: .anything).value
        #expect(session.errorMessage == nil && session.page.stories.first?.lede == "Recovered summary")
    }
}
