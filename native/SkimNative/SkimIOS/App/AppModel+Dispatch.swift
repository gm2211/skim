import Foundation
import SkimCore

/// The Briefing: the paper the AI writes from the reader's feeds. SkimCore
/// holds the prompts and the checks; this runs the two passes with the
/// reader's model and keeps the edition, so a window is written once.
extension AppModel {
    enum DispatchMode { case open, retry, rewrite }

    /// How much one edition reads, by where the model runs. Apple's on-device
    /// model has a 4k context, so it reads headlines only and fewer reports.
    private struct DispatchBudget {
        var pool: Int
        var excerpt: Int
        var reports: Int
        var reportCharacters: Int
        var editorTokens: Int
        var writerTokens: Int
        var concurrency: Int

        static func forProvider(_ provider: String) -> DispatchBudget {
            switch provider {
            case "foundation-models":
                DispatchBudget(pool: 40, excerpt: 0, reports: 3, reportCharacters: 700, editorTokens: 1_200, writerTokens: 700, concurrency: 1)
            case "mlx":
                DispatchBudget(pool: 60, excerpt: 60, reports: 4, reportCharacters: 1_200, editorTokens: 2_000, writerTokens: 1_000, concurrency: 1)
            default:
                DispatchBudget(pool: 240, excerpt: 160, reports: 6, reportCharacters: 1_800, editorTokens: 3_000, writerTokens: 1_200, concurrency: 3)
            }
        }
    }

    var dispatchEnabled: Bool { settings.ai.provider != "none" }

