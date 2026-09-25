import Testing
import Foundation
import SkimCore
@testable import Skim

// MARK: - Test helpers

/// A one-shot rendezvous point: the runner side calls `arrive()` and
/// suspends until the test side calls `release()`. Lets a test deterministically
/// pause a `CatchUpRunner` run mid-flight (e.g. mid-lede, or mid-picks) so it
/// can call `stop()` or `start()` again at an exact, known moment instead of
/// racing against `Task.sleep`.
private actor Gate {
    private var hasArrived = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arrive() async {
        hasArrived = true
        if isReleased { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForArrival() async {
        while !hasArrived {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

/// Serializes call counting across concurrent closures without a data race.
private actor Counter {
    private var value = 0

    @discardableResult
    func next() -> Int {
        value += 1
        return value
    }

    var current: Int { value }
}

@MainActor
private func makeArticle(_ id: String) -> Article {
    Article(id: id, feedID: "feed", feedTitle: "Feed", title: "Article \(id)")
}

// MARK: - CatchUpRunner Tests
//
// skim-ln8r: the Quick Catch-up screen used to be unstoppable and
// un-restartable mid-run (no Stop button, range/model pickers disabled while
// loading). These tests exercise the extracted run loop directly — its job is
// to make sure `stop()` and a mid-run `start()` actually cancel the AI work in
// flight rather than merely hiding it, and that a superseded run's late
// results can never clobber a newer one's page.
@MainActor
@Suite("CatchUpRunner")
struct CatchUpRunnerTests {

    @Test func stopDuringLedeLoopKeepsWrittenLedesAndCallsNoFurtherLedes() async throws {
        let article = makeArticle("a")
        var page = NativeAI.CatchUpPage()
        page.stories = [
            NativeAI.CatchUpStory(headline: "Story 0", lede: "", articleIndexes: [1]),
            NativeAI.CatchUpStory(headline: "Story 1", lede: "", articleIndexes: [1]),
            NativeAI.CatchUpStory(headline: "Story 2", lede: "", articleIndexes: [1])
        ]

        let gate = Gate()
        let story2Calls = Counter()

        let runner = CatchUpRunner(
            loadArticles: { [article] },
            picks: { _, _ in page },
            fallback: { _, _ in "" },
            lede: { headline, _, _ in
                switch headline {
                case "Story 0":
                    return "First lede"
                case "Story 1":
                    // Blocks here until the test calls stop() and releases it,
                    // simulating the user tapping Stop while this story's
                    // lede request is still in flight.
                    await gate.arrive()
                    return "Should never land"
                default:
                    await story2Calls.next()
                    return "Should never run"
                }
            }
        )

        runner.start(range: .anything, statusLabel: "Loading…", settings: AppSettings())
        await gate.waitForArrival()

        runner.stop()
        await gate.release()

        // Let the now-cancelled task actually resume and return.
        try await Task.sleep(for: .milliseconds(50))

        #expect(runner.phase == .stopped)
        #expect(runner.errorMessage == nil)
        #expect(runner.page.stories[0].lede == "First lede")
        #expect(runner.page.stories[1].lede == "")
        #expect(runner.page.stories[2].lede == "")
        #expect(await story2Calls.current == 0)
    }

    @Test func lateCancellationErrorAfterStopProducesNoErrorAndNoExcerpt() async throws {
        let article = makeArticle("a")
        var page = NativeAI.CatchUpPage()
        page.stories = [
            NativeAI.CatchUpStory(headline: "Only story", lede: "", articleIndexes: [1])
        ]

        let gate = Gate()

        let runner = CatchUpRunner(
            loadArticles: { [article] },
            picks: { _, _ in page },
            fallback: { _, _ in "" },
            lede: { _, _, _ in
                await gate.arrive()
                // Mirrors what a cloud provider's URLSession.data actually
                // throws once its Task is cancelled mid-flight.
                throw URLError(.cancelled)
            }
        )

        runner.start(range: .anything, statusLabel: "Loading…", settings: AppSettings())
        await gate.waitForArrival()

        runner.stop()
        await gate.release()

        try await Task.sleep(for: .milliseconds(50))

        #expect(runner.phase == .stopped)
        #expect(runner.errorMessage == nil)
        // No excerpt fallback should paper over the cancelled story.
        #expect(runner.page.stories[0].lede == "")
    }

    @Test func startWithNewRangeMidRunCancelsOldRunAndItsLateResultsNeverLand() async throws {
        let article = makeArticle("a")

        var oldPage = NativeAI.CatchUpPage()
        oldPage.stories = [NativeAI.CatchUpStory(headline: "Old", lede: "", articleIndexes: [1])]
        var newPage = NativeAI.CatchUpPage()
        newPage.stories = [NativeAI.CatchUpStory(headline: "New", lede: "", articleIndexes: [1])]

        let gate = Gate()
        let picksCalls = Counter()

        let runner = CatchUpRunner(
            loadArticles: { [article] },
            picks: { _, _ in
                let call = await picksCalls.next()
                if call == 1 {
                    // The old run's picks pass hangs until the test releases
                    // it — well after the new run has already finished.
                    await gate.arrive()
                    return oldPage
                }
                return newPage
            },
            fallback: { _, _ in "" },
            lede: { headline, _, _ in headline == "Old" ? "Old lede (should never land)" : "New lede" }
        )

        runner.start(range: .anything, statusLabel: "Loading…", settings: AppSettings())
        await gate.waitForArrival()

        // Range changes mid-run: cancels the old run and starts a fresh one.
        runner.start(range: .day, statusLabel: "Loading…", settings: AppSettings())

        // The new run has no gate in its path, so it should reach .finished
        // on its own.
        for _ in 0..<200 where runner.phase != .finished {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(runner.phase == .finished)
        #expect(runner.page.stories.first?.headline == "New")
        #expect(runner.page.stories.first?.lede == "New lede")

        // Now let the stale old run's picks() finally return. Its result must
        // not overwrite the page the new run already produced.
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))

        #expect(runner.page.stories.first?.headline == "New")
        #expect(runner.page.stories.first?.lede == "New lede")
        #expect(runner.errorMessage == nil)
    }

    @Test func isCancellationCoversEveryCancellationShape() {
        #expect(NativeAI.isCancellation(CancellationError()) == true)
        #expect(NativeAI.isCancellation(URLError(.cancelled)) == true)
        #expect(NativeAI.isCancellation(MLXRunner.MLXError.cancelled) == true)
        #expect(NativeAI.isCancellation(NativeAIError.unavailable("offline")) == false)
    }
}
