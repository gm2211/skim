import Foundation
import SkimCore

/// The Briefing: the paper the AI writes from the reader's feeds. SkimCore
/// holds the prompts and the checks; this runs the two passes with the
/// reader's model and keeps the edition, so a window is written once. While
/// a new edition is written the page is never blank: it shows the edition
/// before, or the newest headlines, until the lead lands.
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
        /// Ask for the lead on its own first: worth the extra call only when
        /// requests run side by side, as they do with a hosted model.
        var leadFirst: Bool

        static func forProvider(_ provider: String) -> DispatchBudget {
            switch provider {
            case "foundation-models":
                DispatchBudget(pool: 40, excerpt: 0, reports: 3, reportCharacters: 700, editorTokens: 1_200, writerTokens: 700, concurrency: 1, leadFirst: false)
            case "mlx":
                DispatchBudget(pool: 60, excerpt: 60, reports: 4, reportCharacters: 1_200, editorTokens: 2_000, writerTokens: 1_000, concurrency: 1, leadFirst: false)
            default:
                DispatchBudget(pool: 160, excerpt: 100, reports: 4, reportCharacters: 1_200, editorTokens: 3_000, writerTokens: 900, concurrency: 4, leadFirst: true)
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
        dispatchStandIn = nil
        dispatchPreview = []
    }

    private func isCurrent(_ requestID: UUID) -> Bool { !Task.isCancelled && dispatchLoadID == requestID }

    private func performDispatch(days: Int, mode: DispatchMode, checkFeeds: Bool, requestID: UUID) async {
        let window = Dispatch.window(now: Date(), page: todayPage, days: days)
        let id = Dispatch.editionID(start: window.start, end: window.end, days: days)
        dispatchError = nil
        var stored = try? await store.dispatchEdition(id: id)
        guard isCurrent(requestID) else { return }
        if mode != .rewrite { dispatch = stored }
        if stored?.themes.isEmpty == false || stored?.isComplete == true { dispatchStandIn = nil; dispatchPreview = [] }
        if mode == .open, let complete = stored, complete.isComplete {
            dispatchNewArticles = (try? await store.countArticles(from: complete.startsAt, to: complete.endsAt, fetchedAfter: complete.generatedAt)) ?? 0
            // An empty page is written again once articles arrive for it.
            guard complete.themes.isEmpty, dispatchNewArticles > 0, isCurrent(requestID) else { return }
            stored = nil
        }
        var previous: DispatchEdition?
        if mode == .rewrite { previous = stored; stored = nil; dispatch = nil }
        defer {
            if dispatchLoadID == requestID {
                dispatchStatus = nil
                dispatchStandIn = nil
                dispatchPreview = []
            }
        }
        let settings = self.settings
        let budget = DispatchBudget.forProvider(settings.ai.provider)

        var edition: DispatchEdition
        var pool: [Article] = []
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
            pool = Dispatch.pool(articles, cap: budget.pool)
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
            // Something to read at once: the edition before, or failing that
            // the newest headlines, until the new edition's lead is in.
            if previous == nil {
                previous = try? await store.latestDispatchEdition(days: days, endingBy: window.end, excluding: id)
            }
            guard isCurrent(requestID) else { return }
            dispatchStandIn = previous
            dispatchPreview = previous == nil ? Array(pool.prefix(8)) : []
            dispatchStatus = "Reading \(pool.count) articles…"
        }

        // The editors and the writers run as one group. The front-page editor
        // answers in a few seconds with the lead, whose piece is written
        // while the full plan is still being drawn up; every piece lands on
        // the page the moment it is filed.
        let needsPlan = !pool.isEmpty
        let listing = needsPlan ? Dispatch.listing(pool, excerptCharacters: budget.excerpt) : ""
        // Headlines alone for the lead: the short listing is what makes it quick.
        let leadListing = needsPlan && budget.leadFirst ? Dispatch.listing(pool, excerptCharacters: 0) : ""
        let interests = settings.ai.triageUserPrompt
        let likedTitles = tasteStore.likedTitles()
        var planned = !needsPlan
        var hasLead = false
        var queue = edition.themes.indices.filter { !edition.themes[$0].isWritten }
        var writing = 0
        var failed = false
        await withTaskGroup(of: DispatchEvent.self) { group in
            if needsPlan {
                let candidates = pool
                group.addTask {
                    .plan(await Self.attempt {
                        try await Self.askWithOneCorrection(
                            settings: settings, instructions: Dispatch.editorInstructions(days: days, interests: interests, likedTitles: likedTitles),
                            prompt: Dispatch.editorPrompt(listing: listing), maxTokens: budget.editorTokens
                        ) { try Dispatch.plan($0, pool: candidates) }
                    })
                }
                if budget.leadFirst {
                    group.addTask {
                        .lead(await Self.attempt {
                            try await Self.askWithOneCorrection(
                                settings: settings, instructions: Dispatch.leadInstructions(days: days, interests: interests, likedTitles: likedTitles),
                                prompt: Dispatch.leadPrompt(listing: leadListing), maxTokens: 400
                            ) { try Dispatch.lead($0, pool: candidates) }
                        })
                    }
                }
            }
            while true {
                while writing < budget.concurrency, !queue.isEmpty {
                    let index = queue.removeFirst()
                    let theme = edition.themes[index]
                    let reports = await reportsText(theme.articleIDs, count: budget.reports, characters: budget.reportCharacters)
                    writing += 1
                    group.addTask {
                        let count = min(theme.articleIDs.count, budget.reports)
                        do {
                            let piece = try await Self.askWithOneCorrection(
                                settings: settings, instructions: Dispatch.writerInstructions,
                                prompt: Dispatch.writerPrompt(theme: theme, reports: reports), maxTokens: budget.writerTokens
                            ) { try Dispatch.piece($0, reports: count) }
                            return .piece(index: index, piece: piece, failure: nil)
                        } catch {
                            return .piece(index: index, piece: nil, failure: Self.dispatchFailureReason(error))
                        }
                    }
                }
                guard let event = await group.next() else { break }
                guard isCurrent(requestID) else { group.cancelAll(); failed = true; return }
                switch event {
                case .lead(.success(let lead)) where !planned:
                    hasLead = true
                    edition.themes = [lead]
                    edition.articles = Self.refs(Set(lead.articleIDs), pool: pool)
                    queue = [0]
                    dispatch = edition
                    dispatchStatus = "Writing the lead while the editor reads the rest…"
                case .lead:
                    break
                case .plan(.success(let plan)):
                    planned = true
                    let merged = hasLead ? Dispatch.merge(lead: edition.themes[0], plan: plan) : plan
                    edition.themes = merged.themes
                    edition.briefs = merged.briefs
                    let used = Set(merged.themes.flatMap(\.articleIDs) + merged.briefs.flatMap(\.articleIDs))
                    edition.articles = Self.refs(used, pool: pool)
                    queue = Array(edition.themes.indices.dropFirst(hasLead ? 1 : 0))
                    try? await store.saveDispatchEdition(edition)
                    dispatch = edition
                case .plan(.failure(let error)):
                    planned = true
                    // A lead already on the page stands on its own.
                    guard hasLead else {
                        dispatchError = Self.dispatchFailureReason(error)
                        group.cancelAll()
                        failed = true
                        return
                    }
                    try? await store.saveDispatchEdition(edition)
                case .piece(let index, let piece, let failure):
                    writing -= 1
                    if let piece {
                        if let headline = piece.headline { edition.themes[index].headline = headline }
                        if let dek = piece.dek { edition.themes[index].dek = dek }
                        edition.themes[index].body = piece.body
                        edition.themes[index].takeaways = piece.takeaways
                        edition.themes[index].error = nil
                    } else {
                        edition.themes[index].error = failure
                    }
                    // Kept once the plan is in, so a reopened page resumes the rest.
                    if planned { try? await store.saveDispatchEdition(edition) }
                    dispatch = edition
                }
                if !planned, hasLead, edition.themes[0].isWritten || edition.themes[0].error != nil {
                    dispatchStatus = "Reading \(pool.count) articles for the rest of the page…"
                } else if planned {
                    let filed = edition.themes.filter { $0.isWritten || $0.error != nil }.count
                    dispatchStatus = filed < edition.themes.count ? "Filed \(filed) of \(edition.themes.count)…" : nil
                }
            }
        }
        guard !failed, isCurrent(requestID) else { return }
        edition.isComplete = true
        try? await store.saveDispatchEdition(edition)
        dispatch = edition
        dispatchNewArticles = (try? await store.countArticles(from: edition.startsAt, to: edition.endsAt, fetchedAfter: edition.generatedAt)) ?? 0
    }

    private enum DispatchEvent: Sendable {
        case lead(Result<DispatchEdition.Theme, Error>)
        case plan(Result<(themes: [DispatchEdition.Theme], briefs: [DispatchEdition.Brief]), Error>)
        case piece(index: Int, piece: Dispatch.Piece?, failure: String?)
    }

    nonisolated private static func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private static func refs(_ ids: Set<String>, pool: [Article]) -> [DispatchEdition.ArticleRef] {
        pool.filter { ids.contains($0.id) }.map {
            DispatchEdition.ArticleRef(id: $0.id, title: $0.title, publication: Dispatch.publication($0), imageURL: $0.imageURL)
        }
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