    func loadDispatch(days: Int, mode: DispatchMode = .open, checkFeeds: Bool = true) async {
        dispatchTask?.cancel()
        let requestID = UUID()
        dispatchLoadID = requestID
        let task = Task { await performDispatch(days: Dispatch.days(days), mode: mode, checkFeeds: checkFeeds, requestID: requestID) }
        dispatchTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancelDispatchWork() {
        dispatchTask?.cancel()
        dispatchTask = nil
        dispatchLoadID = UUID()
        dispatchStatus = nil
    }

    private func isCurrent(_ requestID: UUID) -> Bool { !Task.isCancelled && dispatchLoadID == requestID }

    private func performDispatch(days: Int, mode: DispatchMode, checkFeeds: Bool, requestID: UUID) async {
        let window = Dispatch.window(now: Date(), page: todayPage, days: days)
        let id = Dispatch.editionID(start: window.start, end: window.end, days: days)
        dispatchError = nil
        var stored = try? await store.dispatchEdition(id: id)
        guard isCurrent(requestID) else { return }
        if mode != .rewrite { dispatch = stored }
        if mode == .open, let stored, stored.isComplete {
            dispatchNewArticles = (try? await store.countArticles(from: stored.startsAt, to: stored.endsAt, fetchedAfter: stored.generatedAt)) ?? 0
            return
        }
        if mode == .rewrite { stored = nil; dispatch = nil }
        defer { if dispatchLoadID == requestID { dispatchStatus = nil } }
        let settings = self.settings
        let budget = DispatchBudget.forProvider(settings.ai.provider)

        var edition: DispatchEdition
        if let stored, !stored.themes.isEmpty {
            edition = stored
        } else {
            // A new front page is written from fresh feeds: iOS fetches only when asked.
            if checkFeeds, todayPage == 1, !isLoading, await feedsAreStale() {
                dispatchStatus = "Checking your feeds…"
                await fetchFeedsForToday()
                guard isCurrent(requestID) else { return }
            }
            let articles = (try? await store.articles(from: window.start, to: window.end, limit: 4_000)) ?? []
            let pool = Dispatch.pool(articles, cap: budget.pool)
            let now = Date()
            edition = DispatchEdition(id: id, days: days, startsAt: window.start, endsAt: window.end,
                                      generatedAt: min(max(now, window.start), window.end.addingTimeInterval(-1)))
            edition.articleCount = pool.count
            edition.model = settings.ai.model ?? settings.ai.provider
            if pool.isEmpty {
                edition.isComplete = true
                try? await store.saveDispatchEdition(edition)
                if isCurrent(requestID) { dispatch = edition; dispatchNewArticles = 0 }
                return
            }
            dispatchStatus = "Reading \(pool.count) articles…"
            let instructions = Dispatch.editorInstructions(days: days, interests: settings.ai.triageUserPrompt)
            let prompt = Dispatch.editorPrompt(listing: Dispatch.listing(pool, excerptCharacters: budget.excerpt))
            let plan: (themes: [DispatchEdition.Theme], briefs: [DispatchEdition.Brief])
            do {
                plan = try await Self.askWithOneCorrection(settings: settings, instructions: instructions, prompt: prompt, maxTokens: budget.editorTokens) {
                    try Dispatch.plan($0, pool: pool)
                }
            } catch {
                if isCurrent(requestID) { dispatchError = Self.dispatchFailureReason(error) }
                return
            }
            guard isCurrent(requestID) else { return }
            let used = Set(plan.themes.flatMap(\.articleIDs) + plan.briefs.flatMap(\.articleIDs))
            edition.themes = plan.themes
            edition.briefs = plan.briefs
            edition.articles = pool.filter { used.contains($0.id) }.map {
                DispatchEdition.ArticleRef(id: $0.id, title: $0.title, publication: Dispatch.publication($0), imageURL: $0.imageURL)
            }
            try? await store.saveDispatchEdition(edition)
            dispatch = edition
        }

        // The writers: one piece per theme, each landing as it is filed.
        let pending = edition.themes.indices.filter { !edition.themes[$0].isWritten }
        var jobs: [(index: Int, theme: DispatchEdition.Theme, reports: String)] = []
        for index in pending {
            let theme = edition.themes[index]
            jobs.append((index, theme, await reportsText(theme.articleIDs, count: budget.reports, characters: budget.reportCharacters)))
        }
        guard isCurrent(requestID) else { return }
        var filed = 0
        dispatchStatus = "Writing \(jobs.count) \(jobs.count == 1 ? "piece" : "pieces")…"
        for batch in stride(from: 0, to: jobs.count, by: budget.concurrency) {
            let slice = Array(jobs[batch..<min(batch + budget.concurrency, jobs.count)])
            let results = await withTaskGroup(of: (Int, Dispatch.Piece?, String?).self) { group in
                for job in slice {
                    group.addTask {
                        let count = min(job.theme.articleIDs.count, budget.reports)
                        do {
                            let piece = try await Self.askWithOneCorrection(
                                settings: settings, instructions: Dispatch.writerInstructions,
                                prompt: Dispatch.writerPrompt(theme: job.theme, reports: job.reports), maxTokens: budget.writerTokens
                            ) { try Dispatch.piece($0, reports: count) }
                            return (job.index, piece, nil)
                        } catch {
                            return (job.index, nil, Self.dispatchFailureReason(error))
                        }
                    }
                }
                var results: [(Int, Dispatch.Piece?, String?)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard isCurrent(requestID) else { return }
            for (index, piece, failure) in results {
                filed += 1
                if let piece {
                    if let headline = piece.headline { edition.themes[index].headline = headline }
                    if let dek = piece.dek { edition.themes[index].dek = dek }
                    edition.themes[index].body = piece.body
                    edition.themes[index].takeaways = piece.takeaways
                    edition.themes[index].error = nil
                } else {
                    edition.themes[index].error = failure
                }
            }
            try? await store.saveDispatchEdition(edition)
            dispatch = edition
            dispatchStatus = filed < jobs.count ? "Filed \(filed) of \(jobs.count)…" : nil
        }
        edition.isComplete = true
        try? await store.saveDispatchEdition(edition)
        guard isCurrent(requestID) else { return }
        dispatch = edition
        dispatchNewArticles = (try? await store.countArticles(from: edition.startsAt, to: edition.endsAt, fetchedAfter: edition.generatedAt)) ?? 0
    }

    /// The numbered reports a writer reads, in the theme's order. A report
    /// whose text isn't on the device keeps its number with its headline.
    private func reportsText(_ ids: [String], count: Int, characters: Int) async -> String {
        var reports: [Article] = []
        for id in ids.prefix(count) {
            if let article = try? await store.article(id: id) { reports.append(article) }
        }
        let full = await articlesForTodayChat(reports)
        return full.enumerated().map { number, article in
            let body = String((article.contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(characters))
            return "[\(number + 1)] \(article.title) (\(Dispatch.publication(article)))\n\(body.isEmpty ? "(headline only)" : body)"
        }.joined(separator: "\n\n")
    }

    /// Asks once and, if the answer can't be used, once more with the reason.
    nonisolated private static func askWithOneCorrection<T: Sendable>(
        settings: AppSettings, instructions: String, prompt: String, maxTokens: Int,
        parse: @Sendable (String) throws -> T
    ) async throws -> T {
        let answer = try await NativeAI.complete(settings: settings, instructions: instructions, prompt: prompt,
                                                 maxTokens: maxTokens, jsonMode: true, temperature: 0.2)
        do {
            return try parse(answer)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            let retry = "\(prompt)\n\nYour previous answer could not be used: \(reason). Answer again with only the JSON object in the format asked for."
            return try parse(try await NativeAI.complete(settings: settings, instructions: instructions, prompt: retry,
                                                         maxTokens: maxTokens, jsonMode: true, temperature: 0.2))
        }
    }

    /// A reason the reader can act on.
    nonisolated static func dispatchFailureReason(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let lowered = text.lowercased()
        if ["429", "529", "rate limit", "rate_limit", "overloaded", "timed out", "timeout"].contains(where: lowered.contains) {
            return "The AI provider was busy or rate limited. Try again in a moment."
        }
        if error is Dispatch.Failure { return "\(text)." }
        return "The AI provider failed: \(text.prefix(160))"
    }

    /// The reports a theme was written from, for a chat about it.
    func dispatchReports(_ ids: [String]) async -> [Article] {
        var reports: [Article] = []
        for id in ids { if let article = try? await store.article(id: id) { reports.append(article) } }
        return reports
    }
}
