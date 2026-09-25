import Observation
import SkimCore
import SwiftUI

/// Drives the Quick Catch-up two-pass run (pick the stories, then write each
/// lede) as a cancellable, restartable state machine, independent of the
/// view that displays it. Pulled out of `CatchUpSheet` so the run loop —
/// especially "does a stale run's late result get to overwrite a newer
/// one?" — can be tested without SwiftUI.
///
/// The three AI passes are injected as closures so tests can substitute
/// fakes; the defaults call straight into `NativeAI`.
@MainActor
@Observable
final class CatchUpRunner {
    enum Phase: Equatable {
        case idle
        case running
        case stopped
        case finished
    }

    /// Resolves the articles the page is built from.
    var loadArticles: () async throws -> [Article]

    /// Pass one: pick the stories, group the articles under them, and write
    /// the headlines. `nil` means the model's answer couldn't be read, so
    /// `fallback` runs instead.
    var picks: (_ articles: [Article], _ settings: AppSettings) async throws -> NativeAI.CatchUpPage?
    /// Plain-text catch-up, used when `picks` returns nil.
    var fallback: (_ articles: [Article], _ settings: AppSettings) async throws -> String
    /// Pass two: write one story's lede.
    var lede: (_ headline: String, _ articles: [Article], _ settings: AppSettings) async throws -> String

    private(set) var phase: Phase = .idle
    private(set) var statusMessage = ""
    private(set) var page = NativeAI.CatchUpPage()
    private(set) var fallbackText: String?
    private(set) var articles: [Article] = []
    private(set) var errorMessage: String?
    private(set) var errorRemedy: AIErrorRemedy = .none

    private var runTask: Task<Void, Never>?
    private var runID = UUID()

    init(
        loadArticles: @escaping () async throws -> [Article],
        picks: @escaping (_ articles: [Article], _ settings: AppSettings) async throws -> NativeAI.CatchUpPage? = { articles, settings in
            try await NativeAI.catchUpPicks(articles: articles, settings: settings)
        },
        fallback: @escaping (_ articles: [Article], _ settings: AppSettings) async throws -> String = { articles, settings in
            try await NativeAI.quickCatchUp(articles: articles, settings: settings)
        },
        lede: @escaping (_ headline: String, _ articles: [Article], _ settings: AppSettings) async throws -> String = { headline, articles, settings in
            try await NativeAI.catchUpLede(headline: headline, articles: articles, settings: settings)
        }
    ) {
        self.loadArticles = loadArticles
        self.picks = picks
        self.fallback = fallback
        self.lede = lede
    }

    /// Starts a fresh run for `range`, cancelling whatever run is already in
    /// progress. `settings` is read fresh from the caller at this moment
    /// (never cached across runs) so a mid-flight settings change — e.g. the
    /// inline model picker — is picked up the next time a run starts rather
    /// than a stale copy from when the runner was created.
    func start(range: CatchUpRange, statusLabel: String, settings: AppSettings) {
        runTask?.cancel()
        let id = UUID()
        runID = id

        page = NativeAI.CatchUpPage()
        fallbackText = nil
        articles = []
        errorMessage = nil
        errorRemedy = .none
        statusMessage = statusLabel
        phase = .running

        runTask = Task { [weak self] in
            await self?.run(id: id, range: range, settings: settings)
        }
    }

    /// Cancels the run in progress. Whatever has already landed on the page
    /// (headlines, ledes already written, or fallback text) is kept as-is;
    /// missing ledes are left blank rather than backfilled with an excerpt,
    /// since that's the AI-written page, not this one.
    func stop() {
        runTask?.cancel()
        runTask = nil
        runID = UUID()
        phase = .stopped
        statusMessage = ""
    }

    /// True while `id` is still the current run and the task hasn't been
    /// cancelled. Every await in `run` is followed by this check before
    /// touching published state, so a stopped or superseded run can never
    /// clobber a newer one's results.
    private func isCurrent(_ id: UUID) -> Bool {
        runID == id && !Task.isCancelled
    }

    private func run(id: UUID, range: CatchUpRange, settings: AppSettings) async {
        do {
            let loaded = try await loadArticles()
            guard isCurrent(id) else { return }

            let context = range.filter(loaded)
            articles = context
            guard !context.isEmpty else {
                errorMessage = "Nothing published in the \(range.label.lowercased()). Pick a wider range."
                errorRemedy = .none
                finish(id: id)
                return
            }
            statusMessage = "Reading \(context.count) \(context.count == 1 ? "article" : "articles")…"

            guard let picked = try await picks(context, settings) else {
                guard isCurrent(id) else { return }
                let text = try await fallback(context, settings)
                guard isCurrent(id) else { return }
                fallbackText = text
                finish(id: id)
                return
            }
            guard isCurrent(id) else { return }

            withAnimation(.easeOut(duration: 0.3)) {
                page = picked
            }

            for index in page.stories.indices {
                guard isCurrent(id) else { return }
                let story = page.stories[index]
                statusMessage = page.stories.count == 1
                    ? "Writing the lead story…"
                    : "Writing story \(index + 1) of \(page.stories.count)…"

                let behind = story.articleIndexes.compactMap { handle -> Article? in
                    let zeroBased = handle - 1
                    return context.indices.contains(zeroBased) ? context[zeroBased] : nil
                }

                let written: String
                do {
                    written = try await lede(story.headline, behind, settings)
                } catch {
                    // Cancellation (or a newer run having already started)
                    // ends the run quietly here rather than backfilling this
                    // story with an excerpt — `stop()` promises the partial
                    // page is left exactly as it was.
                    guard NativeAI.isCancellation(error) == false, isCurrent(id) else { return }
                    written = ""
                }

                guard isCurrent(id) else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    page.stories[index].lede = written.isEmpty ? Self.excerptLede(behind) : written
                }
            }
        } catch {
            guard isCurrent(id), !NativeAI.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            errorRemedy = AIErrorRemedy.classify(error)
            finish(id: id)
            return
        }

        finish(id: id)
    }

    private func finish(id: UUID) {
        guard isCurrent(id) else { return }
        phase = .finished
        runTask = nil
    }

    /// A short fallback for when one story's second pass fails, so a
    /// headline never sits over nothing.
    static func excerptLede(_ articles: [Article]) -> String {
        guard let text = articles.first?.contentText?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return "" }
        let words = text.split(whereSeparator: \.isWhitespace)
        let clipped = words.prefix(40).joined(separator: " ")
        return words.count > 40 ? clipped + "…" : clipped
    }
}
