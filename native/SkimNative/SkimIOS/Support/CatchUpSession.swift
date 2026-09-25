import SkimCore
import SwiftUI

/// Owns one sheet's work. Cancellation invalidates identity before cancelling
/// transport, so even a provider that returns late cannot publish stale results.
@MainActor
final class CatchUpSession: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var wasStopped = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var page = NativeAI.CatchUpPage()
    @Published private(set) var fallbackText: String?
    @Published private(set) var articles: [Article] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorRemedy: AIErrorRemedy = .none

    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let picks: ([Article], AppSettings) async throws -> NativeAI.CatchUpPage?
    private let fallback: ([Article], AppSettings) async throws -> String
    private let lede: (String, [Article], AppSettings) async throws -> String

    init(
        picks: @escaping ([Article], AppSettings) async throws -> NativeAI.CatchUpPage? = { try await NativeAI.catchUpPicks(articles: $0, settings: $1) },
        fallback: @escaping ([Article], AppSettings) async throws -> String = { try await NativeAI.quickCatchUp(articles: $0, settings: $1) },
        lede: @escaping (String, [Article], AppSettings) async throws -> String = { try await NativeAI.catchUpLede(headline: $0, articles: $1, settings: $2) }
    ) {
        self.picks = picks
        self.fallback = fallback
        self.lede = lede
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        if isLoading { wasStopped = true }
        isLoading = false
    }

    @discardableResult
    func start(request: CatchUpRequest, range: CatchUpRange) -> Task<Void, Never> {
        cancel()
        let id = generation
        isLoading = true
        wasStopped = false
        errorMessage = nil
        errorRemedy = .none
        page = NativeAI.CatchUpPage()
        fallbackText = nil
        articles = []
        statusMessage = request.statusLabel
        let work = Task { await run(request: request, range: range, id: id) }
        task = work
        return work
    }

    private func checkCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard id == generation else { throw CancellationError() }
    }

    private func run(request: CatchUpRequest, range: CatchUpRange, id: UUID) async {
        defer {
            if generation == id { isLoading = false; task = nil }
        }
        do {
            try checkCurrent(id)
            let loaded = try await request.loadArticles()
            try checkCurrent(id)
            let context = range.filter(loaded)
            articles = context
            guard !context.isEmpty else {
                errorMessage = "Nothing published in the \(range.label.lowercased()). Pick a wider range."
                return
            }
            statusMessage = "Reading \(context.count) \(context.count == 1 ? "article" : "articles")…"
            let selected = try await picks(context, request.settings)
            try checkCurrent(id)
            guard let selected else {
                let text = try await fallback(context, request.settings)
                try checkCurrent(id)
                fallbackText = text
                return
            }
            withAnimation(.easeOut(duration: 0.3)) { page = selected }
            for index in selected.stories.indices {
                try checkCurrent(id)
                let story = selected.stories[index]
                statusMessage = selected.stories.count == 1
                    ? "Writing the lead story…"
                    : "Writing story \(index + 1) of \(selected.stories.count)…"
                let behind = story.articleIndexes.compactMap { handle -> Article? in
                    let offset = handle - 1
                    return context.indices.contains(offset) ? context[offset] : nil
                }
                let written: String
                do { written = try await lede(story.headline, behind, request.settings) }
                catch {
                    try checkCurrent(id)
                    if error is CancellationError { throw error }
                    written = ""
                }
                try checkCurrent(id)
                withAnimation(.easeOut(duration: 0.25)) {
                    page.stories[index].lede = written.isEmpty ? Self.excerptLede(behind) : written
                }
            }
        } catch {
            guard generation == id else { return }
            if error is CancellationError || Task.isCancelled {
                wasStopped = true
            } else {
                errorMessage = error.localizedDescription
                errorRemedy = AIErrorRemedy.classify(error)
            }
        }
    }

    private static func excerptLede(_ articles: [Article]) -> String {
        CatchUpText.fallbackLede(articles.compactMap(\.contentText))
    }
}
