import OSLog
import SkimCore
import SkimInferencePolicy
import SwiftUI
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Triage JSON parse-failure logger
// Visible in Console.app under subsystem "com.skim.app" category "triage-json".
// Filter: subsystem:com.skim.app category:triage-json
private let triageJSONLogger = Logger(subsystem: "com.skim.app", category: "triage-json")

struct AIResultRequest: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var statusLabel = "Running AI..."
    var action: () async throws -> AIResultAnswer
    /// When provided, the sheet streams tokens into the result area as they arrive
    /// instead of waiting for the full completion. The callback is called on the main
    /// actor with each decoded chunk. The closure must still return the final complete
    /// answer (for cache writes etc.).
    var streamAction: ((@MainActor @escaping (String) -> Void) async throws -> AIResultAnswer)? = nil
    /// When set, the sheet shows a "Clear" button instead of "Run Again".
    /// Invoking it removes the cached result and dismisses the sheet.
    var clearAction: (() -> Void)? = nil
    /// When set, the sheet shows a "Continue in Chat" button.
    /// Invoking it dismisses this sheet and opens the chat with the result pre-loaded.
    var continueInChat: ((String) -> Void)? = nil
}

struct AIResultAnswer {
    var text: String
    var articles: [Article]
}

/// Where a quoted passage in a chat question came from: a sentence of an
/// earlier Skim answer, or a passage the reader highlighted in the article
/// or in a story the AI wrote for the Briefing.
enum ChatQuoteSource: Sendable, Equatable {
    case answer
    case article
    case story

    /// Lead line before the quoted passage in the prompt.
    var promptLead: String {
        switch self {
        case .answer: "Replying to Skim"
        case .article: "About this passage from the article"
        case .story: "About this passage from the story"
        }
    }

    /// Caption above the quote in the composer and the sent bubble.
    var caption: String {
        switch self {
        case .answer: "Replying to Skim"
        case .article: "From the article"
        case .story: "From the story"
        }
    }

    func prompt(quote: String, question: String) -> String {
        "\(promptLead):\n> \(quote.replacingOccurrences(of: "\n", with: "\n> "))\n\n\(question)"
    }
}

struct AIChatConversation: Sendable {
    struct Turn: Sendable {
        enum Role: String, Sendable {
            case user
            case assistant
        }

        var role: Role
        var text: String
        var quotedText: String?
        var quoteSource: ChatQuoteSource = .answer

        var promptText: String {
            guard let quotedText, !quotedText.isEmpty else { return text }
            return quoteSource.prompt(quote: quotedText, question: text)
        }
    }

    var priorTurns: [Turn]
    var latestQuestion: String
    var latestQuote: String?
    var latestQuoteSource: ChatQuoteSource
    var latestPromptText: String {
        guard let latestQuote, !latestQuote.isEmpty else { return latestQuestion }
        return latestQuoteSource.prompt(quote: latestQuote, question: latestQuestion)
    }
    var generatedSummaryContext: String?
    var priorArticleReferences: [Article]
    var priorArticleContext: [Article]
    var priorArticleHandles: [Int]
    var articleHandleRegistry: [String: Int]

    init(latestQuestion: String, quotedText: String? = nil, quoteSource: ChatQuoteSource = .answer, priorMessages: [AIChatMessage] = [], generatedSummaryContext: String? = nil) {
        self.generatedSummaryContext = generatedSummaryContext
        self.latestQuoteSource = quoteSource
        let previousAnswer = priorMessages.last { $0.role == .assistant && !$0.isError }
        self.priorArticleReferences = previousAnswer?.referencedArticles ?? []
        self.priorArticleContext = previousAnswer?.contextArticles ?? []
        self.priorArticleHandles = previousAnswer?.contextHandles ?? []
        var registry: [String: Int] = [:]
        for message in priorMessages where message.role == .assistant && !message.isError {
            for (id, handle) in message.articleHandleRegistry where registry[id] == nil { registry[id] = handle }
            for (article, handle) in zip(message.contextArticles, message.contextHandles) where registry[article.id] == nil {
                registry[article.id] = handle
            }
        }
        self.articleHandleRegistry = registry
        self.latestQuestion = latestQuestion
        let trimmedQuote = quotedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.latestQuote = trimmedQuote?.isEmpty == false ? trimmedQuote : nil
        let trimmedSummary = generatedSummaryContext?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.priorTurns = priorMessages
            .filter { !$0.isError && !($0.role == .assistant && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSummary) }
            .suffix(8)
            .map { message in
                Turn(
                    role: message.role == .user ? .user : .assistant,
                    text: message.text,
                    quotedText: message.quotedText,
                    quoteSource: message.quoteSource
                )
            }
    }

    var priorReferenceTexts: [String] {
        let sources = priorArticleReferences.isEmpty ? priorArticleContext : priorArticleReferences
        return sources.prefix(15).map { "\($0.title)\n\($0.feedTitle)\n\($0.plainBody)" }
    }

    var promptSection: String {
        let summary = AIRequestPolicy.generatedSummaryContext(generatedSummaryContext)
        return [summary, conversationSection].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private var conversationSection: String {
        guard !priorTurns.isEmpty else {
            return latestPrompt()
        }

        let transcript = priorTurns.map { turn in
            let role = turn.role == .user ? "User" : "Assistant"
            return "\(role):\n\(turn.promptText)"
        }
        .joined(separator: "\n\n")

        return """
        Previous conversation for context only. Do not answer these older turns again:
        \(transcript)

        \(latestPrompt())
        """
    }

    private func latestPrompt() -> String {
        return "Latest user question to answer now:\n\(latestPromptText.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

struct AIChatRequest: Identifiable {
    let id = UUID()
    var sessionKey = UUID().uuidString
    var title: String
    var placeholder: String
    var generatedSummaryContext: String? = nil
    /// Questions offered while the chat is empty; tapping one asks it.
    var suggestedPrompts: [String] = []
    /// A passage the reader highlighted in the article; the chat opens with it
    /// quoted above the composer, ready for a question about it.
    var initialArticleQuote: String? = nil
    /// Where `initialArticleQuote` was highlighted.
    var initialQuoteSource: ChatQuoteSource = .article
    /// Deep research, when this chat offers it: the feeds first, then the web,
    /// written up as a cited briefing. Each step is reported as it starts.
    var research: ((AIChatConversation, @MainActor @escaping (String) -> Void) async throws -> AIChatAnswer)? = nil
    var answer: (AIChatConversation) async throws -> AIChatAnswer
}

struct AIChatAnswer {
    var text: String
    var articles: [Article]
    var webCitations: [WebCitation] = []
    var articleHandles: [Int]? = nil
    /// A deep research briefing, whose [wN] cite `webCitations` in order.
    var isResearch = false
}

/// A citation the model surfaced via the `web_search` tool during a chat
/// tool-use loop. Mirrors desktop's `WebCitation` (src-tauri/src/commands/chat.rs)
/// so citation semantics stay consistent across platforms.
struct WebCitation: Identifiable, Sendable {
    let id = UUID()
    var title: String
    var url: String
    var snippet: String
    /// The query the model issued to produce this citation. Useful when
    /// several searches happen across tool iterations.
    var query: String
}

struct NativeAIAvailabilityStatus {
    var title: String
    var detail: String
    var isAvailable: Bool
}

// MARK: - Summary LRU Cache

/// Small persisted LRU cache for article summaries. Keyed by article + provider/model
/// and summary settings so changing the summary style does not return stale text.
private final class SummaryLRUCache: @unchecked Sendable {
    static let shared = SummaryLRUCache()

    private let maxSize = 20
    private let defaults = UserDefaults.standard
    private let orderKey = "skim.summaryCache.order"
    private let valuePrefix = "skim.summaryCache.value."
    private var store: [String: String] = [:]
    // Tracks insertion/access order; last element = most recently used
    private var order: [String] = []
    private let lock = NSLock()

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        restoreOrderIfNeeded()
        let value: String
        if let memoryValue = store[key] {
            value = memoryValue
        } else if let persistedValue = defaults.string(forKey: storageKey(for: key)) {
            value = persistedValue
            store[key] = persistedValue
        } else {
            return nil
        }
        // Move to most-recently-used position
        order.removeAll(where: { $0 == key })
        order.append(key)
        persistOrder()
        return value
    }

    func set(_ key: String, value: String) {
        lock.lock(); defer { lock.unlock() }
        restoreOrderIfNeeded()
        if store[key] != nil || order.contains(key) {
            order.removeAll(where: { $0 == key })
        } else if order.count >= maxSize, let lru = order.first {
            store.removeValue(forKey: lru)
            defaults.removeObject(forKey: storageKey(for: lru))
            order.removeFirst()
        }
        store[key] = value
        order.append(key)
        defaults.set(value, forKey: storageKey(for: key))
        persistOrder()
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: key)
        order.removeAll(where: { $0 == key })
        defaults.removeObject(forKey: storageKey(for: key))
        persistOrder()
    }

    func removeArticle(_ articleID: String) {
        lock.lock(); defer { lock.unlock() }
        restoreOrderIfNeeded()
        let keys = AIRequestPolicy.summaryCacheKeys(for: articleID, among: Array(Set(order + Array(store.keys))))
        for key in keys {
            store.removeValue(forKey: key)
            defaults.removeObject(forKey: storageKey(for: key))
        }
        order.removeAll { keys.contains($0) }
        persistOrder()
    }

    private func storageKey(for key: String) -> String {
        valuePrefix + key
    }

    private func restoreOrderIfNeeded() {
        guard order.isEmpty else { return }
        order = defaults.stringArray(forKey: orderKey) ?? []
    }

    private func persistOrder() {
        defaults.set(Array(order.suffix(maxSize)), forKey: orderKey)
    }
}

/// Unstructured requests allow the caller to leave at the deadline even if a
/// provider ignores cancellation. The loser cannot publish a late result.
private final class TodaySemanticCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TodaySemanticGroup], Error>?
    private var outcome: Result<[TodaySemanticGroup], Error>?
    private var tasks: [Task<Void, Never>] = []
    private var fallback: [TodaySemanticGroup]?

    func install(_ continuation: CheckedContinuation<[TodaySemanticGroup], Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func retain(_ task: Task<Void, Never>) {
        lock.lock()
        if outcome != nil { lock.unlock(); task.cancel() }
        else { tasks.append(task); lock.unlock() }
    }

    func setFallback(_ groups: [TodaySemanticGroup]) {
        lock.lock()
        if outcome == nil { fallback = groups }
        lock.unlock()
    }

    func finish(_ result: Result<[TodaySemanticGroup], Error>, useFallback: Bool = false) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        let result = useFallback ? fallback.map { Result<[TodaySemanticGroup], Error>.success($0) } ?? result : result
        outcome = result
        let continuation = continuation
        self.continuation = nil
        let tasks = tasks
        self.tasks = []
        lock.unlock()
        continuation?.resume(with: result)
        tasks.forEach { $0.cancel() }
    }
}

enum NativeAI {
    static func verifyToday(plan: TodaySemanticPolicy.VerificationPlan, provider: String,
        complete: @Sendable (String, String, Int) async throws -> String) async throws -> [TodaySemanticGroup] {
        let batches = try TodaySemanticPolicy.verificationBatches(plan: plan)
        var responses: [String] = []
        for batch in batches {
            try Task.checkCancellation()
            if provider == "foundation-models",
               batch.payload.utf8.count + TodaySemanticPolicy.pairPrompt.utf8.count > 2400 {
                throw NativeAIError.unavailable("Today verification exceeds the on-device context budget.")
            }
            let response = try await complete(TodaySemanticPolicy.pairPrompt, batch.payload,
                TodaySemanticPolicy.pairOutputTokens)
            try Task.checkCancellation()
            try TodaySemanticPolicy.validateVerificationResponse(response, batch: batch, plan: plan)
            responses.append(response)
        }
        return try TodaySemanticPolicy.verify(responses: responses, plan: plan)
    }

    static func evaluateToday(candidates: [TodaySemanticCandidate], settings: AppSettings) async throws -> [TodaySemanticGroup] {
        let settings = OfflineAIFallback.effective(settings)
        return try await evaluateToday(candidates: candidates, provider: settings.ai.provider) { instructions, payload, maxTokens in
            try await complete(settings: settings, instructions: instructions, prompt: payload,
                maxTokens: maxTokens, jsonMode: true, temperature: 0)
        }
    }

    static func evaluateToday(candidates: [TodaySemanticCandidate], provider: String,
        request: @escaping @Sendable (String, String, Int) async throws -> String) async throws -> [TodaySemanticGroup] {
        guard !candidates.isEmpty, candidates.count <= TodaySemanticPolicy.maximumCandidates else {
            throw NativeAIError.unavailable("Today candidate pool exceeds the semantic context budget.")
        }
        let prompt = try TodaySemanticPolicy.primaryPayload(candidates: candidates)
        let instructions = TodaySemanticPolicy.prompt
        // Conservative local context bound: reserve output capacity as well as
        // input. Do not truncate the pool or silently switch to a cloud model.
        if provider == "foundation-models",
           prompt.utf8.count + instructions.utf8.count > 2400 {
            throw NativeAIError.unavailable("Today candidate pool exceeds the on-device context budget.")
        }
        let completion = TodaySemanticCompletion()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                completion.retain(Task {
                    do {
                        let raw = try await request(instructions, prompt, provider == "foundation-models" ? 1400 : 8192)
                        try Task.checkCancellation()
                        let plan = try TodaySemanticPolicy.verificationPlan(groups: TodaySemanticPolicy.decode(raw), candidates: candidates)
                        let verified = try await verifyToday(plan: plan, provider: provider) { instructions, payload, maxTokens in
                            try await request(instructions, payload, maxTokens)
                        }
                        try Task.checkCancellation()
                        completion.setFallback(verified)
                        do {
                            var rated = verified
                            for groupID in verified.indices where verified[groupID].needsRating {
                                try Task.checkCancellation()
                                guard let ratingPlan = try TodaySemanticPolicy.ratingPlan(groups: rated, candidates: candidates, groupID: groupID) else {
                                    throw NativeAIError.unavailable("Today rating group is unavailable.")
                                }
                                if provider == "foundation-models",
                                   ratingPlan.payload.utf8.count + TodaySemanticPolicy.ratingPrompt.utf8.count > 2400 {
                                    throw NativeAIError.unavailable("Today rating exceeds the on-device context budget.")
                                }
                                let ratingResponse = try await request(TodaySemanticPolicy.ratingPrompt, ratingPlan.payload,
                                    provider == "foundation-models" ? 1400 : 8192)
                                try Task.checkCancellation()
                                rated = try TodaySemanticPolicy.rate(response: ratingResponse, plan: ratingPlan)
                            }
                            try Task.checkCancellation()
                            completion.finish(.success(rated))
                        } catch {
                            if Task.isCancelled || error is CancellationError { completion.finish(.failure(CancellationError())) }
                            else { completion.finish(.success(verified)) }
                        }
                    } catch { completion.finish(.failure(error)) }
                })
                completion.retain(Task {
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                    completion.finish(.failure(NativeAIError.unavailable("Today semantic evaluation timed out.")), useFallback: true)
                })
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return result
    }

    static func loadingStatusLabel(for ai: AISettings) -> String {
        let ai = OfflineAIFallback.effective(ai)
        switch ai.provider {
        case "foundation-models":
            return "Asking Apple Intelligence..."
        case "mlx":
            let repoId = ai.localModelPath?.nilIfEmpty ?? ai.model?.nilIfEmpty ?? NativeMLX.effectiveDefaultRepoId
            return "Running \(NativeMLX.option(for: repoId).label)..."
        case "claude-subscription":
            return "Asking Claude Pro/Max..."
        case "chatgpt-subscription":
            return "Asking ChatGPT..."
        case "custom":
            return "Calling \(ai.model?.nilIfEmpty ?? "custom provider")..."
        case "anthropic":
            return "Asking Claude..."
        case "openai":
            return "Calling OpenAI..."
        case "xai":
            return "Asking Grok..."
        case "openrouter":
            return "Calling OpenRouter..."
        default:
            return "Running AI..."
        }
    }

    static func availabilityStatus() -> NativeAIAvailabilityStatus {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel(useCase: .general)
            switch model.availability {
            case .available:
                return NativeAIAvailabilityStatus(
                    title: "Apple Foundation Models",
                    detail: "Available on this device.",
                    isAvailable: true
                )
            case .unavailable(let reason):
                return NativeAIAvailabilityStatus(
                    title: "Apple Foundation Models",
                    detail: "Unavailable: \(reasonDescription(reason)).",
                    isAvailable: false
                )
            }
        }
#endif
        return NativeAIAvailabilityStatus(
            title: "Apple Foundation Models",
            detail: "Unavailable in this build.",
            isAvailable: false
        )
    }

    /// Maximum number of articles fed into the catch-up prompt.
    /// Raised from the old hardcoded 35 so larger inboxes get real coverage.
    static let catchUpArticleLimit = 1000

    /// Structured catch-up items, still produced by the Foundation Models
    /// guided-generation path and by the legacy JSON shape.
    struct CatchUpItem {
        var title: String
        var summary: String
        /// 1-based index into the articles array the catch-up was built from.
        var articleIndex: Int?
    }

    private static func parseCatchUpItems(_ raw: String) -> [CatchUpItem]? {
        // Reuse shared repair: strip code fences + find balanced JSON
        let cleaned = repairTriageJSON(raw)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = json["items"] as? [[String: Any]]
        else { return nil }

        let items = rawItems.compactMap { dict -> CatchUpItem? in
            guard let title = dict["title"] as? String,
                  let summary = dict["summary"] as? String
            else { return nil }
            let index = dict["articleIndex"] as? Int
            return CatchUpItem(title: title, summary: summary, articleIndex: index)
        }
        return items.isEmpty ? nil : items
    }


    // MARK: - Front page
    //
    // The old catch-up asked one model call for 5–12 "items" over titles and
    // short excerpts, which could only produce category labels ("Self-hosted
    // analytics become more accessible."). The front page runs in two passes
    // instead: pick and group the stories, then read the articles behind each
    // one and write its lede. The sheet drives the passes so the page fills in
    // as it is written rather than appearing all at once.

    /// A story on the front page. `lede` is empty until the second pass writes it.
    struct CatchUpStory: Identifiable, Sendable {
        let id = UUID()
        var headline: String
        var lede: String
        /// 1-based indexes into the articles the page was built from.
        var articleIndexes: [Int]
    }

    /// A one-line item below the fold.
    struct CatchUpBrief: Identifiable, Sendable {
        let id = UUID()
        var text: String
        var articleIndexes: [Int]
    }

    struct CatchUpPage: Sendable {
        var stories: [CatchUpStory] = []
        var briefs: [CatchUpBrief] = []
        var isEmpty: Bool { stories.isEmpty && briefs.isEmpty }
    }

    static let catchUpMaxStories = 6
    static let catchUpMaxBriefs = 6
    /// Articles cited under one story. A story gathers every article on its
    /// topic, so this is generous; it only stops a model that hands one story
    /// every handle it was given from turning the sources into a manifest.
    static let catchUpMaxCitationsPerStory = 8
    static let catchUpMaxCitationsPerBrief = 2
    /// Articles read in full when writing one story's lede.
    static let catchUpArticlesPerLede = 4

    /// What counts as a story, and what a headline is allowed to be. Shared by
    /// both passes so they cannot disagree.
    private static let frontPageStandard = """
        A story is something that happened. "ByteDance open-sourced its RL training stack" is a story. "Open-source RL gains traction" is not — it is a category. If you cannot say what happened, there is no story.

        Headlines:
        - 4-10 words, present tense, naming the specific actor, product, project, company or number involved.
        - Never a trend statement ("... gains traction", "... are improving", "... are emerging", "... becomes more accessible").
        - Never a description of a source or its readership ("Hacker News is active and diverse").
        - Never the name of a feed or a subject area on its own.
        """

    /// Pass one: pick the stories, group the articles under them, and write the
    /// headlines. Returns nil when the model's answer cannot be read, so the
    /// caller can draft the page from the articles instead.
    static func catchUpPicks(articles: [Article], settings: AppSettings) async throws -> CatchUpPage? {
        let settings = OfflineAIFallback.effective(settings)
        // On-device models skip this pass: one prompt over the whole listing
        // is the slowest step of the run on a phone, and small models (Gemma 3
        // 1B) rarely answer it with JSON that can be read. The page is drafted
        // straight from the articles instead, so the first story shows at once
        // and the model only writes the ledes.
        if catchUpRunsOnDevice(settings) {
            return catchUpDraft(articles: articles)
        }

        let raw = try await complete(
            settings: settings,
            instructions: """
            You are the editor of a one-page newspaper built from a reader's RSS feed. Output ONLY valid JSON. No prose. No markdown fences. The format is exactly:
            {"stories":[{"headline":"...","articleIndexes":[1,4]}],"briefs":[{"text":"...","articleIndexes":[7]}]}

            Choose what goes on the front page, gather every article about each story under it, and write each story's headline. Another pass writes the ledes, so you write no summaries here.

            \(frontPageStandard)
            - Never start a headline with the name of a publication, feed or site ("Hacker News ...", "Lobsters: ..."). The sources are cited separately.

            Grouping (the most important part):
            - "articleIndexes" are the 1-based [N] tags from the article list.
            - A story is a topic, and its articleIndexes are ALL the articles in the list about that topic. They are printed under the story as its cited sources, like a newspaper crediting its reporting.
            - Put together: the same link posted on several aggregators (Hacker News, Lobsters, Reddit), several outlets covering the same announcement, release, incident or paper, and follow-ups, analysis or reactions to it.
            - Never group by source, by feed, or by broad subject area. Two unrelated security bugs are two stories, not one "security" story.
            - Every article belongs to at most one story or one brief. Nothing appears twice on the page.
            - Order the stories so the most consequential comes first; a topic many sources cover usually matters more.

            Picking:
            - Aim for 4-6 stories, and prefer fewer real ones over more filler. If only two things actually happened, return two stories.
            - Anything else worth a glance goes in "briefs": one concrete sentence saying what happened, at most 6 of them.
            - Leave out items with nothing to report. An empty briefs list is a perfectly good answer.
            - Output ONLY the JSON object above. No text before or after. No code block.
            """,
            prompt: """
            Build the front page from these articles.

            \(frontPageDigest(articles, limit: catchUpArticleLimit, budget: catchUpDigestBudget(settings: settings)))
            """,
            maxTokens: 1400
        )

        if let page = parseFrontPage(raw, articleCount: articles.count), !page.isEmpty {
            return tidied(page, articles: articles)
        }
        // The model may have answered in the shape catch-up used to ask for.
        if let items = parseCatchUpItems(raw) {
            return frontPage(fromLegacy: items, articleCount: articles.count)
        }
        return nil
    }

    /// What a Catch-up runs on, and the line telling the reader when that is
    /// not the model they picked.
    struct CatchUpProvider {
        var settings: AppSettings
        var notice: String?
    }

    /// Apple Intelligence can be unsupported, switched off, or still
    /// downloading. Rather than dead-end, say which and why, and switch to
    /// another provider that is already set up. With none, the page is still
    /// drafted from the articles and the ledes are excerpts.
    static func catchUpProvider(for settings: AppSettings) -> CatchUpProvider {
        guard settings.ai.provider == "foundation-models",
              let reason = appleIntelligenceUnavailableReason()
        else { return CatchUpProvider(settings: settings, notice: nil) }
        guard let fallback = AIRequestPolicy.fallbackSettings(
            for: settings.ai,
            hasClaudeSubscription: ClaudeKeychainStore.loadAccessToken() != nil,
            downloadedMLXRepoIds: NativeMLX.downloadedRepoIds(),
            preferredMLXRepoId: NativeMLX.effectiveDefaultRepoId
        ) else {
            return CatchUpProvider(settings: settings, notice: "\(reason) Until then the stories below quote the articles.")
        }
        var switched = settings
        switched.ai = fallback
        let name = fallback.provider == "mlx" ? ModelCatalog.currentLabel(fallback) : providerDisplayName(fallback.provider)
        return CatchUpProvider(settings: switched, notice: "\(reason) Using \(name) for this Catch-up.")
    }

    /// Why Apple Intelligence cannot run here, with what to do about it; nil
    /// when it can.
    static func appleIntelligenceUnavailableReason() -> String? {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .unavailable(let reason) = SystemLanguageModel(useCase: .general).availability {
                return appleIntelligenceUnavailableMessage(reason)
            }
            return nil
        }
#endif
        return "Apple Intelligence needs iOS 26 or later."
    }

    /// Providers that run the model on the phone itself.
    static func catchUpRunsOnDevice(_ settings: AppSettings) -> Bool {
        ["mlx", "foundation-models"].contains(settings.ai.provider)
    }

    /// The front page drafted from the articles alone (see `CatchUpDraft`):
    /// related coverage grouped, each story under its best article's headline,
    /// ledes left for the second pass.
    static func catchUpDraft(articles: [Article]) -> CatchUpPage {
        let draft = CatchUpDraft.frontPage(
            articles,
            maxStories: catchUpMaxStories,
            maxBriefs: catchUpMaxBriefs,
            maxCitationsPerStory: catchUpMaxCitationsPerStory,
            maxCitationsPerBrief: catchUpMaxCitationsPerBrief
        )
        return CatchUpPage(
            stories: draft.stories.map { CatchUpStory(headline: $0.text, lede: "", articleIndexes: $0.articleIndexes) },
            briefs: draft.briefs.map { CatchUpBrief(text: $0.text, articleIndexes: $0.articleIndexes) }
        )
    }

    /// Select a source passage under one headline; only an exact, bounded
    /// excerpt from an individual supplied article may be shown.
    struct TodayPreview: Sendable {
        let excerpt: String
        let sourceArticleID: String
        let sourceEvidenceHash: String
    }

    /// The lede under one story: a verified passage from the reports behind
    /// it, read through the same resolver Today uses, so a link-only aggregator
    /// post contributes the page it links to rather than "[Comments][1]".
    static func catchUpLede(headline: String, articles: [Article], settings: AppSettings) async throws -> String {
        let feedArticles = articles.prefix(TodayLedePolicy.maxArticles).map { article in
            var copy = article
            copy.contentText = ArticleReaderContentLoader.displayBody(for: article)
            return copy
        }
        let resolved = (try? await TodayReaderEvidence.resolve(
            articles: Array(feedArticles), limit: TodayLedePolicy.maxArticles,
            cached: { article in ArticleReaderContentLoader.sanitizedText(ExtractedContentCache.shared.get(article.id)) },
            fetch: { article in try await ArticleReaderContentLoader.loadText(for: article).text }
        )) ?? Array(feedArticles)
        try Task.checkCancellation()
        if let preview = try await catchUpPreview(headline: headline, articles: resolved, settings: settings) {
            return preview.excerpt
        }
        return CatchUpText.fallbackLede(resolved.map(\.plainBody))
    }

    /// The story's AI summary, written from its reports the way the desktop
    /// writes it: two or three sentences with one exact supporting quote from
    /// each report. Returns nil when no report has enough text to summarize;
    /// throws when the model can't be reached or its answer fails the check.
    static func todayEditorial(
        headline: String,
        articles: [Article],
        themes: [String],
        settings: AppSettings
    ) async throws -> TodayEditorial? {
        let settings = OfflineAIFallback.effective(settings)
        // Apple's on-device model has a small context window, so it reads two
        // shorter reports, as it does for ledes.
        let onDevice = settings.ai.provider == "foundation-models"
        let characters = onDevice ? 1_500 : TodayLedePolicy.textCharacters
        let reports = articles
            .map { article in
                TodayEditorialPolicy.Report(
                    articleID: article.id,
                    body: String(String.UnicodeScalarView(article.plainBody.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(characters))))
            }
            .filter { TodayEditorialPolicy.usable($0.body) }
            .prefix(onDevice ? 2 : TodayLedePolicy.maxArticles)
        guard !reports.isEmpty else { return nil }
        let prompt = TodayEditorialPolicy.prompt(headline: headline, reports: Array(reports), themes: themes)
        let response = try await complete(
            settings: settings,
            instructions: TodayEditorialPolicy.instructions,
            prompt: prompt,
            maxTokens: TodayEditorialPolicy.maxTokens, jsonMode: true, temperature: 0)
        try Task.checkCancellation()
        do {
            return try TodayEditorialPolicy.validate(response, reports: Array(reports))
        } catch let rejection as TodayEditorialPolicy.Failure {
            // Say once what was wrong; asking the same question again at
            // temperature 0 only returns the same rejected answer.
            let corrected = try await complete(
                settings: settings,
                instructions: TodayEditorialPolicy.instructions,
                prompt: TodayEditorialPolicy.repairPrompt(prompt, answer: response, rejection: rejection.errorDescription ?? "it failed the checks"),
                maxTokens: TodayEditorialPolicy.maxTokens, jsonMode: true, temperature: 0)
            try Task.checkCancellation()
            return try TodayEditorialPolicy.validate(corrected, reports: Array(reports))
        }
    }

    static func catchUpPreview(
        headline: String,
        articles: [Article],
        settings: AppSettings
    ) async throws -> TodayPreview? {
        guard !articles.isEmpty else { return nil }
        let settings = OfflineAIFallback.effective(settings)

        // Apple's on-device model has a small context window: four reports
        // of 3,000 characters each overflowed it, so every lede failed and
        // Retry failed the same way. It reads two shorter reports instead.
        let onDevice = settings.ai.provider == "foundation-models"
        let selected = Array(articles.prefix(onDevice ? 2 : TodayLedePolicy.maxArticles))
        let characters = onDevice ? 1_500 : TodayLedePolicy.textCharacters
        let bodies = selected.map { String(String.UnicodeScalarView($0.plainBody.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(characters))) }
        let text = zip(selected, bodies).map { article, body in
            "--- \(article.title) [\(PublicationName.of(article: article))]\n\(body)"
        }.joined(separator: "\n\n")

        let prompt = """
        Headline: \(headline)

        Article text behind it:
        \(text)
        """
        // Both attempts use the same evidence; the plain retry cannot authorize rewrites.
        // When the model's choice fails the passage check, or the model can't
        // be reached, the lede is the first verified passage taken without a
        // model: asking again at temperature 0 fails the same way, which is
        // why "Some summaries are missing" came straight back after Retry.
        let modelSelection: TodayLedePolicy.Selection?
        do {
            modelSelection = try await TodayLedePolicy.generateSelection(sources: bodies) { instructions, jsonMode in
                try await complete(settings: settings, instructions: instructions, prompt: prompt,
                    maxTokens: 300, jsonMode: jsonMode, temperature: 0)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            print("[NativeAI] Today lede request failed (\(error.localizedDescription)); using a verified source passage.")
            modelSelection = nil
        }
        guard let selection = modelSelection ?? TodayLedePolicy.extractiveSelection(sources: bodies) else { return nil }
        return TodayPreview(excerpt: selection.excerpt,
            sourceArticleID: selected[selection.sourceIndex].id,
            sourceEvidenceHash: selection.evidenceHash)
    }

    /// Strip the wrappers models put around a bare paragraph.
    private static func cleanLede(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .split(separator: "\n")
                .drop { $0.hasPrefix("```") }
                .prefix { !$0.hasPrefix("```") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["Lede:", "lede:", "Summary:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count > 1, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The article list handed to the first pass: enough to pick and group by,
    /// no more. The ledes get the full text later.
    private static func frontPageDigest(_ articles: [Article], limit: Int, budget: CatchUpDigestBudget? = nil) -> String {
        let selected = articles.prefix(limit)
        if selected.isEmpty {
            return "No articles are available."
        }
        let entries: [String] = selected.enumerated().map { index, article in
            // Markup stripped first: a link-only aggregator post is otherwise
            // listed as "[Comments][1] [1]: https://…".
            let text = StoryText.excerpt(article.plainBody)
            let excerpt = text.isEmpty ? "No reader text available." : text.prefixWords(budget?.wordsPerArticle ?? 60)
            return """
            [\(index + 1)] \(article.title)
            Publication: \(PublicationName.of(article: article))
            Excerpt: \(excerpt)
            """
        }
        return fitted(entries, budget: budget)
    }

    /// Characters of article listing an on-device model is handed in one
    /// catch-up prompt. MLX prefills the whole prompt at once, and a week of
    /// unread articles (up to `catchUpArticleLimit` of them, tens of thousands
    /// of tokens) grows the model's memory past what iOS allows an app: the
    /// system kills Skim mid catch-up. Cloud providers and Apple's model are
    /// not affected (the latter reports its own context error).
    struct CatchUpDigestBudget {
        var maxCharacters: Int
        var wordsPerArticle: Int
    }

    static func catchUpDigestBudget(settings: AppSettings) -> CatchUpDigestBudget? {
        guard settings.ai.provider == "mlx" else { return nil }
        switch LocalModelTier.tier(for: NativeMLX.resolvedRepoId(settings.ai)) {
        case .compact: return CatchUpDigestBudget(maxCharacters: 12_000, wordsPerArticle: 30)
        case .mid: return CatchUpDigestBudget(maxCharacters: 16_000, wordsPerArticle: 30)
        case .large: return CatchUpDigestBudget(maxCharacters: 24_000, wordsPerArticle: 40)
        }
    }

    /// The listing entries joined, cut to the leading ones that fit `budget`.
    /// Entries keep their [N] handles, so citations still resolve.
    private static func fitted(_ entries: [String], budget: CatchUpDigestBudget?) -> String {
        let separator = "\n\n"
        guard let budget else { return entries.joined(separator: separator) }
        let count = CatchUpText.entriesFitting(entries, separator: separator, maxCharacters: budget.maxCharacters)
        if count < entries.count {
            Logger(subsystem: "com.skim.app", category: "catchup").info(
                "On-device catch-up reads \(count, privacy: .public) of \(entries.count, privacy: .public) articles to fit the model's memory"
            )
        }
        return entries.prefix(count).joined(separator: separator)
    }

    private static func parseFrontPage(_ raw: String, articleCount: Int) -> CatchUpPage? {
        let cleaned = repairTriageJSON(raw)
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let rawStories = (json["stories"] ?? json["items"]) as? [[String: Any]] ?? []
        let rawBriefs = (json["briefs"] ?? json["notable_mentions"] ?? json["also"]) as? [[String: Any]] ?? []

        // The model is told each article belongs to one item only; hold it to
        // that here so nothing appears twice on the page.
        var claimed = Set<Int>()
        var seenText = Set<String>()
        var page = CatchUpPage()

        for entry in rawStories where page.stories.count < catchUpMaxStories {
            let headline = ((entry["headline"] ?? entry["title"] ?? entry["text"]) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !headline.isEmpty,
                  !CatchUpText.isPlaceholder(headline),
                  seenText.insert(normalizeSentence(headline)).inserted
            else { continue }
            let indexes = articleIndexes(
                from: entry,
                articleCount: articleCount,
                limit: catchUpMaxCitationsPerStory,
                claimed: &claimed
            )
            guard !indexes.isEmpty else { continue }
            let lede = ((entry["lede"] ?? entry["summary"]) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            page.stories.append(
                CatchUpStory(
                    headline: headline,
                    lede: CatchUpText.isPlaceholder(lede) ? "" : lede,
                    articleIndexes: indexes
                )
            )
        }

        for entry in rawBriefs where page.briefs.count < catchUpMaxBriefs {
            let text = ((entry["text"] ?? entry["headline"] ?? entry["summary"]) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  !CatchUpText.isPlaceholder(text),
                  seenText.insert(normalizeSentence(text)).inserted
            else { continue }
            let indexes = articleIndexes(
                from: entry,
                articleCount: articleCount,
                limit: catchUpMaxCitationsPerBrief,
                claimed: &claimed
            )
            guard !indexes.isEmpty else { continue }
            page.briefs.append(CatchUpBrief(text: text, articleIndexes: indexes))
        }

        return page.isEmpty ? nil : page
    }

    /// The 1-based article handles on one entry, dropping any an earlier item
    /// already took and capping the rest at `limit`.
    ///
    /// The cap matters: a model that hands one item every handle it was given
    /// turns the byline into a wall of source chips. Only the handles kept are
    /// marked claimed, so the overflow stays available to a later item.
    private static func articleIndexes(
        from entry: [String: Any],
        articleCount: Int,
        limit: Int,
        claimed: inout Set<Int>
    ) -> [Int] {
        let value = entry["articleIndexes"] ?? entry["article_ids"] ?? entry["articles"]
            ?? entry["ids"] ?? entry["articleIndex"]
        var candidates: [Int] = []
        if let numbers = value as? [Int] {
            candidates = numbers
        } else if let single = value as? Int {
            candidates = [single]
        } else if let mixed = value as? [Any] {
            candidates = mixed.compactMap { element in
                if let number = element as? Int { return number }
                if let text = element as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
                return nil
            }
        } else if let text = value as? String {
            candidates = [Int(text.trimmingCharacters(in: .whitespaces))].compactMap { $0 }
        }
        var kept: [Int] = []
        for index in candidates where kept.count < limit {
            guard index >= 1, index <= articleCount, !claimed.contains(index) else { continue }
            claimed.insert(index)
            kept.append(index)
        }
        return kept
    }

    /// The page after the checks the model is asked for but not trusted with:
    /// a second posting of a story's link joins that story instead of running
    /// as its own brief, and no headline opens with a publication's name.
    private static func tidied(_ page: CatchUpPage, articles: [Article]) -> CatchUpPage {
        var page = page
        func article(_ handle: Int) -> Article? {
            articles.indices.contains(handle - 1) ? articles[handle - 1] : nil
        }
        func sameStory(_ a: Article, _ b: Article) -> Bool {
            let key = CatchUpText.sameStoryKey(a.title)
            if key.split(separator: " ").count >= 3, key == CatchUpText.sameStoryKey(b.title) { return true }
            guard let x = CatchUpText.sameStoryURL(a.externalURL ?? a.url),
                  let y = CatchUpText.sameStoryURL(b.externalURL ?? b.url) else { return false }
            return x == y
        }

        // A later story citing the same piece folds into the earlier one: a
        // model will sometimes run the Hacker News posting of a link as its
        // own story under a reworded headline.
        var i = 0
        while i < page.stories.count {
            var j = i + 1
            while j < page.stories.count {
                let earlier = page.stories[i].articleIndexes.compactMap(article)
                let overlaps = page.stories[j].articleIndexes.compactMap(article)
                    .contains { later in earlier.contains { sameStory($0, later) } }
                if overlaps {
                    let later = page.stories.remove(at: j)
                    for handle in later.articleIndexes where page.stories[i].articleIndexes.count < catchUpMaxCitationsPerStory {
                        page.stories[i].articleIndexes.append(handle)
                    }
                } else {
                    j += 1
                }
            }
            i += 1
        }

        var claimed = Set(page.stories.flatMap(\.articleIndexes))
        let briefClaimed = Set(page.briefs.flatMap(\.articleIndexes))
        for index in page.stories.indices {
            let cited = page.stories[index].articleIndexes.compactMap(article)
            for handle in 1...max(1, articles.count) where page.stories[index].articleIndexes.count < catchUpMaxCitationsPerStory {
                guard !claimed.contains(handle), let candidate = article(handle) else { continue }
                guard cited.contains(where: { sameStory($0, candidate) }) else { continue }
                claimed.insert(handle)
                page.stories[index].articleIndexes.append(handle)
            }
            let publications = page.stories[index].articleIndexes.compactMap(article).map { PublicationName.of(article: $0) }
            page.stories[index].headline = CatchUpText.stripPublicationPrefix(page.stories[index].headline, publications: publications)
        }
        // A brief whose articles all moved under a story has nothing left to cite.
        if !briefClaimed.isDisjoint(with: claimed) {
            page.briefs = page.briefs.compactMap { brief in
                var brief = brief
                brief.articleIndexes.removeAll { claimed.contains($0) }
                return brief.articleIndexes.isEmpty ? nil : brief
            }
        }
        return page
    }

    /// Reshape the older item list into a front page, keeping its headlines.
    private static func frontPage(fromLegacy items: [CatchUpItem], articleCount: Int) -> CatchUpPage {
        var claimed = Set<Int>()
        var page = CatchUpPage()
        for item in items where page.stories.count < catchUpMaxStories {
            let headline = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !headline.isEmpty else { continue }
            var indexes: [Int] = []
            if let index = item.articleIndex, index >= 1, index <= articleCount, claimed.insert(index).inserted {
                indexes = [index]
            }
            page.stories.append(CatchUpStory(headline: headline, lede: "", articleIndexes: indexes))
        }
        return page
    }

    /// One article's AI Inbox rating, keyed by its 1-based position in the batch.
    struct InboxRating: Equatable {
        var importance: Int
        var relevance: Int
        var reason: String
    }

    /// Words of reader context for AI Inbox relevance: explicit interests plus
    /// titles the reader spent time on. Never cited back in reasons.
    static func inboxReaderContext(interests: String?, likedTitles: [String]) -> String {
        var lines: [String] = []
        if let interests = interests?.trimmingCharacters(in: .whitespacesAndNewlines), !interests.isEmpty {
            lines.append("Reader's interests (explicit): \(interests)")
        }
        if !likedTitles.isEmpty {
            lines.append("Titles the reader spent time on (inspiration only, do not cite):")
            lines.append(contentsOf: likedTitles.prefix(15).map { "- \($0)" })
        }
        return lines.isEmpty ? "No interest information is available." : lines.joined(separator: "\n")
    }

    /// Rate every article on importance and relevance (1-5) with the shared
    /// AI Inbox prompt. Returns ratings keyed by 1-based handle.
    static func inboxRatings(articles: [Article], readerContext: String, settings: AppSettings) async throws -> [Int: InboxRating] {
        guard !articles.isEmpty else { return [:] }
        let settings = OfflineAIFallback.effective(settings)
        let digest = articleDigest(articles, limit: articles.count, wordsPerArticle: 40)
#if canImport(FoundationModels)
        if #available(iOS 26.0, *), settings.ai.provider == "foundation-models" {
            return try await inboxRatingsFM(articles: articles, digest: digest, readerContext: readerContext)
        }
#endif
        let raw = try await complete(
            settings: settings,
            instructions: InboxRanking.triagePrompt,
            prompt: """
            \(readerContext)

            Articles:
            \(digest)

            Rate EVERY article above. Refer to articles by their numeric handle.
            Output ONLY JSON:
            {"triage":[{"id":1,"importance":3,"relevance":3,"reason":"short reason"}]}
            """,
            maxTokens: inboxRatingsMaxTokens(count: articles.count),
            jsonMode: true,
            temperature: 0.3
        )
        let ratings = parseInboxRatings(raw, count: articles.count)
        if ratings.isEmpty {
            let preview = String(raw.prefix(200)).replacingOccurrences(of: "\n", with: " ")
            triageJSONLogger.error("AI Inbox ratings parse failed. Raw preview: \(preview, privacy: .public)")
            throw NativeAIError.unavailable("The AI model didn't return usable ratings. Try again or pick another model.")
        }
        return ratings
    }

    /// Output budget for rating `count` articles. An entry with its reason runs to about
    /// 50 tokens; 45 per article left no slack, so a model that wrote longer reasons
    /// was cut off mid-array and the whole batch failed to parse.
    static func inboxRatingsMaxTokens(count: Int) -> Int {
        count * 80 + 300
    }

    /// Tolerant decode of `{"triage":[{id, importance, relevance, reason}]}`;
    /// numbers may arrive as strings and single-axis `priority` fills both axes.
    /// A response cut off mid-array still yields the entries it finished.
    static func parseInboxRatings(_ raw: String, count: Int) -> [Int: InboxRating] {
        func int(_ value: Any?) -> Int? {
            if let n = value as? Int { return n }
            if let d = value as? Double { return Int(d.rounded()) }
            if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        let cleaned = repairTriageJSON(raw)
        let entries: [[String: Any]]
        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let object = json as? [String: Any] {
                entries = (object["triage"] ?? object["ratings"] ?? object["articles"]) as? [[String: Any]] ?? []
            } else {
                entries = json as? [[String: Any]] ?? []
            }
        } else {
            entries = completeTriageEntries(raw)
        }
        var out: [Int: InboxRating] = [:]
        for entry in entries {
            guard let id = int(entry["id"] ?? entry["handle"] ?? entry["articleIndex"]),
                  (1...count).contains(id)
            else { continue }
            let priority = int(entry["priority"])
            guard let importance = int(entry["importance"]) ?? priority,
                  let relevance = int(entry["relevance"]) ?? priority
            else { continue }
            out[id] = InboxRating(
                importance: min(5, max(1, importance)),
                relevance: min(5, max(1, relevance)),
                reason: (entry["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return out
    }

    /// The objects a truncated `{"triage":[{…},{…},{"id":` response finished, in order.
    /// Scans from the first `[` and keeps each balanced `{…}` directly inside it.
    static func completeTriageEntries(_ raw: String) -> [[String: Any]] {
        guard let arrayStart = raw.firstIndex(of: "[") else { return [] }
        var entries: [[String: Any]] = []
        var depth = 0
        var inString = false
        var escaped = false
        var objectStart: String.Index?
        var idx = raw.index(after: arrayStart)
        while idx < raw.endIndex {
            let ch = raw[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    if depth == 0 { objectStart = idx }
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0, let start = objectStart,
                       let data = String(raw[start...idx]).data(using: .utf8),
                       let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        entries.append(entry)
                    }
                    if depth < 0 { break }
                } else if ch == "]" && depth == 0 {
                    break
                }
            }
            idx = raw.index(after: idx)
        }
        return entries
    }

    // MARK: - Structured triage JSON (used by auto-group and future JSON consumers)

    /// Decode a raw MLX/model string as triage JSON, applying a repair pass on failure.
    /// Logs parse failures via `triageJSONLogger` so Console.app shows which model misbehaved.
    /// - Returns: decoded value on success, throws on unrecoverable failure.
    static func decodeTriageJSON<T: Decodable>(
        _ type: T.Type,
        from raw: String,
        modelID: String
    ) throws -> T {
        let decoder = JSONDecoder()

        // 1. Strict decode first
        if let data = raw.data(using: .utf8),
           let value = try? decoder.decode(type, from: data) {
            return value
        }

        // 2. Attempt repair: strip code fences, find outermost balanced braces/brackets
        let repaired = repairTriageJSON(raw)
        if repaired != raw {
            if let data = repaired.data(using: .utf8),
               let value = try? decoder.decode(type, from: data) {
                triageJSONLogger.warning("Triage JSON repaired for model '\(modelID, privacy: .public)': stripped fences/junk. Consider upgrading prompt.")
                return value
            }
        }

        // 3. Log failure and throw
        let preview = String(raw.prefix(200)).replacingOccurrences(of: "\n", with: " ")
        triageJSONLogger.error("Triage JSON parse failed for model '\(modelID, privacy: .public)'. Raw preview: \(preview, privacy: .public)")
        throw NativeAIError.unavailable("Could not parse triage JSON from model '\(modelID)'. Falling back to local triage.")
    }

    /// Strip markdown code fences, find the outermost `{...}` or `[...]`, drop trailing junk.
    static func repairTriageJSON(_ raw: String) -> String {
        // Strip code fences
        let withoutFences = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^```[a-zA-Z]*\\n?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "```$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Find balanced { ... }
        if let start = withoutFences.firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaped = false
            var idx = withoutFences.startIndex
            while idx < withoutFences.endIndex {
                let ch = withoutFences[idx]
                if escaped {
                    escaped = false
                } else if ch == "\\" && inString {
                    escaped = true
                } else if ch == "\"" {
                    inString.toggle()
                } else if !inString {
                    if ch == "{" { depth += 1 }
                    else if ch == "}" {
                        depth -= 1
                        if depth == 0, idx >= start {
                            return String(withoutFences[start...idx])
                        }
                    }
                }
                idx = withoutFences.index(after: idx)
            }
        }

        // Fallback: find balanced [ ... ]
        if let start = withoutFences.firstIndex(of: "[") {
            var depth = 0
            var inString = false
            var escaped = false
            var idx = withoutFences.startIndex
            while idx < withoutFences.endIndex {
                let ch = withoutFences[idx]
                if escaped {
                    escaped = false
                } else if ch == "\\" && inString {
                    escaped = true
                } else if ch == "\"" {
                    inString.toggle()
                } else if !inString {
                    if ch == "[" { depth += 1 }
                    else if ch == "]" {
                        depth -= 1
                        if depth == 0, idx >= start {
                            return String(withoutFences[start...idx])
                        }
                    }
                }
                idx = withoutFences.index(after: idx)
            }
        }

        return withoutFences
    }

    static func summarize(article: Article, settings: AppSettings) async throws -> String {
        let settings = OfflineAIFallback.effective(settings)
        let publication = AIPublicationGate()
        defer { publication.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let key = summaryCacheKey(article: article, ai: settings.ai)
            if let cached = SummaryLRUCache.shared.get(key) {
                return cached
            }
            let wordCount = summaryTargetWordCount(settings.ai)
            // Pass wordCount into instructions so the system prompt carries the full directive.
            // The user turn contains only the article body to avoid FM echoing the instruction
            // text back as part of the response (a known issue with some Foundation Models builds).
            let result = AIRequestPolicy.completeSummary(try await complete(
                settings: settings,
                instructions: summaryInstructions(settings.ai, wordCount: wordCount),
                prompt: """
                Article to summarize:

                \(articleDigest([article], limit: 1, wordsPerArticle: 2200))
                """,
                maxTokens: AIRequestPolicy.summaryRequestMaxTokens(settings.ai)
            ))
            try Task.checkCancellation()
            guard publication.publish({ SummaryLRUCache.shared.set(key, value: result) }) else { throw CancellationError() }
            return result
        } onCancel: { publication.cancel() }
    }

    /// Streaming variant of `summarize`. For MLX provider this calls `NativeMLX.stream()`
    /// so the UI can render tokens progressively. `onToken` is called on the calling context
    /// with each decoded chunk. For non-MLX providers the result is delivered in one shot
    /// (onToken is not called during generation; the final text is returned normally).
    /// Returns the full sanitized summary and writes it to the LRU cache.
    static func summarizeStreaming(
        article: Article,
        settings: AppSettings,
        onToken: @MainActor @escaping (String) -> Void
    ) async throws -> String {
        let settings = OfflineAIFallback.effective(settings)
        let publication = AIPublicationGate()
        defer { publication.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let key = summaryCacheKey(article: article, ai: settings.ai)
            if let cached = SummaryLRUCache.shared.get(key) {
                try Task.checkCancellation()
                await MainActor.run { publication.publish { onToken(cached) } }
                try Task.checkCancellation()
                return cached
            }
            let wordCount = summaryTargetWordCount(settings.ai)
            let prompt = """
            Article to summarize:

            \(articleDigest([article], limit: 1, wordsPerArticle: 2200))
            """
            let instructions = summaryInstructions(settings.ai, wordCount: wordCount)
            let maxTok = AIRequestPolicy.summaryRequestMaxTokens(settings.ai)

            var result: String
            if settings.ai.provider == "mlx" {
                result = try await NativeMLX.stream(
                    settings: settings.ai,
                    instructions: instructions,
                    prompt: prompt,
                    maxTokens: maxTok,
                    jsonMode: false,
                    onToken: { chunk in
                        Task { @MainActor in publication.publish { onToken(chunk) } }
                    }
                )
            } else {
                result = try await complete(
                    settings: settings,
                    instructions: instructions,
                    prompt: prompt,
                    maxTokens: maxTok
                )
            }
            result = AIRequestPolicy.completeSummary(result)

            try Task.checkCancellation()
            guard publication.publish({ SummaryLRUCache.shared.set(key, value: result) }) else { throw CancellationError() }
            return result
        } onCancel: { publication.cancel() }
    }

    /// Evicts the cached summary for the given article + settings combination.
    static func clearSummaryCache(articleID: String, ai: AISettings) {
        SummaryLRUCache.shared.removeArticle(articleID)
    }

    private static func summaryCacheKey(article: Article, ai: AISettings) -> String {
        let model = ai.model?.nilIfEmpty ?? ai.provider
        let wordCount = summaryTargetWordCount(ai)
        return [
            article.id,
            "summary-v5",
            AIRequestPolicy.summaryPlan(ai).cacheIdentity,
            AIRequestPolicy.summarySourceFingerprint(articleDigest([article], limit: 1, wordsPerArticle: 2200)),
            ai.provider,
            model,
            ai.endpoint?.nilIfEmpty ?? "",
            ai.localModelPath?.nilIfEmpty ?? "",
            ai.summaryLength?.nilIfEmpty ?? "",
            ai.summaryTone?.nilIfEmpty ?? "",
            String(wordCount),
            ai.summaryCustomPrompt?.nilIfEmpty ?? "",
        ].joined(separator: "|")
    }

    // MARK: - Local MLX web search (skim-7oi1)

    /// Decision produced by the router pass for local MLX chat.
    enum LocalSearchDecision {
        case answer
        case search(String)
    }

    /// Parse the single-line router output from the local model.
    /// Returns `.search(query)` if the output matches `SEARCH: <query>`,
    /// `.answer` if it contains "ANSWER", and `.answer` for any ambiguous/empty/garbage output.
    static func parseRouterDecision(_ raw: String) -> LocalSearchDecision {
        let line = raw
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? ""

        // Try SEARCH: <query> pattern (case-insensitive)
        let pattern = #"^\s*SEARCH\s*[:\-]\s*(.+)$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let ns = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let queryRange = match.range(at: 1)
                if queryRange.location != NSNotFound, let range = Range(queryRange, in: line) {
                    var query = String(line[range])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Strip surrounding quotes / backticks / angle brackets
                    query = query.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>"))
                    // Reject placeholder-like values or very long strings
                    if query.isEmpty || query.lowercased() == "query" || query.count > 200 {
                        return .answer
                    }
                    // Clamp to at most 12 words
                    let words = query.split(separator: " ").prefix(12)
                    query = words.joined(separator: " ")
                    return .search(query)
                }
            }
        }

        // If output contains ANSWER (case-insensitive) -> answer
        if line.range(of: "ANSWER", options: .caseInsensitive) != nil {
            return .answer
        }

        // Default: ambiguous/empty -> answer (never search on garbage)
        return .answer
    }

    /// Format web search results into a plain numbered block for injection into the answer prompt.
    static func formatWebResultsBlock(query: String, results: [SearchResult]) -> String {
        let header = "Web search results for \"\(query)\" (use for facts not in the article; answer in prose, and cite a result you use by its number, like [w1], right after the claim):"
        let body = results.enumerated().map { index, result in
            let label = "[w\(index + 1)]"
            return "\(label) \(result.title)\n    \(result.snippet)\n    \(result.url)"
        }
        .joined(separator: "\n")
        return header + "\n" + body
    }

    /// Returns true when local MLX web search is enabled for the given settings.
    private static func localWebSearchEnabled(_ ai: AISettings) -> Bool {
        ai.provider == "mlx" && (ai.localChatWebSearch ?? true)
    }

    /// Pre-gate: return true to skip the router and answer directly.
    /// Only suppresses the router — never forces a search.
    /// Conservative: returns false when in doubt.
    private static func canSkipRouter(conversation: AIChatConversation, articleCount: Int) -> Bool {
        guard articleCount == 1 else { return false }
        let q = conversation.latestQuestion.lowercased()
        guard q.split(separator: " ").count <= 8 else { return false }
        let freshnessTokens = ["latest", "current", "today", "now", "recent", "price", "weather",
                               "who won", "look up", "search", "google"]
        for token in freshnessTokens {
            if q.contains(token) { return false }
        }
        return true
    }

    /// Router pass: ask the local model whether to ANSWER or SEARCH, with maxTokens 24.
    /// Never throws — returns .answer on any error.
    private static func routeLocalChat(
        conversation: AIChatConversation,
        articleContext: String,
        settings: AppSettings
    ) async -> LocalSearchDecision {
        let routerSystem = """
        You are a routing assistant. Decide whether to answer from the article or search the web.
        Reply with EXACTLY one line — either:
          ANSWER
        or:
          SEARCH: <concise search query>

        Examples:
          User: What is the author's main argument?
          Reply: ANSWER

          User: What is the current price of Bitcoin?
          Reply: SEARCH: Bitcoin price today

          User: Who won the 2024 US election?
          Reply: SEARCH: 2024 US election winner

          User: Summarize the article.
          Reply: ANSWER

        If you are not sure, reply ANSWER. Never explain your choice.
        """
        let digest = articleContext
        let routerUser = """
        \(digest)

        \(conversation.latestQuestion)
        """
        do {
            let raw = try await NativeMLX.complete(
                settings: settings.ai,
                instructions: routerSystem,
                prompt: routerUser,
                maxTokens: 24,
                jsonMode: false
            )
            return parseRouterDecision(raw)
        } catch {
            return .answer
        }
    }

    /// Build a multi-turn messages array for local MLX chat. Produces:
    ///   [system] instructions + article context + optional web block
    ///   [user/assistant] one message per prior turn in conversation.priorTurns
    ///   [user] conversation.latestQuestion
    static func buildLocalChatMessages(
        instructions: String,
        articleContext: String,
        conversation: AIChatConversation,
        webBlock: String?
    ) -> [[String: String]] {
        var systemContent = instructions + "\n\nArticle:\n\(articleContext)"
        if let webBlock {
            systemContent += "\n\n\(webBlock)"
        }
        let systemMessage: [String: String] = ["role": "system", "content": systemContent]

        let priorTurnMessages: [[String: String]] = conversation.priorTurns.map { turn in
            ["role": turn.role == .user ? "user" : "assistant", "content": turn.promptText]
        }

        let finalContent = [AIRequestPolicy.generatedSummaryContext(conversation.generatedSummaryContext), conversation.latestPromptText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let finalUser: [String: String] = ["role": "user", "content": finalContent]

        return [systemMessage] + priorTurnMessages + [finalUser]
    }

    /// Builds the grounded, answer-first local MLX chat-with-article prompt
    /// (`GroundedChatPrompt.build`'s `[system, user]`, question last). Never
    /// includes the raw generated-summary text as its own turn: the prior
    /// exchange folded in is either the most recent real user/assistant pair
    /// from `conversation.priorTurns`, or — only when there are no prior
    /// turns and the new question reads as a contextual follow-up to the
    /// summary (e.g. "why does that matter?") — the generated summary itself,
    /// truncated by `GroundedChatPrompt.build` and labeled "Earlier summary"
    /// rather than presented as something the model itself said.
    static func buildGroundedLocalMessages(
        conversation: AIChatConversation,
        articleContext: String,
        webBlock: String?
    ) -> [[String: String]] {
        let question = conversation.latestQuestion
        let system = GroundedChatPrompt.systemPrompt(question: question)

        var priorExchange: (question: String, answer: String, label: String)?
        if let lastUser = conversation.priorTurns.last(where: { $0.role == .user }),
           let lastAssistant = conversation.priorTurns.last(where: { $0.role == .assistant }) {
            priorExchange = (question: lastUser.promptText, answer: lastAssistant.text, label: "A")
        } else if conversation.priorTurns.isEmpty,
                  let summary = conversation.generatedSummaryContext?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty,
                  LibraryChatPolicy.isContextualFollowup(question, referenceTexts: [summary]) {
            priorExchange = (question: question, answer: summary, label: "Earlier summary")
        }

        let messages = GroundedChatPrompt.build(
            system: system,
            articleContext: articleContext,
            question: conversation.latestPromptText,
            priorExchange: priorExchange,
            webBlock: webBlock
        )
        return messages.map { ["role": $0.role, "content": $0.content] }
    }

    static func chatInstructions(isLibrary: Bool, enableWebSearch: Bool) -> String {
        let base = isLibrary
            ? "You answer questions across a set of RSS articles using the provided article list and any supplied web search results. Use previous turns only to resolve references like 'that' or 'the second one'; prior assistant turns are context, not evidence. Answer only the latest user question. Do not repeat a prior answer unless the latest question explicitly asks. Answer first, in plain prose of about 50 to 100 words, so the reader gets the gist without opening the articles. Cite each article you draw on with its numeric handle like [3], placed right after the claim it supports. Do not list the articles or repeat their titles as a list: the app shows every cited article as a card under the answer. If the answer is not supported by the supplied articles or web results, say so."
            : "You answer questions about a single article using the provided article text and any supplied web search results. Use previous turns only to resolve references like 'that' or 'the second one'; prior assistant turns are context, not evidence. Answer only the latest user question. Do not repeat a prior answer unless the latest question explicitly asks you to recap it. If the answer is not supported by the supplied article text or web results, say so."
        let corrected = base + "\n\n" + ChatCorrections.instructions
        guard enableWebSearch else { return corrected }
        return corrected + "\n\nIf the provided article context doesn't answer the latest question, call the `web_search` tool to fetch fresh web results, then answer using them. Prefer the article context when it suffices. Cite each web result you use by its number, like [w2], right after the claim it supports."
    }

    /// Local MLX chat with optional web-search augmentation (2-pass: router + answer).
    /// Falls back to a plain local answer on any failure in the router or search step.
    /// Grounded, answer-first prompting (skim-p9ol): context/token budgets scale with
    /// the model's parameter-count tier, the prompt is built by `buildGroundedLocalMessages`,
    /// sampling comes from `GroundedChatPrompt.samplingPreset`, and the raw completion is
    /// run through `ChatAnswerCleanup` before it reaches the UI.
    private static func chatLocalWithSearch(
        conversation: AIChatConversation,
        article: Article,
        settings: AppSettings
    ) async throws -> (text: String, citations: [WebCitation]) {
        let repoId = NativeMLX.resolvedRepoId(settings.ai)
        let budget = ChatContextBudget.forTier(LocalModelTier.tier(for: repoId))
        let sampling = GroundedChatPrompt.samplingPreset(basedOn: MLXSamplingPreset.preset(for: repoId))

        func answer(articleContext: String, webBlock: String?) async throws -> String {
            let msgs = buildGroundedLocalMessages(conversation: conversation, articleContext: articleContext, webBlock: webBlock)
            let raw = try await NativeMLX.complete(
                settings: settings.ai,
                messages: msgs,
                maxTokens: budget.maxTokens,
                temperature: Double(sampling.temperature),
                topP: Double(sampling.topP),
                repetitionPenalty: Double(sampling.repetitionPenalty),
                reusablePrefixMarker: PromptPrefix.articleMarker
            )
            return ChatAnswerCleanup.clean(raw, question: conversation.latestQuestion)
        }

        let articleContext = try groundedArticleContext(article: article, conversation: conversation, maxCharacters: budget.evidenceChars)
        let skipRouter = canSkipRouter(conversation: conversation, articleCount: 1)

        let decision: LocalSearchDecision
        if skipRouter {
            decision = .answer
        } else if let routerContext = try? groundedArticleContext(article: article, conversation: conversation, maxCharacters: budget.routerChars) {
            decision = await routeLocalChat(
                conversation: conversation,
                articleContext: routerContext,
                settings: settings
            )
        } else {
            decision = .answer
        }

        switch decision {
        case .answer:
            return (try await answer(articleContext: articleContext, webBlock: nil), [])

        case .search(let query):
            let results = (try? await NativeWebSearch.run(query: query, maxResults: 4)) ?? []
            guard !results.isEmpty else {
                // Empty results: fall back to answering from article only (multi-turn, no web block)
                return (try await answer(articleContext: articleContext, webBlock: nil), [])
            }
            let webBlock = "Web search results are provided below; use them for facts the article doesn't cover; if they don't help, say what you couldn't find.\n\n"
                + formatWebResultsBlock(query: query, results: results)
            // Reselect from the full source at the smaller web-augmented budget.
            let trimmedContext = try groundedArticleContext(article: article, conversation: conversation, maxCharacters: budget.webEvidenceChars)
            let text = try await answer(articleContext: trimmedContext, webBlock: webBlock)
            return (text, results.map { WebCitation(title: $0.title, url: $0.url, snippet: $0.snippet, query: query) })
        }
    }

    static func chat(question: String, article: Article, settings: AppSettings) async throws -> String {
        try await chat(
            conversation: AIChatConversation(latestQuestion: question),
            article: article,
            settings: settings
        ).text
    }

    static func chat(
        conversation: AIChatConversation, article: Article, settings: AppSettings,
        urlSession: URLSession = .shared
    ) async throws -> (text: String, citations: [WebCitation]) {
        var settings = settings
        settings.ai = OfflineAIFallback.effective(AIRequestPolicy.chatSettings(settings.ai))
        let toolsOK = ["anthropic", "claude-subscription"].contains(settings.ai.provider)
        let instructions = chatInstructions(isLibrary: false, enableWebSearch: toolsOK)

        // Local MLX web-search path (skim-7oi1)
        if localWebSearchEnabled(settings.ai) {
            return try await chatLocalWithSearch(
                conversation: conversation,
                article: article,
                settings: settings
            )
        }

        // MLX without web search: grounded, answer-first prompting (skim-p9ol) —
        // context/token budgets scale with the model's tier, sampling comes from
        // GroundedChatPrompt.samplingPreset, and the output is cleaned before display.
        if settings.ai.provider == "mlx" {
            let repoId = NativeMLX.resolvedRepoId(settings.ai)
            let budget = ChatContextBudget.forTier(LocalModelTier.tier(for: repoId))
            let sampling = GroundedChatPrompt.samplingPreset(basedOn: MLXSamplingPreset.preset(for: repoId))
            let articleContext = try groundedArticleContext(article: article, conversation: conversation, maxCharacters: budget.evidenceChars)
            let msgs = buildGroundedLocalMessages(conversation: conversation, articleContext: articleContext, webBlock: nil)
            let raw = try await NativeMLX.complete(
                settings: settings.ai,
                messages: msgs,
                maxTokens: budget.maxTokens,
                temperature: Double(sampling.temperature),
                topP: Double(sampling.topP),
                repetitionPenalty: Double(sampling.repetitionPenalty),
                reusablePrefixMarker: PromptPrefix.articleMarker
            )
            let text = ChatAnswerCleanup.clean(raw, question: conversation.latestQuestion)
            return (text, [])
        }

        let articleContext = try singleArticleChatContext(article: article, conversation: conversation)
        return try await completeWithCitations(
            settings: settings,
            instructions: instructions,
            prompt: """
            Article:
            \(articleContext)

            \(conversation.promptSection)
            """,
            maxTokens: AIRequestPolicy.requestMaxTokens(650, provider: settings.ai.provider),
            enableWebSearch: toolsOK,
            urlSession: urlSession,
            messages: buildLocalChatMessages(
                instructions: instructions,
                articleContext: articleContext,
                conversation: conversation,
                webBlock: nil
            )
        )
    }

    static func validateChatEvidence(source: String, excerpt: String) throws {
        guard source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !excerpt.isEmpty else {
            throw NativeAIError.unavailable("Could not prepare article text for this question. Try opening the article again.")
        }
    }

    static func singleArticleChatContext(article: Article, conversation: AIChatConversation, maxCharacters: Int = 12000) throws -> String {
        let body = article.plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = ChatEvidencePolicy.retrievalQuery(query: conversation.latestQuestion,
            priorUserQueries: conversation.priorTurns.filter { $0.role == .user }.map(\.text), referenceText: body)
        let excerpt = body.isEmpty ? "No reader text available."
            : ChatEvidencePolicy.excerpt(text: body, query: query, maxCharacters: maxCharacters)
        try validateChatEvidence(source: body, excerpt: excerpt)
        return "[1] \(article.title)\nFeed: \(article.feedTitle)\nAuthor: \(article.author ?? "unknown")\n\(AIRequestPolicy.publicationContext(article.publishedAt))\nExcerpt: \(excerpt)"
    }

    /// Grounded-chat successor to `singleArticleChatContext`: builds the same
    /// `[1] title/feed/author/date/excerpt` header via `ChatEvidencePolicy.articleContext`
    /// (byte-identical to the inline formatting above), but term-expands the retrieval
    /// query first (`ChatEvidencePolicy.expandedQuery`) so plural/singular near-misses
    /// (e.g. a question about "nozzles" against source text that only says "nozzle")
    /// still match the shared selector's exact, unstemmed casefold matching.
    static func groundedArticleContext(article: Article, conversation: AIChatConversation, maxCharacters: Int) throws -> String {
        let body = article.plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = ChatEvidencePolicy.expandedQuery(
            ChatEvidencePolicy.retrievalQuery(query: conversation.latestQuestion,
                priorUserQueries: conversation.priorTurns.filter { $0.role == .user }.map(\.text), referenceText: body)
        )
        let excerpt = body.isEmpty ? "No reader text available."
            : ChatEvidencePolicy.excerpt(text: body, query: query, maxCharacters: maxCharacters)
        try validateChatEvidence(source: body, excerpt: excerpt)
        return ChatEvidencePolicy.articleContext(
            title: article.title,
            feedTitle: article.feedTitle,
            author: article.author,
            publishedAt: article.publishedAt,
            body: body,
            query: query,
            maxCharacters: maxCharacters
        )
    }

    static func libraryChatHandleRegistry(articles: [Article], conversation: AIChatConversation) -> [String: Int] {
        var registry = conversation.articleHandleRegistry
        var next = (registry.values.max() ?? 0) + 1
        for article in articles where registry[article.id] == nil {
            registry[article.id] = next
            next += 1
        }
        return registry
    }

    static func libraryChatHandles(articles: [Article], conversation: AIChatConversation) -> [Int] {
        let registry = libraryChatHandleRegistry(articles: articles, conversation: conversation)
        return articles.compactMap { registry[$0.id] }
    }

    static func libraryChatContext(articles: [Article], conversation: AIChatConversation) throws -> String {
        let priorIDs = Set((conversation.priorArticleReferences.isEmpty
            ? conversation.priorArticleContext : conversation.priorArticleReferences).map(\.id))
        let refreshedReferences = articles.filter { priorIDs.contains($0.id) }
            .map { "\($0.title)\n\($0.feedTitle)\n\($0.plainBody)" }
        let topic = LibraryChatPolicy.retrievalTopic(query: conversation.latestQuestion,
            priorUserQueries: conversation.priorTurns.filter { $0.role == .user }.map(\.text),
            referenceTexts: refreshedReferences.isEmpty ? conversation.priorReferenceTexts : refreshedReferences)
        let handles = libraryChatHandles(articles: articles, conversation: conversation)
        return try zip(articles, handles).enumerated().map { index, source in
            let (article, handle) = source
            let excerpt = LibraryChatPolicy.queryExcerpt(text: article.plainBody,
                query: (topic.terms + LibraryChatPolicy.topicKeywords(conversation.latestQuestion)).joined(separator: " "), maxCharacters: index < 3 ? 2400 : 800)
            try validateChatEvidence(source: article.plainBody, excerpt: excerpt)
            return "[\(handle)] \(article.title)\nFeed: \(article.feedTitle)\nURL: \(article.externalURL?.absoluteString ?? article.url?.absoluteString ?? "")\n\(AIRequestPolicy.publicationContext(article.publishedAt))\nExcerpt: \(excerpt)"
        }.joined(separator: "\n\n")
    }

    static func chat(question: String, articles: [Article], settings: AppSettings) async throws -> String {
        try await chat(
            conversation: AIChatConversation(latestQuestion: question),
            articles: articles,
            settings: settings
        ).text
    }

    static func chat(
        conversation: AIChatConversation, articles: [Article], settings: AppSettings,
        urlSession: URLSession = .shared
    ) async throws -> (text: String, citations: [WebCitation]) {
        var settings = settings
        settings.ai = OfflineAIFallback.effective(AIRequestPolicy.chatSettings(settings.ai))
        let toolsOK = ["anthropic", "claude-subscription"].contains(settings.ai.provider)
        let instructions = chatInstructions(isLibrary: true, enableWebSearch: toolsOK)
        let context = try libraryChatContext(articles: articles, conversation: conversation)
        if settings.ai.provider == "mlx" {
            let messages = buildLocalChatMessages(instructions: chatInstructions(isLibrary: true, enableWebSearch: false), articleContext: context,
                conversation: conversation, webBlock: nil)
            let raw = try await NativeMLX.complete(settings: settings.ai, messages: messages, maxTokens: 850)
            return (ChatAnswerCleanup.clean(raw, question: conversation.latestQuestion), [])
        }
        return try await completeWithCitations(
            settings: settings,
            instructions: instructions,
            prompt: """
            Articles:
            \(context)

            \(conversation.promptSection)
            """,
            maxTokens: AIRequestPolicy.requestMaxTokens(850, provider: settings.ai.provider),
            enableWebSearch: toolsOK,
            urlSession: urlSession,
            messages: buildLocalChatMessages(
                instructions: instructions,
                articleContext: context,
                conversation: conversation,
                webBlock: nil
            )
        )
    }

    static func complete(
        settings: AppSettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        jsonMode: Bool = false,
        enableWebSearch: Bool = false,
        temperature: Double? = nil
    ) async throws -> String {
        try await OfflineAIFallback.run(settings) { settings in
            try await completeOnProvider(
                settings: settings, instructions: instructions, prompt: prompt, maxTokens: maxTokens,
                jsonMode: jsonMode, enableWebSearch: enableWebSearch, temperature: temperature
            )
        }
    }

    private static func completeOnProvider(
        settings: AppSettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        jsonMode: Bool,
        enableWebSearch: Bool,
        temperature: Double?
    ) async throws -> String {
        var ai = settings.ai
        if let temperature { ai.mlxTemperature = temperature }
        switch ai.provider {
        case "none":
            throw NativeAIError.unavailable("AI features are disabled in Settings.")
        case "foundation-models":
            return try await completeWithFoundationModels(instructions: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature)
        case "openai", "xai", "openrouter", "custom":
            return try await completeOpenAICompatible(settings: ai, instructions: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature)
        case "chatgpt-subscription":
            return try await NativeChatGPT.complete(settings: ai, instructions: instructions, prompt: prompt)
        case "anthropic", "claude-subscription":
            if enableWebSearch {
                return try await completeAnthropicWithTools(settings: ai, instructions: instructions, prompt: prompt, maxTokens: maxTokens).text
            }
            return try await completeAnthropic(settings: ai, instructions: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature)
        case "mlx":
            return try await NativeMLX.complete(
                settings: ai,
                instructions: instructions,
                prompt: prompt,
                maxTokens: maxTokens,
                jsonMode: jsonMode
            )
        default:
            throw NativeAIError.unavailable("Provider \(ai.provider) is not available in the native iOS app.")
        }
    }

    /// Like `complete`, but also returns any web-search citations the model
    /// gathered during the tool-use loop (empty for providers/paths that
    /// don't support tools). Used by the chat surfaces that render source
    /// chips; other `complete` callers don't need citations and keep using
    /// the plain String-returning overload above.
    static func completeWithCitations(
        settings: AppSettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        enableWebSearch: Bool = false,
        urlSession: URLSession = .shared,
        messages: [[String: String]]? = nil
    ) async throws -> (text: String, citations: [WebCitation]) {
        try await OfflineAIFallback.run(settings) { settings in
            try await completeWithCitationsOnProvider(
                settings: settings, instructions: instructions, prompt: prompt, maxTokens: maxTokens,
                enableWebSearch: enableWebSearch, urlSession: urlSession, messages: messages
            )
        }
    }

    private static func completeWithCitationsOnProvider(
        settings: AppSettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        enableWebSearch: Bool,
        urlSession: URLSession,
        messages: [[String: String]]?
    ) async throws -> (text: String, citations: [WebCitation]) {
        let ai = settings.ai
        if let messages {
            let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? instructions
            let turns = messages.filter { $0["role"] != "system" }.map { message -> [String: Any] in
                ["role": message["role"] ?? "user", "content": message["content"] ?? ""]
            }
            if ["openai", "xai", "openrouter", "custom"].contains(ai.provider) {
                let text = try await completeOpenAICompatible(
                    settings: ai,
                    instructions: system,
                    prompt: prompt,
                    maxTokens: maxTokens,
                    urlSession: urlSession,
                    messages: messages
                )
                return (text, [])
            }
            if ai.provider == "chatgpt-subscription" {
                let text = try await NativeChatGPT.complete(
                    settings: ai,
                    instructions: system,
                    prompt: prompt,
                    messages: messages,
                    urlSession: urlSession
                )
                return (text, [])
            }
            if ["anthropic", "claude-subscription"].contains(ai.provider) {
                if enableWebSearch {
                    return try await completeAnthropicWithTools(
                        settings: ai,
                        instructions: system,
                        prompt: prompt,
                        maxTokens: maxTokens,
                        initialMessages: turns,
                        urlSession: urlSession
                    )
                }
                let text = try await completeAnthropic(
                    settings: ai,
                    instructions: system,
                    prompt: prompt,
                    maxTokens: maxTokens,
                    messages: turns
                )
                return (text, [])
            }
            if ai.provider == "foundation-models" {
                let text = try await completeWithFoundationModels(
                    instructions: system,
                    prompt: prompt,
                    maxTokens: maxTokens,
                    messages: messages.map { LocalChatMessage(role: $0["role"] ?? "user", content: $0["content"] ?? "") }
                )
                return (text, [])
            }
        }
        guard enableWebSearch, ["anthropic", "claude-subscription"].contains(ai.provider) else {
            let text = try await complete(
                settings: settings,
                instructions: instructions,
                prompt: prompt,
                maxTokens: maxTokens,
                enableWebSearch: enableWebSearch
            )
            return (text, [])
        }
        return try await completeAnthropicWithTools(settings: ai, instructions: instructions, prompt: prompt, maxTokens: maxTokens)
    }

    static func completeWithFoundationModels(
        instructions: String,
        prompt: String,
        maxTokens: Int,
        temperature: Double? = nil,
        messages: [LocalChatMessage]? = nil
    ) async throws -> String {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel(useCase: .general)
            if case .unavailable(let reason) = model.availability {
                throw NativeAIError.unavailable(appleIntelligenceUnavailableMessage(reason))
            }

            func attempt(instructions: String) async throws -> String {
                let options = GenerationOptions(
                    sampling: temperature == 0 ? .greedy : .random(top: 50),
                    temperature: temperature ?? 0.7,
                    maximumResponseTokens: maxTokens
                )
                if let messages {
                    let prepared = try FoundationChatMessages.prepare(
                        instructions: instructions,
                        messages: messages,
                        user: prompt
                    )
                    let session = LanguageModelSession(model: model, transcript: prepared.transcript)
                    let response = try await session.respond(to: prepared.prompt, options: options)
                    let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    return stripEchoedPrompt(raw, prompt: prepared.prompt)
                }
                let session = LanguageModelSession(model: model, instructions: instructions)
                let response = try await session.respond(to: prompt, options: options)
                let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return stripEchoedPrompt(raw, prompt: prompt)
            }

            // Retries once with neutralizing instructions when Apple's on-device
            // safety filter refuses ordinary content; see the guardrail-refusal
            // guard above `completeWithFoundationModels`.
            func attemptWithGuardrailRetry() async throws -> String {
                do {
                    return try await attempt(instructions: instructions)
                } catch {
                    guard isGuardrailRefusal(error) else { throw error }
                    print("[NativeAI] Foundation Models refused content (guardrail); retrying once with neutralized instructions.")
                    do {
                        return try await attempt(instructions: instructions + "\n\n" + guardrailNeutralizingInstructions)
                    } catch {
                        guard isGuardrailRefusal(error) else { throw error }
                        throw NativeAIError.unavailable(guardrailRefusalMessage)
                    }
                }
            }

            let first = try await attemptWithGuardrailRetry()
            let (firstTrimmed, firstDegenerate) = degenerateRepetitionTrim(first)
            guard firstDegenerate else { return first }

            print("[NativeAI] Foundation Models output looked degenerate (repetitive); retrying once.")
            let second = try await attemptWithGuardrailRetry()
            let (secondTrimmed, secondDegenerate) = degenerateRepetitionTrim(second)
            guard secondDegenerate else { return second }

            print("[NativeAI] Foundation Models retry was also degenerate; returning the longer trimmed attempt.")
            return firstTrimmed.count >= secondTrimmed.count ? firstTrimmed : secondTrimmed
        }
#endif
        throw NativeAIError.unavailable("Foundation Models are not available in this build.")
    }

    /// Foundation Models occasionally echoes the user prompt back before the actual
    /// response. This strips such an echo when it occurs so callers always receive
    /// clean output.
    ///
    /// Strategy: if the response begins with ≥40 characters that also appear verbatim
    /// at the start of the prompt, or if the response contains the prompt body
    /// followed by a blank line, strip the repeated portion and any leading whitespace.
    private static func stripEchoedPrompt(_ response: String, prompt: String) -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Case 1: response literally starts with the full prompt
        if trimmedResponse.hasPrefix(trimmedPrompt) {
            let afterPrompt = trimmedResponse.dropFirst(trimmedPrompt.count)
            return afterPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Case 2: response starts with a substantial prefix of the prompt (≥40 chars).
        // FM sometimes truncates the echo slightly, so we check a leading window.
        let prefixLength = min(trimmedPrompt.count, 120)
        if prefixLength >= 40 {
            let promptPrefix = String(trimmedPrompt.prefix(prefixLength))
            if trimmedResponse.hasPrefix(promptPrefix) {
                // Find end of the echoed block: scan to the first blank line after the echo
                let lines = trimmedResponse.components(separatedBy: "\n")
                var consuming = true
                var resultLines: [String] = []
                for line in lines {
                    if consuming && trimmedPrompt.contains(line) && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        continue
                    } else {
                        consuming = false
                        resultLines.append(line)
                    }
                }
                let candidate = resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    return candidate
                }
            }
        }

        return trimmedResponse
    }

    // MARK: - Guardrail-refusal guard (Foundation Models only)
    //
    // Apple's on-device safety filter occasionally refuses ordinary tech-news
    // content (a false positive), and without this guard the raw refusal
    // ("Detected content likely to be unsafe") leaks straight into the UI with
    // no actionable next step. We retry once with instructions that clarify the
    // content is journalism being neutrally summarized, and only surface a
    // friendly error if the retry is refused too.

    /// Instructions appended (once) on a guardrail-triggered retry, nudging the
    /// model to treat the input as neutral news summarization rather than
    /// content it should evaluate for safety.
    static let guardrailNeutralizingInstructions =
        "You are summarizing published news journalism for a news-reader app. Report facts neutrally and briefly; omit graphic or sensational detail."

    /// User-facing message shown when Foundation Models refuses content twice
    /// in a row (original attempt + neutralized retry).
    static let guardrailRefusalMessage =
        "Apple's on-device model declined to process this content. Try the Claude provider, or a smaller selection of articles."

    /// Detects a Foundation Models "guardrail" refusal — Apple's on-device
    /// safety filter declining to process content it judged unsafe. On iOS 26+
    /// this pattern-matches the typed `LanguageModelSession.GenerationError
    /// .guardrailViolation` case; as a fallback (and the only path exercised
    /// when FoundationModels isn't available, e.g. in unit tests) it also
    /// matches any error whose `localizedDescription` mentions "unsafe" or
    /// "guardrail", which covers the raw NSError shape Foundation Models
    /// actually surfaces in practice.
    static func isGuardrailRefusal(_ error: Error) -> Bool {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let generationError = error as? LanguageModelSession.GenerationError,
               case .guardrailViolation = generationError {
                return true
            }
        }
#endif
        let description = error.localizedDescription.lowercased()
        return description.contains("unsafe") || description.contains("guardrail")
    }

    // MARK: - Degenerate-output guard (Foundation Models only)
    //
    // Small on-device models occasionally loop: before the sampling fix in
    // skim PR #70, Foundation Models emitted the same sentence dozens of times
    // in a single summary (e.g. "The protest was held in the 21st century.").
    // Stochastic sampling reduces this but doesn't eliminate it, so we detect
    // and trim degenerate repetition defensively before output ever reaches
    // the UI.

    /// A contiguous chunk of text produced by `splitIntoSentenceChunks`, together
    /// with its exact range in the source string so trimming can operate on the
    /// original text (byte-for-byte) rather than a reconstructed approximation.
    private struct SentenceChunk {
        var range: Range<String.Index>
        var text: String
    }

    /// Splits `text` into sentence-ish chunks, breaking after ". ", "! ", "? ",
    /// or a newline. Deliberately simple and dependency-free: this is a heuristic
    /// for repetition detection, not a linguistic sentence tokenizer. The chunks'
    /// ranges are contiguous and cover the whole string, so joining chunk texts
    /// back together reconstructs `text` exactly.
    private static func splitIntoSentenceChunks(_ text: String) -> [SentenceChunk] {
        var chunks: [SentenceChunk] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\n" {
                let end = text.index(after: i)
                chunks.append(SentenceChunk(range: start..<end, text: String(text[start..<end])))
                start = end
                i = end
                continue
            }
            if c == "." || c == "!" || c == "?" {
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == " " {
                    let end = text.index(after: next)
                    chunks.append(SentenceChunk(range: start..<end, text: String(text[start..<end])))
                    start = end
                    i = end
                    continue
                } else if next == text.endIndex {
                    chunks.append(SentenceChunk(range: start..<next, text: String(text[start..<next])))
                    start = next
                    i = next
                    continue
                }
            }
            i = text.index(after: i)
        }
        if start < text.endIndex {
            chunks.append(SentenceChunk(range: start..<text.endIndex, text: String(text[start..<text.endIndex])))
        }
        return chunks
    }

    /// Case/whitespace-insensitive normalization used to compare sentences for
    /// repetition purposes.
    private static func normalizeSentence(_ s: String) -> String {
        let collapsed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    /// Detects a trailing sub-sentence loop: the raw text ends with the same
    /// substring (>= 12 characters) repeated >= 4 times back-to-back, with no
    /// sentence-level delimiters to split on (e.g. a runaway token loop). Returns
    /// the text trimmed to the first occurrence of the repeating unit, or `nil`
    /// if no such loop is found.
    private static func trimTrailingSubstringLoop(_ text: String) -> String? {
        let chars = Array(text)
        let n = chars.count
        guard n >= 48 else { return nil }
        let maxPeriod = min(n / 4, 400)
        guard maxPeriod >= 12 else { return nil }

        for period in 12...maxPeriod {
            let repeatLen = period * 4
            guard repeatLen <= n else { break }
            let tailStart = n - repeatLen
            let unitRange = tailStart..<(tailStart + period)
            let unit = chars[unitRange]
            // Skip near-blank "units" (e.g. runs of spaces/newlines) — not a
            // meaningful loop even if they repeat.
            if unit.allSatisfy({ $0.isWhitespace }) { continue }

            var isRepeating = true
            for k in 1..<4 {
                let segStart = tailStart + k * period
                let seg = chars[segStart..<(segStart + period)]
                if seg != unit {
                    isRepeating = false
                    break
                }
            }
            if isRepeating {
                // Extend backward to find where the loop actually starts, so we
                // trim to exactly one occurrence of the unit rather than the
                // four (or more) reps used to detect it.
                var loopStart = tailStart
                while loopStart - period >= 0 && chars[(loopStart - period)..<loopStart] == unit {
                    loopStart -= period
                }
                let cutIndex = loopStart + period
                return String(chars[0..<cutIndex])
            }
        }
        return nil
    }

    /// Detects and trims degenerate repetitive output from a small on-device
    /// model. Returns the (possibly trimmed) text and whether degeneration was
    /// detected at all.
    ///
    /// Detection rules:
    /// - The same normalized sentence appears >= 3 times consecutively, or
    /// - The final N sentences (N >= 5) contain <= 2 unique normalized sentences, or
    /// - The raw text ends with the same >= 12-character substring repeated
    ///   >= 4 times back-to-back (sub-sentence loop, e.g. no punctuation).
    ///
    /// When degenerate, the output is trimmed to the point where the repetition
    /// run begins, keeping everything before it. If trimming would remove the
    /// entire string, the first occurrence of the repeated content is kept
    /// instead so a non-empty input never yields an empty result.
    static func degenerateRepetitionTrim(_ text: String) -> (text: String, wasDegenerate: Bool) {
        guard !text.isEmpty else { return (text, false) }

        // Sub-sentence loop check first — this catches degenerate output that
        // has no clean sentence delimiters to split on.
        if let trimmed = trimTrailingSubstringLoop(text), !trimmed.isEmpty {
            return (trimmed, true)
        }

        let chunks = splitIntoSentenceChunks(text)
        let nonBlank = chunks.enumerated().compactMap { _, chunk -> SentenceChunk? in
            normalizeSentence(chunk.text).isEmpty ? nil : chunk
        }
        guard nonBlank.count >= 3 else { return (text, false) }
        let normalized = nonBlank.map { normalizeSentence($0.text) }

        var runStart: Int?

        // Rule A: >= 3 consecutive identical normalized sentences.
        var i = 0
        while i < normalized.count {
            var j = i
            while j + 1 < normalized.count && normalized[j + 1] == normalized[i] {
                j += 1
            }
            let runLength = j - i + 1
            if runLength >= 3 {
                runStart = i
                break
            }
            i = j + 1
        }

        // Rule B: the final N sentences (N >= 5) contain <= 2 unique sentences.
        // Search increasing window sizes from 5 so we find the smallest (least
        // destructive) qualifying trim.
        if runStart == nil {
            let n = normalized.count
            if n >= 5 {
                for windowSize in 5...n {
                    let windowStart = n - windowSize
                    let uniqueCount = Set(normalized[windowStart...]).count
                    if uniqueCount <= 2 {
                        runStart = windowStart
                        break
                    }
                }
            }
        }

        guard let start = runStart else { return (text, false) }

        if start == 0 {
            // Nothing precedes the repetition — keep the first occurrence only
            // so we never return an empty string.
            let kept = String(text[text.startIndex..<nonBlank[0].range.upperBound])
            return (kept, true)
        }

        let cutIndex = nonBlank[start].range.lowerBound
        let kept = String(text[text.startIndex..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        if kept.isEmpty {
            let fallback = String(text[text.startIndex..<nonBlank[0].range.upperBound])
            return (fallback, true)
        }
        return (kept, true)
    }

    private static func completeOpenAICompatible(
        settings: AISettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        temperature: Double? = nil,
        urlSession: URLSession = .shared,
        messages: [[String: String]]? = nil
    ) async throws -> String {
        let provider = settings.provider
        let credential = try await openAICompatibleCredential(settings)

        func send(_ token: String?) async throws -> (Data, URLResponse) {
            let request = try buildOpenAICompatibleRequest(
                settings: settings,
                instructions: instructions,
                prompt: prompt,
                maxTokens: maxTokens,
                temperature: temperature ?? 0.2,
                messages: messages,
                bearerToken: token
            )
            return try await urlSession.data(for: request)
        }

        var (data, response) = try await send(credential.token)
        if credential.isSubscription, (response as? HTTPURLResponse)?.statusCode == 401 {
            guard let refreshed = try? await NativeXAIOAuth.refreshStoredTokens() else {
                throw NativeAIError.unavailable("SuperGrok sign-in expired. Sign in again in Settings.")
            }
            (data, response) = try await send(refreshed)
        }
        try validate(response: response, data: data, provider: providerDisplayName(provider))
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content.nilIfEmpty else {
            throw NativeAIError.unavailable("The \(providerDisplayName(provider)) response was empty.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildOpenAICompatibleRequest(
        settings: AISettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        temperature: Double = 0.2,
        messages: [[String: String]]? = nil,
        bearerToken: String? = nil
    ) throws -> URLRequest {
        let provider = settings.provider
        let key = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? bearerToken?.nilIfEmpty
        if provider != "custom", key == nil {
            throw NativeAIError.unavailable("Add an API key for \(providerDisplayName(provider)) in Settings.")
        }
        let body: [String: Any] = [
            "model": settings.model?.nilIfEmpty ?? defaultModel(for: provider),
            "messages": messages ?? [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ],
            "temperature": temperature,
            "max_tokens": maxTokens
        ]
        var request = URLRequest(url: openAICompatibleURL(settings))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if provider == "openrouter" {
            request.setValue("Skim", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func completeAnthropic(settings: AISettings, instructions: String, prompt: String, maxTokens: Int, temperature: Double? = nil, messages: [[String: Any]]? = nil) async throws -> String {
        if settings.provider == "claude-subscription" {
            return try await completeAnthropicSubscription(settings: settings, instructions: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature, messages: messages)
        }
        // API-key path (provider == "anthropic")
        let key = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let key else {
            throw NativeAIError.unavailable("Add a Claude API key in Settings.")
        }
        let request = try buildAnthropicRequest(settings: settings, accessToken: key, isSubscription: false, instructions: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature, messages: messages)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, provider: providerDisplayName(settings.provider))
        return try decodeAnthropicContent(data: data)
    }

    /// Handles the claude-subscription path with Keychain token storage, migration,
    /// and automatic one-shot refresh on 401.
    private static func completeAnthropicSubscription(settings: AISettings, instructions: String, prompt: String, maxTokens: Int, temperature: Double? = nil, messages: [[String: Any]]? = nil) async throws -> String {
        // Resolve the access token: prefer Keychain, fall back to settings.apiKey
        // (legacy location), migrating if found.
        let accessToken: String
        if ClaudeKeychainStore.loadAccessToken() != nil {
            // Proactively refresh if the stored token is expired/near-expiry.
            guard let keychainToken = await NativeClaudeOAuth.validAccessToken() else {
                throw NativeAIError.requiresReauthentication
            }
            accessToken = keychainToken
        } else if let legacyToken = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            // Migrate legacy token from settings database to Keychain.
            ClaudeKeychainStore.migrateIfNeeded(legacyToken: legacyToken)
            accessToken = legacyToken
        } else {
            throw NativeAIError.unavailable("Sign in with Claude in Settings to use your Claude subscription.")
        }

        let request = try buildAnthropicRequest(settings: settings, accessToken: accessToken, isSubscription: true, instructions: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature, messages: messages)
        let (data, response) = try await URLSession.shared.data(for: request)

        // On 401, attempt token refresh and retry once.
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            let newToken: String
            do {
                newToken = try await NativeClaudeOAuth.refreshStoredTokens()
            } catch {
                // Refresh failed — Keychain already cleared inside refreshStoredTokens().
                throw NativeAIError.requiresReauthentication
            }
            let retryRequest = try buildAnthropicRequest(settings: settings, accessToken: newToken, isSubscription: true, instructions: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature, messages: messages)
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            try validate(response: retryResponse, data: retryData, provider: providerDisplayName(settings.provider))
            return try decodeAnthropicContent(data: retryData)
        }

        try validate(response: response, data: data, provider: providerDisplayName(settings.provider))
        return try decodeAnthropicContent(data: data)
    }

    // MARK: - Anthropic request builder (extended)

    /// Full-featured request builder. `messages` is the complete array of chat turns;
    /// `tools` (optional) injects tool definitions. This is the single source of truth
    /// for all Anthropic HTTP requests.
    static func buildAnthropicRequestFull(
        settings: AISettings,
        accessToken: String,
        isSubscription: Bool,
        instructions: String,
        messages: [[String: Any]],
        maxTokens: Int,
        tools: [[String: Any]]? = nil,
        temperature: Double? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if isSubscription {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20,claude-code-20250219", forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue(accessToken, forHTTPHeaderField: "x-api-key")
        }
        let model = resolveAnthropicModel(settings)
        var body: [String: Any] = [
            "model": model,
            "system": anthropicSystem(instructions: instructions, isSubscription: isSubscription),
            "messages": messages,
            "max_tokens": maxTokens
        ]
        if anthropicModelAcceptsTemperature(model) {
            body["temperature"] = temperature ?? 0.2
        }
        if anthropicModelThinksByDefault(model) {
            // 5-series models think before answering unless told otherwise, and the
            // thinking counts against `max_tokens`. At the default effort a long article
            // context could spend a chat's whole budget thinking and return no text
            // ("The Claude response was empty."). Low effort keeps thinking short, and
            // the floor leaves room for the answer after it.
            body["output_config"] = ["effort": "low"]
            body["max_tokens"] = max(maxTokens, anthropicThinkingMaxTokensFloor)
        }
        if let tools {
            body["tools"] = tools
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Identity line a Claude subscription (OAuth) token must open the system prompt with.
    /// Without it, Anthropic answers requests (Haiku 5.5 and Sonnet 5.5 alike) with a 429 `rate_limit_error`
    /// whose message is just "Error", which read as "Claude is rate-limited" to someone with
    /// no limits hit. The desktop app sends the same prefix (`claude_oauth.rs` SYSTEM_PREFIX).
    static let claudeSubscriptionSystemPrefix = "You are Claude Code, Anthropic's official CLI for Claude."

    /// The `system` field: a plain string for API keys; for a subscription token, the
    /// identity line as its own first block followed by the app's instructions.
    static func anthropicSystem(instructions: String, isSubscription: Bool) -> Any {
        guard isSubscription else { return instructions }
        var blocks: [[String: Any]] = [["type": "text", "text": claudeSubscriptionSystemPrefix]]
        if !instructions.isEmpty {
            blocks.append(["type": "text", "text": instructions])
        }
        return blocks
    }

    /// Claude Opus/Sonnet 4.7 and later, and every 5-series model (Sonnet 5.5, Opus 5.5,
    /// Fable, Haiku 5.5…), answer a `temperature` field with a 400. Only send it to the
    /// older models known to take it (Claude 3.x and 4.0–4.6); anything unrecognised gets
    /// the API's default sampling rather than a failed request.
    static func anthropicModelAcceptsTemperature(_ model: String) -> Bool {
        guard let version = anthropicModelVersion(model) else { return false }
        if version.major < 4 { return true }
        return version.major == 4 && version.minor <= 6
    }

    /// Every 5-series model (Sonnet 5.5, Opus 5.5, Haiku 5.5, Fable…) runs adaptive
    /// thinking when the request doesn't mention it, and all of them take
    /// `output_config.effort`. Older models think only when asked, and some (Sonnet 4.5,
    /// Haiku 4.5) reject `effort`, so they get neither.
    static func anthropicModelThinksByDefault(_ model: String) -> Bool {
        guard let version = anthropicModelVersion(model) else { return false }
        return version.major >= 5
    }

    /// Smallest `max_tokens` sent to a model that thinks by default, so thinking can't
    /// use up the whole budget before the answer starts.
    static let anthropicThinkingMaxTokensFloor = 4096

    /// Major/minor version from a Claude model id, or nil for an id that isn't one.
    private static func anthropicModelVersion(_ model: String) -> (major: Int, minor: Int)? {
        var parts = model.lowercased().split(separator: "-").map(String.init)
        guard parts.first == "claude" else { return nil }
        parts.removeFirst()
        // "claude-3-5-sonnet-…" names the version first; "claude-sonnet-4-6" names the family first.
        if let first = parts.first, Int(first) == nil { parts.removeFirst() }
        guard let majorText = parts.first, let major = Int(majorText) else { return nil }
        // A 1–2 digit second part is the minor version; a date snapshot ("4-20250514") is x.0.
        let minor = parts.dropFirst().first.flatMap { $0.count <= 2 ? Int($0) : nil } ?? 0
        return (major, minor)
    }

    /// What to tell the reader when a response carries no text, by `stop_reason`.
    static func anthropicEmptyResponseMessage(stopReason: String?) -> String {
        switch stopReason {
        case "max_tokens":
            return "Claude ran out of room before it wrote an answer. Try again, or ask a narrower question."
        case "refusal":
            return "Claude declined to answer this. Try rephrasing the question."
        default:
            return "The Claude response was empty."
        }
    }

    /// Thin wrapper preserving the original single-message, no-tools signature
    /// used by all non-chat callers (summarize, triage, inbox). Byte-for-byte
    /// equivalent to the old `buildAnthropicRequest`.
    private static func buildAnthropicRequest(settings: AISettings, accessToken: String, isSubscription: Bool, instructions: String, prompt: String, maxTokens: Int, temperature: Double? = nil, messages: [[String: Any]]? = nil) throws -> URLRequest {
        try buildAnthropicRequestFull(
            settings: settings,
            accessToken: accessToken,
            isSubscription: isSubscription,
            instructions: instructions,
            messages: messages ?? [["role": "user", "content": prompt]],
            maxTokens: maxTokens,
            tools: nil,
            temperature: temperature
        )
    }

    private static func decodeAnthropicContent(data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        let content = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n").nilIfEmpty
        guard let content else {
            throw NativeAIError.unavailable(anthropicEmptyResponseMessage(stopReason: decoded.stopReason))
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Anthropic models API (Settings > AI model picker)

    /// Fetches the list of Claude models available to whichever credential
    /// (subscription token or API key) is currently configured, for populating
    /// the Model dropdown in Settings. Mirrors the auth-header selection in
    /// `buildAnthropicRequestFull` — keep the two in sync if that logic changes.
    static func fetchAnthropicModels(settings: AISettings) async throws -> [AIModelInfo] {
        let isSubscription = settings.provider == "claude-subscription"
        let accessToken: String
        if isSubscription {
            if ClaudeKeychainStore.loadAccessToken() != nil {
                guard let keychainToken = await NativeClaudeOAuth.validAccessToken() else {
                    throw NativeAIError.requiresReauthentication
                }
                accessToken = keychainToken
            } else if let legacyToken = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                accessToken = legacyToken
            } else {
                throw NativeAIError.unavailable("Sign in with Claude in Settings to use your Claude subscription.")
            }
        } else {
            guard let key = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                throw NativeAIError.unavailable("Add a Claude API key in Settings.")
            }
            accessToken = key
        }

        let request = buildAnthropicModelsRequest(accessToken: accessToken, isSubscription: isSubscription)
        let (data, response) = try await URLSession.shared.data(for: request)

        if isSubscription, let http = response as? HTTPURLResponse, http.statusCode == 401 {
            let newToken: String
            do {
                newToken = try await NativeClaudeOAuth.refreshStoredTokens()
            } catch {
                throw NativeAIError.requiresReauthentication
            }
            let retryRequest = buildAnthropicModelsRequest(accessToken: newToken, isSubscription: true)
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            try validate(response: retryResponse, data: retryData, provider: providerDisplayName(settings.provider))
            return try parseAnthropicModelsResponse(retryData)
        }

        try validate(response: response, data: data, provider: providerDisplayName(settings.provider))
        return try parseAnthropicModelsResponse(data)
    }

    private static func buildAnthropicModelsRequest(accessToken: String, isSubscription: Bool) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if isSubscription {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20,claude-code-20250219", forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue(accessToken, forHTTPHeaderField: "x-api-key")
        }
        return request
    }

    /// Parses the `{"data": [{"id": ..., "display_name": ...}, ...]}` envelope
    /// returned by Anthropic's `/v1/models` endpoint, preserving API order.
    /// Not private so unit tests can exercise it directly against fixtures.
    static func parseAnthropicModelsResponse(_ data: Data) throws -> [AIModelInfo] {
        try JSONDecoder().decode(AIModelsResponse.self, from: data).data
    }

    /// Fetches the live model list from an OpenAI-compatible `/v1/models`
    /// endpoint (OpenAI, xAI). Both return `{"data": [{"id": ...}, ...]}` with
    /// no display name, so the id doubles as the label.
    ///
    /// Results are sorted by id: OpenAI in particular returns dozens of models
    /// in no meaningful order, and an alphabetical list is at least predictable
    /// to scan.
    static func fetchOpenAICompatibleModels(settings: AISettings) async throws -> [AIModelInfo] {
        let credential = try await openAICompatibleCredential(settings)

        func send(_ token: String?) async throws -> (Data, URLResponse) {
            var request = URLRequest(url: modelsURL(for: settings))
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            return try await URLSession.shared.data(for: request)
        }

        var (data, response) = try await send(credential.token)
        if credential.isSubscription, (response as? HTTPURLResponse)?.statusCode == 401,
           let refreshed = try? await NativeXAIOAuth.refreshStoredTokens() {
            (data, response) = try await send(refreshed)
        }
        try validate(response: response, data: data, provider: providerDisplayName(settings.provider))
        return try parseOpenAICompatibleModelsResponse(data)
    }

    /// The bearer token for an OpenAI-compatible provider: the entered API key,
    /// else (Grok only) the SuperGrok sign-in, matching desktop where an API key
    /// takes priority. `custom` may run keyless against a local endpoint.
    private static func openAICompatibleCredential(_ settings: AISettings) async throws -> (token: String?, isSubscription: Bool) {
        if let key = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return (key, false)
        }
        if settings.provider == "xai", let token = await NativeXAIOAuth.validAccessToken() {
            return (token, true)
        }
        if settings.provider == "custom" {
            return (nil, false)
        }
        if settings.provider == "xai" {
            throw NativeAIError.unavailable("Sign in with SuperGrok or add an xAI API key in Settings.")
        }
        throw NativeAIError.unavailable("Add an API key for \(providerDisplayName(settings.provider)) in Settings.")
    }

    /// Keeps the provider's own order (Giulio, 2026-10-15), dropping repeats and
    /// models that can't answer chat, such as xAI's grok-imagine-* image/video ones.
    static func parseOpenAICompatibleModelsResponse(_ data: Data) throws -> [AIModelInfo] {
        var seen = Set<String>()
        return try JSONDecoder().decode(AIModelsResponse.self, from: data).data
            .filter { isChatModel($0.id) && seen.insert($0.id).inserted }
    }

    /// Id words that mark a model as image, video, audio, embedding or moderation
    /// rather than text chat. `/models` lists carry no modality, so the id is all
    /// we have. Mirrors `is_chat_model` in the desktop app.
    private static let nonChatModelWords: Set<String> = [
        "imagine", "image", "video", "embed", "embedding", "tts", "whisper", "dall", "moderation",
        "transcribe", "sora", "realtime", "audio", "speech", "imagen", "banana", "veo", "lyria",
    ]

    static func isChatModel(_ id: String) -> Bool {
        !id.lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .contains { nonChatModelWords.contains(String($0)) }
    }

    /// Derives the `/v1/models` URL from the same base the completion path uses,
    /// so a custom endpoint keeps working.
    private static func modelsURL(for settings: AISettings) -> URL {
        let completions = openAICompatibleURL(settings).absoluteString
        guard let range = completions.range(of: "/chat/completions", options: .backwards) else {
            return URL(string: "https://api.openai.com/v1/models")!
        }
        return URL(string: completions.replacingCharacters(in: range, with: "/models"))
            ?? URL(string: "https://api.openai.com/v1/models")!
    }

    // MARK: - web_search tool definition

    private static var webSearchToolDefinition: [String: Any] {
        [
            "name": "web_search",
            "description": "Search the public web (DuckDuckGo) for fresh information not present in the user's article context. Returns up to `max_results` title/url/snippet tuples. Call this when the provided articles don't cover the user's question.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Search query."
                    ],
                    "max_results": [
                        "type": "integer",
                        "description": "Max results to return (1-10). Defaults to 5.",
                        "minimum": 1,
                        "maximum": 10
                    ]
                ],
                "required": ["query"]
            ] as [String: Any]
        ]
    }

    // MARK: - Anthropic tool-use loop

    /// Chat completion with web_search tool support. Handles both api-key and
    /// subscription providers. Loops up to 3 tool iterations then returns.
    static func completeAnthropicWithTools(
        settings: AISettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        initialMessages: [[String: Any]]? = nil,
        urlSession: URLSession = .shared,
        accessTokenOverride: String? = nil,
        refreshAccessToken: (@Sendable () async throws -> String)? = nil
    ) async throws -> (text: String, citations: [WebCitation]) {
        let isSubscription = settings.provider == "claude-subscription"

        // Resolve access token (mirrors completeAnthropic / completeAnthropicSubscription)
        let accessToken: String
        if let accessTokenOverride {
            accessToken = accessTokenOverride
        } else if isSubscription {
            if ClaudeKeychainStore.loadAccessToken() != nil {
                // Proactively refresh if the stored token is expired/near-expiry.
                guard let keychainToken = await NativeClaudeOAuth.validAccessToken() else {
                    throw NativeAIError.requiresReauthentication
                }
                accessToken = keychainToken
            } else if let legacyToken = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                ClaudeKeychainStore.migrateIfNeeded(legacyToken: legacyToken)
                accessToken = legacyToken
            } else {
                throw NativeAIError.unavailable("Sign in with Claude in Settings to use your Claude subscription.")
            }
        } else {
            guard let key = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                throw NativeAIError.unavailable("Add a Claude API key in Settings.")
            }
            accessToken = key
        }

        let tools: [[String: Any]] = [webSearchToolDefinition]
        var messages: [[String: Any]] = initialMessages ?? [["role": "user", "content": prompt]]

        let maxIterations = 3
        var currentToken = accessToken

        // Web-search citations gathered across tool iterations, deduped by
        // URL (mirrors the Rust reference's `!citations.iter().any(|c| c.url == r.url)`).
        var citations: [WebCitation] = []
        var seenCitationURLs: Set<String> = []

        for iteration in 0...maxIterations {
            let request = try buildAnthropicRequestFull(
                settings: settings,
                accessToken: currentToken,
                isSubscription: isSubscription,
                instructions: instructions,
                messages: messages,
                maxTokens: maxTokens,
                tools: tools
            )

            // Execute the request, handling subscription 401 refresh once per iteration.
            var data: Data
            var response: URLResponse
            (data, response) = try await urlSession.data(for: request)

            if isSubscription, let http = response as? HTTPURLResponse, http.statusCode == 401 {
                let newToken: String
                do {
                    if let refreshAccessToken {
                        newToken = try await refreshAccessToken()
                    } else {
                        newToken = try await NativeClaudeOAuth.refreshStoredTokens()
                    }
                } catch {
                    throw NativeAIError.requiresReauthentication
                }
                currentToken = newToken
                let retryRequest = try buildAnthropicRequestFull(
                    settings: settings,
                    accessToken: newToken,
                    isSubscription: isSubscription,
                    instructions: instructions,
                    messages: messages,
                    maxTokens: maxTokens,
                    tools: tools
                )
                (data, response) = try await urlSession.data(for: retryRequest)
            }

            try validate(response: response, data: data, provider: providerDisplayName(settings.provider))

            let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            let textBlocks = decoded.content.filter { $0.type == "text" }
            let toolUseBlocks = decoded.content.filter { $0.type == "tool_use" }

            let joinedText = textBlocks.compactMap(\.text).joined(separator: "\n")

            // No tool calls → done.
            if toolUseBlocks.isEmpty {
                let trimmed = joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw NativeAIError.unavailable(anthropicEmptyResponseMessage(stopReason: decoded.stopReason))
                }
                return (trimmed, citations)
            }

            if iteration == maxIterations {
                // Hit iteration cap; return whatever text we have.
                let trimmed = joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
                return (trimmed.isEmpty ? "(No response)" : trimmed, citations)
            }

            // --- Build assistant turn ---
            // Replay the response's blocks unchanged: a model that thinks puts `thinking`
            // blocks before its tool calls, and the next request has to carry them back.
            // Rebuilding the turn from text + tool_use alone dropped them.
            var assistantContentBlocks: [[String: Any]] = []
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawBlocks = raw["content"] as? [[String: Any]], !rawBlocks.isEmpty {
                assistantContentBlocks = rawBlocks
            } else {
                if !joinedText.isEmpty {
                    assistantContentBlocks.append(["type": "text", "text": joinedText])
                }
                for block in toolUseBlocks {
                    var tb: [String: Any] = ["type": "tool_use"]
                    if let id = block.id   { tb["id"]    = id }
                    if let name = block.name { tb["name"] = name }
                    if let input = block.input {
                        tb["input"] = input.mapValues { $0.foundationObject }
                    } else {
                        tb["input"] = [String: Any]()
                    }
                    assistantContentBlocks.append(tb)
                }
            }
            // --- Execute each tool call ---
            var resultBlocks: [[String: Any]] = []
            for block in toolUseBlocks {
                let toolUseID = block.id ?? ""
                let toolName  = block.name ?? ""
                let input     = block.input ?? [:]

                if toolName == "web_search" {
                    let query = input["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let maxResults = input["max_results"]?.intValue.map { max(1, min(10, $0)) } ?? 5

                    if query.isEmpty {
                        resultBlocks.append([
                            "type": "tool_result",
                            "tool_use_id": toolUseID,
                            "is_error": true,
                            "content": "web_search called with empty query"
                        ])
                        continue
                    }

                    do {
                        let results = try await NativeWebSearch.run(query: query, maxResults: maxResults)
                        if results.isEmpty {
                            resultBlocks.append([
                                "type": "tool_result",
                                "tool_use_id": toolUseID,
                                "is_error": true,
                                "content": "web_search returned no results for: \(query)"
                            ])
                        } else {
                            // Capture citations for the UI, deduped by URL across iterations, and
                            // number each result by its place there so [wN] names the N-th card.
                            var lines: [String] = []
                            for r in results {
                                if seenCitationURLs.insert(r.url).inserted {
                                    citations.append(WebCitation(title: r.title, url: r.url, snippet: r.snippet, query: query))
                                }
                                let number = (citations.firstIndex { $0.url == r.url } ?? 0) + 1
                                lines.append("[w\(number)] \(r.title) (\(r.url))\n    \(r.snippet)")
                            }
                            let payloadString = "Results for \u{201C}\(query)\u{201D} (cite one you use as [wN]):\n" + lines.joined(separator: "\n")
                            resultBlocks.append([
                                "type": "tool_result",
                                "tool_use_id": toolUseID,
                                "content": payloadString
                            ])
                        }
                    } catch {
                        resultBlocks.append([
                            "type": "tool_result",
                            "tool_use_id": toolUseID,
                            "is_error": true,
                            "content": "web_search failed: \(error.localizedDescription)"
                        ])
                    }
                } else {
                    resultBlocks.append([
                        "type": "tool_result",
                        "tool_use_id": toolUseID,
                        "is_error": true,
                        "content": "Unknown tool: \(toolName)"
                    ])
                }
            }
            appendAnthropicToolContinuation(
                to: &messages,
                assistantContent: assistantContentBlocks,
                resultContent: resultBlocks
            )
        }

        // Should never reach here due to loop structure, but satisfy the compiler.
        throw NativeAIError.unavailable("Tool-use loop exited without a final response.")
    }

    static func appendAnthropicToolContinuation(
        to messages: inout [[String: Any]],
        assistantContent: [[String: Any]],
        resultContent: [[String: Any]]
    ) {
        messages.append(["role": "assistant", "content": assistantContent])
        messages.append(["role": "user", "content": resultContent])
    }

    private static func openAICompatibleURL(_ settings: AISettings) -> URL {
        let base: String
        switch settings.provider {
        case "openai":
            base = "https://api.openai.com"
        case "xai":
            base = "https://api.x.ai"
        case "openrouter":
            base = "https://openrouter.ai/api"
        default:
            base = settings.endpoint?.nilIfEmpty ?? "https://api.openai.com"
        }

        if base.contains("/chat/completions") {
            return URL(string: base)!
        }
        return URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/chat/completions")!
    }

    private static func validate(response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let rawBody = String(data: data, encoding: .utf8) ?? "No response body."
            // Never surface the raw error body in the UI (raw JSON reads as broken and
            // would look bad in App Store review) — log the full body for debugging and
            // throw a friendly, actionable message instead.
            print("[NativeAI] \(provider) request failed (\(status)): \(rawBody.prefix(2000))")
            let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
            throw NativeAIError.unavailable(friendlyErrorMessage(status: status, data: data, provider: provider, retryAfter: retryAfter))
        }
    }

    /// Builds a friendly, actionable user-facing message for a failed AI provider request.
    /// Parses the `{"error": {"type": ..., "message": ...}}` envelope used by both the
    /// Anthropic API and OpenAI-compatible providers when possible, but always falls back
    /// to a generic message — raw JSON error bodies must never reach the UI.
    static func friendlyErrorMessage(status: Int, data: Data, provider: String, retryAfter: String? = nil) -> String {
        let isClaude = provider.hasPrefix("Claude")
        let errorType = parsedErrorType(from: data)
        let errorMessage = parsedErrorMessage(from: data)

        switch status {
        case 401:
            return isClaude
                ? "Claude sign-in expired. Sign in again in Settings."
                : "\(provider) sign-in expired. Check your API key in Settings."
        case 402, 403:
            return isClaude
                ? "Your Claude plan doesn't allow this request."
                : "Your \(provider) plan doesn't allow this request."
        case 429:
            // A real rate limit carries a `retry-after` header or says what was exceeded. A
            // bare 429 "Error" is Claude refusing the request itself (e.g. a subscription
            // request it doesn't accept), so don't tell someone with no limits to wait.
            let detail = errorMessage.flatMap { isInformativeErrorDetail($0) ? $0 : nil }
            let wait = retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if detail == nil, wait == nil {
                return isClaude
                    ? "Claude turned down this request without saying why (429). Try another model, or sign in to Claude again in Settings."
                    : "\(provider) turned down this request without saying why (429). Try another model, or check your account in Settings."
            }
            let name = isClaude ? "Claude" : provider
            // If the provider included a specific, human-readable detail (e.g. a
            // subscription usage limit reset time), surface it — but never the raw
            // JSON envelope, and never a non-descriptive placeholder like "Error".
            if let detail {
                return "\(name) is rate-limited right now. Wait a bit and try again. (\(detail))"
            }
            if let wait, wait > 0 {
                let minutes = (wait + 59) / 60
                return "\(name) is rate-limited right now. Try again in \(minutes == 1 ? "a minute" : "\(minutes) minutes")."
            }
            return "\(name) is rate-limited right now. Wait a bit and try again."
        case 500...599:
            return isClaude
                ? "Claude is temporarily unavailable. Try again shortly."
                : "\(provider) is temporarily unavailable. Try again shortly."
        default:
            if errorType == "overloaded_error" {
                return isClaude
                    ? "Claude is temporarily unavailable. Try again shortly."
                    : "\(provider) is temporarily unavailable. Try again shortly."
            }
            // A 400 is the provider rejecting this request, and its message says why (an
            // unsupported parameter, a prompt that is too long, an unknown model). Show that
            // reason, not a bare status code that leaves "Try again" as the only advice.
            if let detail = errorMessage, isInformativeErrorDetail(detail) {
                let reason = detail.count > 240 ? String(detail.prefix(240)) + "…" : detail
                return isClaude
                    ? "Claude couldn't run this request: \(reason)"
                    : "\(provider) couldn't run this request: \(reason)"
            }
            return isClaude
                ? "Claude request failed (\(status)). Try again."
                : "\(provider) request failed (\(status)). Try again."
        }
    }

    /// One sentence a reader can act on for any AI failure, whichever provider
    /// raised it. Provider HTTP failures already carry a friendly message
    /// (`friendlyErrorMessage`); this covers the rest, above all Apple's
    /// on-device model, whose errors are enums and NSErrors with no
    /// `errorDescription` — printing those put a raw dump on the page
    /// ("The operation couldn't be completed. (FoundationModels…error 2.)").
    static func userFacingMessage(_ error: Error) -> String {
        if let aiError = error as? NativeAIError {
            switch aiError {
            case .unavailable(let message) where isPresentableErrorText(message): return message
            case .unavailable: break
            case .requiresReauthentication: return "Your Claude session expired. Sign in again."
            }
        }
        if isGuardrailRefusal(error) { return guardrailRefusalMessage }
#if canImport(FoundationModels)
        if #available(iOS 26.0, *), let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize:
                return "That was too much text for Apple's on-device model. Try fewer articles, or pick Claude in AI Settings."
            case .assetsUnavailable:
                return "Apple Intelligence is still downloading its model. Keep this device on Wi-Fi and charging, then try again."
            case .rateLimited:
                return "Apple's on-device model is busy. Try again in a moment."
            case .unsupportedLanguageOrLocale:
                return "Apple's on-device model doesn't support this language. Pick Claude in AI Settings."
            case .decodingFailure, .unsupportedGuide:
                return "Apple's on-device model returned an answer Skim couldn't read. Try again, or pick Claude in AI Settings."
            case .concurrentRequests:
                return "Another AI request is still running. Try again in a moment."
            default:
                return "Apple's on-device model couldn't finish this. Try again, or pick Claude in AI Settings."
            }
        }
#endif
        if let localized = (error as? LocalizedError)?.errorDescription, isPresentableErrorText(localized) {
            return localized
        }
        if error is CancellationError { return "The request was cancelled." }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorNotConnectedToInternet || nsError.code == NSURLErrorNetworkConnectionLost
                ? "No internet connection. Try again once you're back online."
                : "Couldn't reach the AI provider. Check your connection and try again."
        }
        if isPresentableErrorText(nsError.localizedDescription) { return nsError.localizedDescription }
        print("[NativeAI] Unmapped error surfaced to the UI: \(error)")
        return "The AI request failed. Try again, or pick another model in AI Settings."
    }

    /// Whether an error string reads as a sentence rather than a debug dump.
    /// Rejects Swift's placeholder for an error with no description, NSError
    /// dumps, and anything with raw enum or JSON punctuation in it.
    static func isPresentableErrorText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else { return false }
        let lowered = trimmed.lowercased()
        let dumpMarkers = [
            "the operation couldn’t be completed", "the operation couldn't be completed",
            "error domain=", "userinfo=", "nserror", "debugdescription",
            "foundationmodels", "languagemodelsession",
        ]
        if dumpMarkers.contains(where: lowered.contains) { return false }
        // `"\(error)"` on an enum case with a payload, e.g. `unavailable("…")`.
        return !(trimmed.contains("(") && trimmed.hasSuffix(")") && !trimmed.contains(" "))
    }

    /// Parses the `error` object out of a provider error body, e.g.
    /// `{"type":"error","error":{"type":"rate_limit_error","message":"..."}}` (Anthropic)
    /// or `{"error":{"message":"...","type":"...","code":"..."}}` (OpenAI-compatible).
    private static func parsedErrorEnvelope(from data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["error"] as? [String: Any]
    }

    private static func parsedErrorType(from data: Data) -> String? {
        parsedErrorEnvelope(from: data)?["type"] as? String
    }

    private static func parsedErrorMessage(from data: Data) -> String? {
        parsedErrorEnvelope(from: data)?["message"] as? String
    }

    /// Filters out placeholder/non-descriptive error messages (e.g. Anthropic's generic
    /// `"Error"`) so we don't surface something that reads as broken or unhelpful.
    private static func isInformativeErrorDetail(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 10 && trimmed.lowercased() != "error"
    }

    /// The old default Claude model id (pre-PR #73). A stored `ai.model` that matches this
    /// exactly (rather than some other "claude*" id) means the user never customized the
    /// field — it was auto-filled by the old default and should be migrated forward one time.
    private static let legacyDefaultAnthropicModel = "claude-sonnet-4-5"

    /// Returns the correct Anthropic model id, guarding against a leaked MLX repo id
    /// (e.g. "mlx-community/gemma-3-1b-it-4bit") that the shared `ai.model` field may
    /// contain when the user previously used local inference and then signed into Claude.
    /// Also migrates a stored model id that exactly matches the pre-PR #73 default
    /// ("claude-sonnet-4-5") forward to the current default, since that value means the
    /// user never customized it — a hand-typed "claude-sonnet-4-5" is indistinguishable
    /// from the old auto-fill, but treating it as unmigrated would leave signed-in users
    /// stuck on a stale default forever.
    private static func resolveAnthropicModel(_ settings: AISettings) -> String {
        let m = settings.model?.nilIfEmpty
        if let m, m == legacyDefaultAnthropicModel { return defaultModel(for: settings.provider) }
        if let m, m.hasPrefix("claude") { return m }
        return defaultModel(for: settings.provider)
    }

    private static func defaultModel(for provider: String) -> String {
        switch provider {
        case "anthropic", "claude-subscription":
            return "claude-sonnet-5"
        case "xai":
            return "grok-4.3"
        case "openrouter":
            return "openai/gpt-4o-mini"
        default:
            return "gpt-4o-mini"
        }
    }

    private static func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "openai": "OpenAI"
        case "xai": "Grok"
        case "openrouter": "OpenRouter"
        case "anthropic": "Claude API"
        case "claude-subscription": "Claude subscription"
        case "chatgpt-subscription": "ChatGPT"
        case "custom": "Custom provider"
        default: provider
        }
    }

    private static func summaryInstructions(_ settings: AISettings, wordCount: Int? = nil) -> String {
        AIRequestPolicy.summaryInstructions(settings, wordCount: wordCount)
    }

    private static func summaryTargetWordCount(_ settings: AISettings) -> Int {
        AIRequestPolicy.summaryWordCount(settings)
    }

    private static func articleDigest(_ articles: [Article], limit: Int, wordsPerArticle: Int = 95, budget: CatchUpDigestBudget? = nil) -> String {
        let selected = articles.prefix(limit)
        if selected.isEmpty {
            return "No articles are available."
        }

        let entries: [String] = selected.enumerated().map { index, article in
            let text = article.plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = text.isEmpty ? "No reader text available." : text.prefixWords(budget?.wordsPerArticle ?? wordsPerArticle)
            return """
            [\(index + 1)] \(article.title)
            Feed: \(article.feedTitle)
            Author: \(article.author ?? "unknown")
            Excerpt: \(excerpt)
            """
        }
        return fitted(entries, budget: budget)
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func reasonDescription(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "this device is not eligible"
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is not enabled"
        case .modelNotReady:
            "the language model is not ready"
        @unknown default:
            "unknown reason"
        }
    }

    /// Why Apple Intelligence cannot run, said with what to do about it.
    @available(iOS 26.0, *)
    static func appleIntelligenceUnavailableMessage(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "Apple Intelligence doesn't run on this device. Pick another model in AI Settings."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off. Turn it on in the Settings app under Apple Intelligence & Siri."
        case .modelNotReady:
            "Apple Intelligence is still downloading its model. Keep this device on Wi-Fi and charging, then try again."
        @unknown default:
            "Apple Intelligence isn't available right now. Try again later or pick another model in AI Settings."
        }
    }

    // MARK: - @Generable triage types (Foundation Models guided generation)
    //
    // These types are used with `session.respond(to:generating:)` to produce
    // schema-constrained output, eliminating JSON parsing errors entirely.
    // Only used when the provider is "foundation-models" on iOS 26+.

    /// Guided-generation output for one AI Inbox rating.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct FMInboxRating {
        @Guide(description: "1-based index of the article in the provided list")
        var articleIndex: Int
        @Guide(description: "Impact of the thing at the center of the article, in any field, 1 (noise) to 5 (changes a whole field)", .range(1...5))
        var importance: Int
        @Guide(description: "Fit with this reader's interests, 1 (outside them) to 5 (squarely in them); 3 when unknown", .range(1...5))
        var relevance: Int
        @Guide(description: "Under 80 characters: what the article is and why it matters or is noise")
        var reason: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct FMInboxRatings {
        @Guide(description: "One rating for every article in the list")
        var ratings: [FMInboxRating]
    }

    /// Guided-generation output for auto-group.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct FMAutoGroupFolder {
        @Guide(description: "Short folder name, 2 to 4 words")
        var name: String
        /// Zero-based numeric handles matching the feed listing.
        @Guide(description: "Zero-based numeric handles of feeds belonging to this folder")
        var feedIndices: [Int]
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct FMAutoGroupProposal {
        @Guide(description: "4 to 8 topical folders, each feed in exactly one folder")
        var folders: [FMAutoGroupFolder]
    }

    /// Guided-generation output for structured catch-up.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct FMCatchUpEntry {
        @Guide(description: "Short headline, 10 words or fewer")
        var title: String
        @Guide(description: "1 to 2 sentence plain-text summary")
        var summary: String
        /// 1-based index, or -1 when the item spans multiple articles.
        @Guide(description: "1-based article index, or -1 when the item covers multiple articles")
        var articleIndex: Int
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct FMCatchUpStructured {
        @Guide(description: "5 to 12 items covering the most important stories")
        var items: [FMCatchUpEntry]
    }

    // MARK: - FM guided-generation triage methods

    /// Foundation Models guided generation for AI Inbox ratings.
    @available(iOS 26.0, macOS 26.0, *)
    static func inboxRatingsFM(articles: [Article], digest: String, readerContext: String) async throws -> [Int: InboxRating] {
        let model = SystemLanguageModel(useCase: .general)
        if case .unavailable(let reason) = model.availability {
            throw NativeAIError.unavailable(appleIntelligenceUnavailableMessage(reason))
        }
        let baseInstructions = InboxRanking.triagePrompt

        func attempt(instructions: String) async throws -> [Int: InboxRating] {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: """
                \(readerContext)

                Rate every one of these \(articles.count) articles.

                \(digest)
                """,
                generating: FMInboxRatings.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: articles.count * 45 + 200)
            )
            var out: [Int: InboxRating] = [:]
            for entry in response.content.ratings where articles.indices.contains(entry.articleIndex - 1) {
                out[entry.articleIndex] = InboxRating(
                    importance: min(5, max(1, entry.importance)),
                    relevance: min(5, max(1, entry.relevance)),
                    reason: entry.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            guard !out.isEmpty else {
                throw NativeAIError.unavailable("Foundation Models returned no ratings.")
            }
            return out
        }

        // Retries once with neutralizing instructions when Apple's on-device
        // safety filter refuses ordinary content; see the guardrail-refusal
        // guard near `completeWithFoundationModels`.
        do {
            return try await attempt(instructions: baseInstructions)
        } catch {
            guard isGuardrailRefusal(error) else { throw error }
            print("[NativeAI] AI Inbox (Foundation Models) refused content (guardrail); retrying once with neutralized instructions.")
            do {
                return try await attempt(instructions: baseInstructions + "\n\n" + guardrailNeutralizingInstructions)
            } catch {
                guard isGuardrailRefusal(error) else { throw error }
                throw NativeAIError.unavailable(guardrailRefusalMessage)
            }
        }
    }

    /// Uses Foundation Models guided generation for structured catch-up items.
    /// Bypasses `repairTriageJSON` — guided generation guarantees valid output.
    @available(iOS 26.0, macOS 26.0, *)
    static func quickCatchUpStructuredFM(articles: [Article]) async throws -> [CatchUpItem] {
        let model = SystemLanguageModel(useCase: .general)
        if case .unavailable(let reason) = model.availability {
            throw NativeAIError.unavailable(appleIntelligenceUnavailableMessage(reason))
        }

        let baseInstructions = "You write crisp catch-up summaries for a news/RSS reader."

        func attempt(instructions: String) async throws -> [CatchUpItem] {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: """
                Create a Quick Catch-up from these articles. Cover the 5–12 most important stories.

                \(articleDigest(articles, limit: catchUpArticleLimit))
                """,
                generating: FMCatchUpStructured.self,
                options: GenerationOptions(sampling: .random(top: 50), temperature: 0.7, maximumResponseTokens: 1200)
            )
            let structured = response.content
            return structured.items.map { entry in
                CatchUpItem(
                    title: entry.title,
                    summary: entry.summary,
                    // Convert sentinel -1 back to nil (no specific article)
                    articleIndex: entry.articleIndex < 1 ? nil : entry.articleIndex
                )
            }
        }

        // Retries once with neutralizing instructions when Apple's on-device
        // safety filter refuses ordinary content; see the guardrail-refusal
        // guard near `completeWithFoundationModels`.
        func attemptWithGuardrailRetry() async throws -> [CatchUpItem] {
            do {
                return try await attempt(instructions: baseInstructions)
            } catch {
                guard isGuardrailRefusal(error) else { throw error }
                print("[NativeAI] Quick catch-up (Foundation Models) refused content (guardrail); retrying once with neutralized instructions.")
                do {
                    return try await attempt(instructions: baseInstructions + "\n\n" + guardrailNeutralizingInstructions)
                } catch {
                    guard isGuardrailRefusal(error) else { throw error }
                    throw NativeAIError.unavailable(guardrailRefusalMessage)
                }
            }
        }

        // The degenerate-repetition guard operates on text, but this path
        // returns structured items. Build a text digest of the items purely
        // for detection, and if a retry is also degenerate, fall back to
        // deduping consecutive near-identical items rather than trimming text.
        func digestText(_ items: [CatchUpItem]) -> String {
            items.map { "\($0.title). \($0.summary)" }.joined(separator: "\n")
        }
        func dedupeConsecutive(_ items: [CatchUpItem]) -> [CatchUpItem] {
            var result: [CatchUpItem] = []
            var lastNormalized: String?
            for item in items {
                let normalized = normalizeSentence(item.title + " " + item.summary)
                if normalized == lastNormalized {
                    continue
                }
                result.append(item)
                lastNormalized = normalized
            }
            return result.isEmpty ? items : result
        }

        let first = try await attemptWithGuardrailRetry()
        let (_, firstDegenerate) = degenerateRepetitionTrim(digestText(first))
        guard firstDegenerate else { return first }

        print("[NativeAI] Quick catch-up (Foundation Models) output looked degenerate; retrying once.")
        let second = try await attemptWithGuardrailRetry()
        let (_, secondDegenerate) = degenerateRepetitionTrim(digestText(second))
        guard secondDegenerate else { return second }

        print("[NativeAI] Quick catch-up retry was also degenerate; returning the best deduped attempt.")
        let firstDeduped = dedupeConsecutive(first)
        let secondDeduped = dedupeConsecutive(second)
        return firstDeduped.count >= secondDeduped.count ? firstDeduped : secondDeduped
    }
#endif
}

enum NativeAIError: LocalizedError {
    case unavailable(String)
    /// The Claude subscription token has expired and the refresh token is invalid.
    /// The user must sign in again.
    case requiresReauthentication

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            message
        case .requiresReauthentication:
            "Claude sign-in expired. Sign in again in Settings."
        }
    }
}

/// What the UI can offer the user to fix a failed AI request.
enum AIErrorRemedy: Equatable {
    case none
    /// Claude subscription token expired; present `ClaudeReauthSheet`.
    case reauthenticate
    /// Provider is missing, disabled, or lacks credentials; open the AI settings.
    case openAISettings

    static func classify(_ error: Error) -> AIErrorRemedy {
        guard let aiError = error as? NativeAIError else { return .none }
        switch aiError {
        case .requiresReauthentication:
            return .reauthenticate
        case .unavailable(let message):
            let needle = message.lowercased()
            let mentionsSettings = needle.contains("in settings")
            let mentionsCredentials = needle.contains("sign in") || needle.contains("api key") || needle.contains("api token")
            return (mentionsSettings || mentionsCredentials) ? .openAISettings : .none
        }
    }
}

private struct OpenAIResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String
        }

        var message: Message
    }

    var choices: [Choice]
}

// MARK: - Anthropic /v1/models response

/// One entry from Anthropic's `/v1/models` list, used to populate the Model
/// dropdown in Settings > AI. Not private so `SettingsSheet` and unit tests
/// can reference it directly.
struct AIModelInfo: Decodable, Equatable, Sendable {
    var id: String
    var displayName: String

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    /// OpenAI-compatible `/v1/models` responses (OpenAI, xAI) carry only an
    /// `id`, so fall back to it when `display_name` is absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.id = id
        self.displayName = (try? container.decode(String.self, forKey: .displayName)) ?? id
    }
}

private struct AIModelsResponse: Decodable {
    var data: [AIModelInfo]
}

// MARK: - JSONValue: lightweight dynamic JSON for tool_use input payloads

private enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self)  { self = .string(s); return }
        if let d = try? container.decode(Double.self)  { self = .number(d); return }
        if let b = try? container.decode(Bool.self)    { self = .bool(b);   return }
        if container.decodeNil()                        { self = .null;      return }
        if let a = try? container.decode([JSONValue].self)         { self = .array(a);  return }
        if let o = try? container.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.typeMismatch(JSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unrecognised JSON value"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d)
        case .bool(let b):   try c.encode(b)
        case .null:          try c.encodeNil()
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // Convenience accessors
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var intValue: Int? {
        if case .number(let d) = self { return Int(d) }
        return nil
    }

    /// Re-serialise this value as a JSON string.
    var jsonString: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "null"
    }

    /// Convert to a plain Foundation object for JSONSerialization.
    var foundationObject: Any {
        switch self {
        case .string(let s):  return s
        case .number(let d):  return d
        case .bool(let b):    return b
        case .null:           return NSNull()
        case .array(let a):   return a.map { $0.foundationObject }
        case .object(let o):  return o.mapValues { $0.foundationObject }
        }
    }
}

private struct AnthropicResponse: Decodable {
    struct ContentBlock: Decodable {
        var type: String?
        var text: String?
        // tool_use fields
        var id: String?
        var name: String?
        var input: [String: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case type, text, id, name, input
        }
    }

    var content: [ContentBlock]
    var stopReason: String?

    private enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}

struct AIResultSheet: View {
    var request: AIResultRequest
    @Environment(\.dismiss) private var dismiss
    @State private var publication: AIPublicationGate?
    @State private var retryTask: Task<Void, Never>?
    @State private var isLoading = true
    @State private var result = ""
    @State private var referencedArticles: [Article] = []
    @State private var errorMessage: String?
    @State private var errorRemedy: AIErrorRemedy = .none
    @State private var showAISettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(request.subtitle)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(SkimStyle.secondary)

                    if isLoading && result.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(SkimStyle.accent)
                            Text(request.statusLabel)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(SkimStyle.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else if let errorMessage {
                        AIErrorBox(message: errorMessage, remedy: errorRemedy, onResolved: { retryTask = Task { await run() } })
                    } else {
                        PrettyAIText(result)

                        if !referencedArticles.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Articles")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(SkimStyle.secondary)
                                    .textCase(.uppercase)
                                    .tracking(1.2)
                                    .padding(.top, 6)

                                ForEach(referencedArticles) { article in
                                    NavigationLink(value: article.id) {
                                        ChatArticleReferenceRow(article: article)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        AIDisclaimerLabel()
                            .padding(.top, 8)
                    }
                }
                .padding(24)
            }
            .background(SkimStyle.chrome.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle(request.title)
            .navigationDestination(for: String.self) { articleID in
                ArticleDetailView(articleID: articleID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            showAISettings = true
                        } label: {
                            Label("AI Settings", systemImage: "gearshape")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .help("AI Settings")
                        if let continueInChat = request.continueInChat, !isLoading, errorMessage == nil {
                            Button {
                                let captured = result
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    continueInChat(captured)
                                }
                            } label: {
                                Label("Chat", systemImage: SkimIcon.chat)
                            }
                        }
                        if let clearAction = request.clearAction {
                            Button("Clear", role: .destructive) {
                                clearAction()
                                dismiss()
                            }
                            .disabled(isLoading)
                        } else {
                            Button {
                                retryTask = Task { await run() }
                            } label: {
                                Label("Run Again", systemImage: SkimIcon.refresh)
                                    .labelStyle(.iconOnly)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .help("Run Again")
                            .disabled(isLoading)
                        }
                    }
                }
            }
            .task { await run() }
            // On the stack, not the toolbar: a sheet inside a ToolbarItem does not present.
            .sheet(isPresented: $showAISettings, onDismiss: {
                if errorMessage != nil { retryTask = Task { await run() } }
            }) {
                SettingsSheet(isPresented: $showAISettings, aiOnly: true)
            }
            .onDisappear {
                publication?.cancel()
                retryTask?.cancel()
            }
        }
    }

    @MainActor
    private func run() async {
        publication?.cancel()
        let current = AIPublicationGate()
        publication = current
        defer { current.cancel() }
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            isLoading = true
            errorMessage = nil
            errorRemedy = .none
            result = ""
            referencedArticles = []
            do {
                let answer: AIResultAnswer
                if let streamAction = request.streamAction {
                    answer = try await streamAction { @MainActor chunk in
                        current.publish { result += chunk }
                    }
                } else {
                    answer = try await request.action()
                }
                try Task.checkCancellation()
                current.publish {
                    result = answer.text
                    referencedArticles = ArticleReferenceExtractor.references(in: answer.text, articles: answer.articles)
                    isLoading = false
                }
            } catch is CancellationError {
                current.cancel()
            } catch {
                guard !Task.isCancelled else { return }
                current.publish {
                    errorMessage = error.localizedDescription
                    errorRemedy = AIErrorRemedy.classify(error)
                    isLoading = false
                }
            }
        } onCancel: { current.cancel() }
    }
}

private struct PrettyAIText: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(formattedText)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(SkimStyle.text)
            .lineSpacing(5)
            .textSelection(.enabled)
    }

    private var formattedText: AttributedString {
        ChatMarkdown.attributed(text)
    }
}

struct AIChatSheet: View {
    var request: AIChatRequest
    @Environment(\.dismiss) private var dismiss
    @Binding private var messages: [AIChatMessage]
    @State private var input = ""
    @State private var quotedText: String?
    @State private var quoteSource: ChatQuoteSource = .answer
    @State private var isSending = false
    /// Questions asked while an answer is in flight; they send in order as each one lands.
    @State private var queued: [QueuedChatMessage] = []
    /// A failed answer holds the queue until the reader resumes it.
    @State private var queuePaused = false
    @State private var editingQueuedID: UUID?
    @State private var queuedDraft = ""
    @FocusState private var queuedEditorFocused: Bool
    /// Deep research: slower, reads the feeds then the web, and writes a cited briefing.
    @State private var deepResearch = false
    /// What the research in flight has done so far.
    @State private var researchSteps: [String] = []
    @State private var showReauth = false
    @State private var showAISettings = false
    /// Articles opened from the chat, so a citation chip can push one like a card does.
    @State private var path: [String] = []
    @FocusState private var focused: Bool
    private var initialAssistantMessage: String?
    private let bottomAnchorID = "chat-bottom-anchor"

    init(request: AIChatRequest, messages: Binding<[AIChatMessage]>, initialAssistantMessage: String? = nil) {
        self.request = request
        _messages = messages
        self.initialAssistantMessage = initialAssistantMessage
    }

    private var hint: some View {
        Group {
            if deepResearch {
                ContentUnavailableView("Research a topic", systemImage: "doc.text.magnifyingglass",
                    description: Text("Skim reads your feeds first, then searches the web for what they leave out, and writes a briefing that cites both."))
            } else {
                ContentUnavailableView("Ask Skim", systemImage: SkimIcon.chat, description: Text(request.placeholder))
            }
        }
        .foregroundStyle(SkimStyle.secondary)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if messages.isEmpty {
                                // Centered in the visible space above the input bar, so the
                                // hint stays in view when the keyboard shrinks the sheet;
                                // starter questions sit below it instead.
                                if request.suggestedPrompts.isEmpty {
                                    hint
                                        .frame(maxWidth: .infinity)
                                        .containerRelativeFrame(.vertical, alignment: .center) { height, _ in
                                            max(height - 36, 0)
                                        }
                                } else {
                                    hint
                                        .padding(.top, 32)
                                    if !isSending && !deepResearch {
                                        ChatStarterPrompts(prompts: request.suggestedPrompts) { prompt in
                                            input = prompt
                                            Task { await send() }
                                        }
                                    }
                                }
                            } else {
                                ForEach(messages) { message in
                                    AIChatBubble(
                                        message: message,
                                        onOpenArticle: { path.append($0) },
                                        onReauth: { showReauth = true },
                                        onOpenSettings: { showAISettings = true },
                                        onReply: { quote in
                                            quotedText = quote
                                            quoteSource = .answer
                                            focusComposer()
                                        }
                                    )
                                        .id(message.id)
                                }
                                AIDisclaimerLabel()
                                    .padding(.top, 4)
                            }

                            if isSending && deepResearch {
                                ResearchProgressList(steps: researchSteps)
                            } else if isSending {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(SkimStyle.accent)
                                    Text("Thinking...")
                                        .foregroundStyle(SkimStyle.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }

                            if !queued.isEmpty {
                                queuedList
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                        }
                        .padding(18)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    // A solid edge under the Close and model buttons, so a
                    // scrolled-up question doesn't run beneath them.
                    .chatHardTopScrollEdge()
                    .simultaneousGesture(TapGesture().onEnded { focused = false })
                    .onChange(of: messages.last?.id) { _, _ in
                        scrollToLatest(proxy)
                    }
                    .onChange(of: isSending) { _, sending in
                        if sending { scrollToLatest(proxy) }
                    }
                    .onChange(of: researchSteps.count) { _, _ in
                        if isSending { scrollToLatest(proxy) }
                    }
                    // Keep a queued question in view above the keyboard while it's edited.
                    .onChange(of: editingQueuedID) { _, id in
                        guard let id else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            withAnimation(.smooth(duration: 0.22)) { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                        guard let id = editingQueuedID else { return }
                        withAnimation(.smooth(duration: 0.22)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: queued.count) { old, new in
                        if new > old {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(80))
                                withAnimation(.smooth(duration: 0.22)) { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
                            }
                        }
                    }
                }

                VStack(spacing: 8) {
                    if let quotedText {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(quoteSource.caption)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(SkimStyle.accent)
                                Text(quotedText)
                                    .font(.system(size: 13))
                                    .foregroundStyle(SkimStyle.secondary)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button {
                                self.quotedText = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(SkimStyle.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove reply quote")
                        }
                        .padding(10)
                        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if request.research != nil {
                        HStack(spacing: 10) {
                            Button {
                                deepResearch.toggle()
                            } label: {
                                Label("Deep research", systemImage: "doc.text.magnifyingglass")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(deepResearch ? Color.white : SkimStyle.secondary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .background(deepResearch ? SkimStyle.accent : SkimStyle.surface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSending)
                            .accessibilityAddTraits(deepResearch ? .isSelected : [])
                            .accessibilityHint("Reads your feeds first, then the web, and writes a cited briefing")
                            if deepResearch {
                                Text("Feeds first, then the web. Takes a minute or two.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(SkimStyle.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    HStack(spacing: 10) {
                        TextField(isSending ? "Queue a follow-up..." : deepResearch ? "Name a topic to research..." : "Ask...", text: $input, axis: .vertical)
                            .focused($focused)
                            .lineLimit(1...4)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(SkimStyle.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                        // Inline rather than on the keyboard bar: iOS 26 floats keyboard
                        // toolbar items over the send button.
                        if focused {
                            Button {
                                focused = false
                            } label: {
                                Image(systemName: "keyboard.chevron.compact.down")
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundStyle(SkimStyle.secondary)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Hide keyboard")
                        }

                        Button {
                            Task { await send() }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? SkimStyle.secondary : SkimStyle.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(isSending ? "Queue message" : "Send")
                        .accessibilityHint(isSending ? "Sends when Skim finishes the current answer" : "")
                    }
                }
                .padding(14)
                .background(SkimStyle.chrome)
            }
            .background(SkimStyle.chrome.ignoresSafeArea())
            .navigationTitle(request.title)
            .navigationDestination(for: String.self) { articleID in
                ArticleDetailView(articleID: articleID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    AppModelPicker(isDisabled: isSending, forChat: true)
                }
            }
            .onAppear {
                seedInitialMessageIfNeeded()
                if let quote = request.initialArticleQuote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
                    quotedText = quote
                    quoteSource = request.initialQuoteSource
                }
                // The keyboard would cover the starter questions, so wait for a tap.
                if !(messages.isEmpty && quotedText == nil && !request.suggestedPrompts.isEmpty) {
                    focusComposer()
                }
            }
            .sheet(isPresented: $showReauth) {
                ClaudeReauthSheet()
            }
            .sheet(isPresented: $showAISettings) {
                SettingsSheet(isPresented: $showAISettings, aiOnly: true)
            }
        }
    }

    /// Puts the cursor in the composer with the keyboard up, so a quoted
    /// passage is ready for a question. The text the passage was selected in
    /// still holds first responder, and a sheet that is still sliding up drops
    /// a focus change, so let go of the selection first and ask again once the
    /// sheet has settled.
    private func focusComposer() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        focused = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            if !focused { focused = true }
        }
    }

    private func seedInitialMessageIfNeeded() {
        guard messages.isEmpty,
              let seed = initialAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !seed.isEmpty
        else { return }
        messages = [AIChatMessage(role: .assistant, text: seed)]
    }

    /// A new answer is scrolled so its first line sits at the top, so the
    /// reader starts at the beginning instead of the end of a long reply.
    /// A question (and the "Thinking..." row) scrolls to the bottom.
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        let answerID = messages.last.flatMap { $0.role == .assistant ? $0.id : nil }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.smooth(duration: 0.22)) {
                if let answerID {
                    proxy.scrollTo(answerID, anchor: .top)
                } else {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    /// Sends the composer, or queues it while an answer is still coming.
    private func send() async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let item = QueuedChatMessage(text: question, quotedText: quotedText, quoteSource: quoteSource)
        input = ""
        quotedText = nil
        focused = true
        if isSending {
            queued.append(item)
            return
        }
        await send(item)
    }

    /// Sends the next queued question once nothing is in flight, unless the
    /// queue is paused or the reader is editing that question.
    private func sendNextQueued() async {
        guard !isSending, !queuePaused, let next = queued.first, next.id != editingQueuedID else { return }
        queued.removeFirst()
        await send(next)
    }

    private func send(_ item: QueuedChatMessage) async {
        guard !isSending else { return }
        queuePaused = false
        let toSend = item.text
        let quoteToSend = item.quotedText
        let sourceToSend = item.quoteSource
        let priorMessages = messages
        let conversation = AIChatConversation(latestQuestion: toSend, quotedText: quoteToSend, quoteSource: sourceToSend, priorMessages: priorMessages, generatedSummaryContext: request.generatedSummaryContext ?? initialAssistantMessage)
        let userMessage = AIChatMessage(role: .user, text: toSend, quotedText: quoteToSend, quoteSource: sourceToSend)
        messages.append(userMessage)
        isSending = true
        researchSteps = []
        do {
            let answer: AIChatAnswer
            if deepResearch, let research = request.research {
                answer = try await research(conversation) { @MainActor step in researchSteps.append(step) }
            } else {
                answer = try await request.answer(conversation)
            }
            // A correction edits the earlier reply it fixes, struck through with the fix beside it.
            let corrections = ChatCorrections.apply(
                to: messages.map { $0.role == .assistant && !$0.isError ? $0.text : nil },
                answer: answer.text
            )
            for (index, revised) in corrections.earlier.enumerated() {
                if let revised, messages.indices.contains(index), messages[index].text != revised { messages[index].text = revised }
            }
            let answerText = corrections.answer
            messages.append(
                AIChatMessage(
                    role: .assistant,
                    text: answerText,
                    referencedArticles: ArticleReferenceExtractor.references(in: answerText, articles: answer.articles, handles: answer.articleHandles),
                    webCitations: answer.webCitations,
                    contextArticles: answer.articles,
                    contextHandles: answer.articleHandles ?? answer.articles.indices.map { $0 + 1 },
                    articleHandleRegistry: NativeAI.libraryChatHandleRegistry(articles: answer.articles, conversation: conversation),
                    isResearch: answer.isResearch
                )
            )
        } catch {
            messages.removeAll { $0.id == userMessage.id }
            // Back to the composer, or to the front of the queue when the
            // reader has started typing the next question.
            if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                input = toSend
                quotedText = quoteToSend
                quoteSource = sourceToSend
            } else {
                queued.insert(item, at: 0)
            }
            queuePaused = !queued.isEmpty
            let reauth: Bool = {
                if case NativeAIError.requiresReauthentication = error { return true }
                return false
            }()
            messages.append(AIChatMessage(role: .assistant, text: error.localizedDescription, isError: true, needsReauth: reauth, remedy: AIErrorRemedy.classify(error)))
        }
        isSending = false
        await sendNextQueued()
    }

    /// Queued questions as dimmed, outlined bubbles under the conversation;
    /// each can be edited in place or removed before it sends.
    private var queuedList: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                Text("QUEUED")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                Text(queuePaused ? "paused after an error" : "sends when Skim finishes")
                    .font(.system(size: 12))
                if queuePaused && !isSending {
                    Button("Resume") {
                        queuePaused = false
                        Task { await sendNextQueued() }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SkimStyle.accent)
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(SkimStyle.secondary)
            ForEach(Array(queued.enumerated()), id: \.element.id) { index, item in
                queuedRow(item, position: index + 1)
                    .id(item.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func queuedRow(_ item: QueuedChatMessage, position: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let editing = editingQueuedID == item.id
        return VStack(alignment: .leading, spacing: 4) {
            if let quote = item.quotedText {
                Text("\(item.quoteSource.caption): “\(quote)”")
                    .font(.system(size: 12))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineLimit(1)
            }
            if editing {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Edit question", text: $queuedDraft, axis: .vertical)
                        .focused($queuedEditorFocused)
                        .lineLimit(1...4)
                        .font(.system(size: 16))
                        .foregroundStyle(SkimStyle.text)
                        .submitLabel(.done)
                        .onSubmit { saveQueuedEdit(item.id) }
                    Button("Done") { saveQueuedEdit(item.id) }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SkimStyle.accent)
                        .buttonStyle(.plain)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    Text(item.text)
                        .font(.system(size: 16))
                        .foregroundStyle(SkimStyle.text.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        queuedDraft = item.text
                        editingQueuedID = item.id
                        queuedEditorFocused = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 40, height: 44)
                            .contentShape(Rectangle())
                    }
                    .padding(.vertical, -7)
                    .buttonStyle(.plain)
                    .foregroundStyle(SkimStyle.secondary)
                    .accessibilityLabel("Edit queued message")
                    Button {
                        queued.removeAll { $0.id == item.id }
                        if queued.isEmpty { queuePaused = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 40, height: 44)
                            .contentShape(Rectangle())
                    }
                    .padding(.vertical, -7)
                    .buttonStyle(.plain)
                    .foregroundStyle(SkimStyle.secondary)
                    .accessibilityLabel("Remove queued message")
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, editing ? 12 : 4)
        .padding(.vertical, 6)
        .background(SkimStyle.accent.opacity(0.07), in: shape)
        .overlay(shape.strokeBorder(SkimStyle.accent.opacity(editing ? 0.6 : 0.35), style: StrokeStyle(lineWidth: 1, dash: editing ? [] : [4, 3])))
        .frame(maxWidth: 320, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued message \(position)")
    }

    /// Saving an empty question removes it.
    private func saveQueuedEdit(_ id: UUID) {
        let text = queuedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            queued.removeAll { $0.id == id }
        } else if let index = queued.firstIndex(where: { $0.id == id }) {
            queued[index].text = text
        }
        editingQueuedID = nil
        queuedEditorFocused = false
        if queued.isEmpty { queuePaused = false }
        Task { await sendNextQueued() }
    }
}

/// A question written while Skim was still answering, waiting its turn.
struct QueuedChatMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var quotedText: String?
    var quoteSource: ChatQuoteSource
}

/// Tappable starter questions for an empty chat.
private struct ChatStarterPrompts: View {
    var prompts: [String]
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SkimStyle.secondary)
                .padding(.leading, 4)
            ForEach(prompts, id: \.self) { prompt in
                Button {
                    onSelect(prompt)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SkimStyle.accent)
                        Text(prompt)
                            .font(.system(size: 16))
                            .foregroundStyle(SkimStyle.text)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Asks this question")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AIChatMessage: Identifiable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    let id = UUID()
    var role: Role
    var text: String
    var quotedText: String? = nil
    var quoteSource: ChatQuoteSource = .answer
    var referencedArticles: [Article] = []
    var webCitations: [WebCitation] = []
    var contextArticles: [Article] = []
    var contextHandles: [Int] = []
    var articleHandleRegistry: [String: Int] = [:]
    /// A deep research briefing rather than a quick answer.
    var isResearch = false
    var isError = false
    var needsReauth = false
    var remedy: AIErrorRemedy = .none
}

private struct AIChatBubble: View {
    var message: AIChatMessage
    var onOpenArticle: ((String) -> Void)? = nil
    var onReauth: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onReply: ((String) -> Void)? = nil

    @State private var activeCitation: WebCitation?
    @State private var selectedText = ""

    /// The answer with each [n] turned into a chip link numbered like its card;
    /// [wN] web citations are numbered after the articles.
    private var citedMarkdown: String {
        guard message.role == .assistant else { return message.text }
        var text = message.text
        if !message.referencedArticles.isEmpty {
            text = ArticleReferenceExtractor.labeledCitations(
                in: text,
                references: message.referencedArticles,
                contextArticles: message.contextArticles,
                contextHandles: message.contextHandles
            )
        }
        if !message.webCitations.isEmpty {
            text = ArticleReferenceExtractor.labeledWebCitations(
                in: text, firstLabel: message.referencedArticles.count + 1, count: message.webCitations.count)
        }
        return text
    }

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 42)
            }

            VStack(alignment: .leading, spacing: 12) {
                if message.isResearch {
                    Label("Research briefing", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(SkimStyle.accent)
                }
                if let quote = message.quotedText {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message.quoteSource.caption)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SkimStyle.accent)
                        Text(quote)
                            .font(.system(size: 13))
                            .foregroundStyle(SkimStyle.secondary)
                            .lineLimit(3)
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(SkimStyle.accent).frame(width: 2)
                    }
                }

                SelectableChatText(
                    text: message.role == .assistant && !message.isError ? ChatMarkdown.attributed(citedMarkdown) : AttributedString(message.text),
                    sourceMarkdown: message.text,
                    isError: message.isError,
                    onReply: message.role == .assistant && !message.isError ? onReply : nil,
                    onOpenCitation: onOpenArticle,
                    onOpenWebCitation: { n in
                        if message.webCitations.indices.contains(n - 1) { activeCitation = message.webCitations[n - 1] }
                    },
                    onSelection: { selectedText = $0 }
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                if message.role == .assistant, !message.isError, !selectedText.isEmpty, let onReply {
                    Button {
                        onReply(selectedText)
                        selectedText = ""
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(SkimStyle.accent)
                }

                if message.needsReauth, let onReauth {
                    Button {
                        onReauth()
                    } label: {
                        Label("Sign in again", systemImage: "person.crop.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SkimStyle.accent)
                }

                if message.remedy == .openAISettings, let onOpenSettings {
                    Button {
                        onOpenSettings()
                    } label: {
                        Label("Open AI Settings", systemImage: "gearshape")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SkimStyle.accent)
                } else if message.isError, !message.needsReauth, let onOpenSettings {
                    // Other AI failures may still be a provider or model problem.
                    Button {
                        onOpenSettings()
                    } label: {
                        Label("AI Settings", systemImage: "gearshape")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(SkimStyle.accent)
                }

                if !message.referencedArticles.isEmpty {
                    // The cited articles as cards, numbered like the chips in the answer.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(Array(message.referencedArticles.enumerated()), id: \.element.id) { index, article in
                                NavigationLink(value: article.id) {
                                    ChatSourceTile(article: article, label: index + 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    // Scroll edge to edge inside the bubble and clip at its border,
                    // so a card that doesn't fit peeks rather than spilling past it.
                    .contentMargins(.horizontal, 15, for: .scrollContent)
                    .contentMargins(.vertical, 1, for: .scrollContent)
                    .padding(.horizontal, -15)
                }

                if !message.webCitations.isEmpty {
                    // Web sources as cards, numbered after the articles like their [wN] chips.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(Array(message.webCitations.enumerated()), id: \.element.id) { index, citation in
                                Button {
                                    activeCitation = citation
                                } label: {
                                    WebSourceTile(citation: citation, label: message.referencedArticles.count + index + 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    // Scroll edge to edge inside the bubble and clip at its border,
                    // so a card that doesn't fit peeks rather than spilling past it.
                    .contentMargins(.horizontal, 15, for: .scrollContent)
                    .contentMargins(.vertical, 1, for: .scrollContent)
                    .padding(.horizontal, -15)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(
                message.role == .user ? SkimStyle.accent.opacity(0.28) : SkimStyle.surface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )

            if message.role == .assistant {
                Spacer(minLength: 42)
            }
        }
        .sheet(item: $activeCitation) { citation in
            CitationBrowserSheet(citation: citation)
        }
    }
}

/// UITextView provides native iOS text selection and copying while keeping
/// the rendered Markdown attributes used by the chat bubble.
private struct SelectableChatText: UIViewRepresentable {
    var text: AttributedString
    var sourceMarkdown: String
    var isError: Bool
    var onReply: ((String) -> Void)?
    var onOpenCitation: ((String) -> Void)? = nil
    var onOpenWebCitation: ((Int) -> Void)? = nil
    var onSelection: (String) -> Void

    func makeUIView(context: Context) -> ChatSelectableTextView {
        let view = ChatSelectableTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = .systemFont(ofSize: 17)
        view.textColor = isError ? UIColor.systemRed : UIColor.label
        view.linkTextAttributes = [.foregroundColor: UIColor.tintColor]
        return view
    }

    func updateUIView(_ view: ChatSelectableTextView, context: Context) {
        context.coordinator.onSelection = onSelection
        context.coordinator.onReply = onReply
        context.coordinator.onOpenCitation = onOpenCitation
        context.coordinator.onOpenWebCitation = onOpenWebCitation
        let rendered = makeRenderedText()
        if view.attributedText != rendered {
            view.attributedText = rendered
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatSelectableTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    private func makeRenderedText() -> NSAttributedString {
        let rendered = NSMutableAttributedString(attributedString: NSAttributedString(text))
        let fullRange = NSRange(location: 0, length: rendered.length)
        let baseFont = UIFont.systemFont(ofSize: 17)
        rendered.addAttribute(.font, value: baseFont, range: fullRange)
        // In the text itself rather than textColor, which would repaint struck-through corrections.
        rendered.addAttribute(.foregroundColor, value: isError ? UIColor.systemRed : UIColor.label, range: fullRange)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        rendered.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

        for run in text.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let prefix = String(text[text.startIndex..<run.range.lowerBound].characters)
            let selected = String(text[run.range].characters)
            let range = NSRange(location: prefix.utf16.count, length: selected.utf16.count)
            if intent.contains(.strikethrough) {
                // An in-place correction: the wrong words struck through and dimmed.
                rendered.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                rendered.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
            }
            let isCode = intent.contains(.code)
            let isBold = intent.contains(.stronglyEmphasized)
            let isItalic = intent.contains(.emphasized)
            let font: UIFont
            if isCode {
                font = .monospacedSystemFont(ofSize: 15, weight: .regular)
                rendered.addAttribute(.backgroundColor, value: UIColor.secondarySystemBackground, range: range)
            } else if isBold && isItalic {
                font = .systemFont(ofSize: 17, weight: .bold).withTraits(.traitItalic)
            } else if isBold {
                font = .boldSystemFont(ofSize: 17)
            } else if isItalic {
                font = .italicSystemFont(ofSize: 17)
            } else {
                continue
            }
            rendered.addAttribute(.font, value: font, range: range)
        }

        // The "[updated]:" label of an in-place correction, in the accent like desktop.
        let plain = rendered.string as NSString
        var labelSearch = NSRange(location: 0, length: plain.length)
        while true {
            let found = plain.range(of: "[updated]:", range: labelSearch)
            if found.location == NSNotFound { break }
            rendered.addAttribute(.foregroundColor, value: UIColor.tintColor, range: found)
            labelSearch = NSRange(location: found.upperBound, length: plain.length - found.upperBound)
        }

        // Citation chips: a small number on a tinted pill, matching its card under the answer.
        for run in text.runs {
            guard let url = run.link,
                  url.scheme == ArticleReferenceExtractor.citationScheme || url.scheme == ArticleReferenceExtractor.webCitationScheme
            else { continue }
            let prefix = String(text[text.startIndex..<run.range.lowerBound].characters)
            let selected = String(text[run.range].characters)
            let range = NSRange(location: prefix.utf16.count, length: selected.utf16.count)
            rendered.addAttribute(.font, value: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), range: range)
            rendered.addAttribute(.backgroundColor, value: UIColor.tintColor.withAlphaComponent(0.18), range: range)
            rendered.addAttribute(.baselineOffset, value: 1, range: range)
        }

        let renderedString = rendered.string as NSString
        var searchLocation = 0
        var headingCodeFence: (marker: Character, length: Int)?
        for line in sourceMarkdown.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indentation = line.distance(from: line.startIndex, to: trimmed.startIndex)
            if indentation <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                let length = trimmed.prefix(while: { $0 == marker }).count
                if length >= 3 {
                    let rest = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
                    if let currentFence = headingCodeFence {
                        if currentFence.marker == marker, length >= currentFence.length, rest.isEmpty {
                            headingCodeFence = nil
                        }
                    } else {
                        headingCodeFence = (marker, length)
                    }
                    continue
                }
            }
            if headingCodeFence != nil { continue }
            let heading = line.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(heading), line.count > heading, line[line.index(line.startIndex, offsetBy: heading)] == " " else { continue }
            let title = String(line.dropFirst(heading + 1)).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let found = renderedString.range(of: title, options: [], range: NSRange(location: searchLocation, length: max(0, renderedString.length - searchLocation)))
            guard found.location != NSNotFound else { continue }
            let size = max(18, 24 - CGFloat(heading))
            rendered.addAttribute(.font, value: UIFont.systemFont(ofSize: size, weight: .semibold), range: found)
            searchLocation = NSMaxRange(found)
        }
        return rendered
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection, onReply: onReply) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSelection: (String) -> Void
        var onReply: ((String) -> Void)?
        var onOpenCitation: ((String) -> Void)?
        var onOpenWebCitation: ((Int) -> Void)?
        init(onSelection: @escaping (String) -> Void, onReply: ((String) -> Void)?) {
            self.onSelection = onSelection
            self.onReply = onReply
        }
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content, url.scheme == ArticleReferenceExtractor.webCitationScheme {
                guard let onOpenWebCitation, let n = ArticleReferenceExtractor.citedWebNumber(url) else { return nil }
                return UIAction { _ in onOpenWebCitation(n) }
            }
            guard case .link(let url) = textItem.content, url.scheme == ArticleReferenceExtractor.citationScheme else { return defaultAction }
            guard let onOpenCitation, let id = ArticleReferenceExtractor.citedArticleID(url) else { return nil }
            return UIAction { _ in onOpenCitation(id) }
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let range = textView.selectedTextRange else { onSelection(""); return }
            onSelection(textView.text(in: range)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            replyMenu(for: textView, suggestedActions: suggestedActions)
        }
        func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue], suggestedActions: [UIMenuElement]) -> UIMenu? {
            replyMenu(for: textView, suggestedActions: suggestedActions)
        }
        private func replyMenu(for textView: UITextView, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let onReply else { return UIMenu(children: suggestedActions) }
            let action = UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak textView] _ in
                guard let textView, let selection = textView.selectedTextRange,
                      let quote = textView.text(in: selection)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !quote.isEmpty else { return }
                textView.selectedTextRange = nil
                textView.resignFirstResponder()
                onReply(quote)
            }
            return UIMenu(children: suggestedActions + [action])
        }
    }
}

private final class ChatSelectableTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIView.noIntrinsicMetric
        guard width != UIView.noIntrinsicMetric else { return super.intrinsicContentSize }
        return sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// A tappable source chip for a single web-search citation. Shows the
/// citation's title (falling back to its domain when the title is empty)
/// behind a globe glyph, matching desktop's "web" source treatment.
/// A web source as a card: the number its chips carry, the site, the title and a line of what it says.
private struct WebSourceTile: View {
    var citation: WebCitation
    var label: Int

    private var site: String {
        (URL(string: citation.url)?.host(percentEncoded: false) ?? "Web").replacingOccurrences(of: "www.", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(label)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(SkimStyle.accent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SkimStyle.accent)
                Text(site)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineLimit(1)
            }
            Text(citation.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SkimStyle.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !citation.snippet.isEmpty {
                Text(citation.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 220, height: 124, alignment: .topLeading)
        .background(SkimStyle.chrome.opacity(0.64), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SkimStyle.separator.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Web source \(label): \(citation.title), \(site)")
    }
}

/// In-app browser sheet for opening a web-search citation, mirroring the
/// WKWebView-based reader used for the article "Web" page.
private struct CitationBrowserSheet: View {
    var citation: WebCitation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var snapshot = WebViewSnapshot()

    private var url: URL? { URL(string: citation.url) }

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    WebView(url: url, snapshot: $snapshot)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("Link unavailable", systemImage: "globe.badge.chevron.backward")
                        .foregroundStyle(SkimStyle.text)
                }
            }
            .navigationTitle(url?.host(percentEncoded: false) ?? citation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                if let url {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            openURL(url)
                        } label: {
                            Image(systemName: SkimIcon.openExternal)
                        }
                        .accessibilityLabel("Open in Browser")
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// A cited article as a card: the number its chips carry, the feed, and the title.
private struct ChatSourceTile: View {
    var article: Article
    var label: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(label)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(SkimStyle.accent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(article.feedTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineLimit(1)
            }
            Text(article.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SkimStyle.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 196, height: 104, alignment: .topLeading)
        .background(SkimStyle.chrome.opacity(0.64), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SkimStyle.separator.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Source \(label): \(article.title), \(article.feedTitle)")
    }
}

private struct ChatArticleReferenceRow: View {
    var article: Article

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SkimStyle.accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(article.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SkimStyle.text)
                    .lineLimit(2)

                Text(article.feedTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SkimStyle.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(SkimStyle.secondary.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(SkimStyle.chrome.opacity(0.64), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SkimStyle.separator.opacity(0.6), lineWidth: 1)
        }
        .accessibilityLabel("Open article \(article.title)")
    }
}

enum ArticleReferenceExtractor {
    static let citationScheme = "skim-cite"

    /// Rewrites each [n] the answer cites as a chip link numbered by its place in
    /// `references` (where the reader first meets it), so the chip and the card
    /// under the answer carry the same number. Chips stay on their word's line.
    static func labeledCitations(in text: String, references: [Article], contextArticles: [Article], contextHandles: [Int]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"( ?)\[(\d+)\](?!\()"#) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = NSMaxRange(match.range)
            let original = ns.substring(with: match.range)
            guard let handle = Int(ns.substring(with: match.range(at: 2))) else { result += original; continue }
            let position = contextHandles.isEmpty ? handle - 1 : (contextHandles.firstIndex(of: handle) ?? -1)
            guard contextArticles.indices.contains(position),
                  let label = references.firstIndex(where: { $0.id == contextArticles[position].id }),
                  let id = contextArticles[position].id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            else { result += original; continue }
            let lead = match.range(at: 1).length > 0 ? "\u{00A0}" : "\u{2060}"
            result += "\(lead)[\u{2009}\(label + 1)\u{2009}](\(citationScheme):\(id))"
        }
        return result + ns.substring(from: cursor)
    }

    static let webCitationScheme = "skim-cite-web"

    /// Rewrites each [wN] in a research briefing as a chip link labeled
    /// `firstLabel + N - 1`, so web chips number on from the article chips.
    static func labeledWebCitations(in text: String, firstLabel: Int, count: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"( ?)\[[wW](\d{1,3})\](?!\()"#) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = NSMaxRange(match.range)
            guard let n = Int(ns.substring(with: match.range(at: 2))), (1...max(count, 1)).contains(n), count > 0 else {
                result += ns.substring(with: match.range)
                continue
            }
            let lead = match.range(at: 1).length > 0 ? "\u{00A0}" : "\u{2060}"
            result += "\(lead)[\u{2009}\(firstLabel + n - 1)\u{2009}](\(webCitationScheme):\(n))"
        }
        return result + ns.substring(from: cursor)
    }

    /// The web source number a chip link made by `labeledWebCitations` points at.
    static func citedWebNumber(_ url: URL) -> Int? {
        guard url.scheme == webCitationScheme else { return nil }
        return Int(url.absoluteString.dropFirst(webCitationScheme.count + 1))
    }

    /// The article a chip link made by `labeledCitations` points at.
    static func citedArticleID(_ url: URL) -> String? {
        guard url.scheme == citationScheme else { return nil }
        let encoded = url.absoluteString.dropFirst(citationScheme.count + 1)
        return String(encoded).removingPercentEncoding
    }

    static func references(in text: String, articles: [Article], handles: [Int]? = nil) -> [Article] {
        var references: [Article] = []
        var seenIDs: Set<String> = []

        for index in numericHandles(in: text) {
            let zeroBased: Int
            if let handles {
                guard let position = handles.firstIndex(of: index), articles.indices.contains(position) else { continue }
                zeroBased = position
            } else {
                zeroBased = index - 1
                guard articles.indices.contains(zeroBased) else { continue }
            }
            let article = articles[zeroBased]
            if seenIDs.insert(article.id).inserted {
                references.append(article)
            }
        }

        if references.isEmpty {
            for article in articles where text.localizedCaseInsensitiveContains(article.title) {
                if seenIDs.insert(article.id).inserted {
                    references.append(article)
                }
            }
        }

        return references
    }

    private static func numericHandles(in text: String) -> [Int] {
        let pattern = #"\[(\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return Int(text[range])
        }
    }
}

private extension Article {
    var plainBody: String {
        if let contentText, !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contentText
        }
        return contentHTML?.plainTextFromHTML ?? ""
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var plainTextFromHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func prefixWords(_ maxWords: Int) -> String {
        let words = split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard words.count > maxWords else { return self }
        return words.prefix(maxWords).joined(separator: " ") + "..."
    }
}

private extension View {
    @ViewBuilder
    func chatHardTopScrollEdge() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}

// MARK: - Deep research

extension NativeAI {
    /// Deep research on the latest question: the reader's feeds first, then the
    /// web for what they leave open, written up as a briefing that cites both.
    /// The steps and prompts match desktop (src-tauri/src/commands/research.rs);
    /// `progress` hears each step as it starts.
    static func research(
        conversation: AIChatConversation,
        settings: AppSettings,
        store: SkimStore,
        fullest: @escaping @Sendable ([Article]) async -> [Article],
        progress: @MainActor @escaping (String) -> Void
    ) async throws -> AIChatAnswer {
        var settings = settings
        settings.ai = OfflineAIFallback.effective(AIRequestPolicy.chatSettings(settings.ai))
        let question = conversation.latestPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = conversation.priorTurns.map { "\($0.role == .user ? "Reader" : "Skim"): \(String($0.promptText.prefix(1500)))" }
        let asked = history.isEmpty ? question : "Conversation so far:\n\(history.joined(separator: "\n"))\n\nQuestion: \(question)"

        // 1. Plan searches of the library.
        await progress("Planning the research")
        let plan = ResearchPolicy.plan(
            from: try await complete(settings: settings, instructions: ResearchPolicy.planPrompt, prompt: asked, maxTokens: 400, jsonMode: true),
            question: conversation.latestQuestion)
        let focus = ([conversation.latestQuestion, plan.topic] + plan.libraryQueries).joined(separator: " ")

        // 2. Search the library.
        var searches: [[Article]] = []
        for query in plan.libraryQueries {
            try Task.checkCancellation()
            let terms = LibraryChatPolicy.topicKeywords(query)
            guard !terms.isEmpty else { continue }
            await progress("Searched your feeds for \u{201c}\(query)\u{201d}")
            searches.append(try await store.searchArticlesForChat(filter: ArticleFilter(), feedIDs: nil,
                terms: terms, allowRecentFallback: false, limit: 15))
        }
        let found = ResearchPolicy.fuse(pinned: [], searches: searches, id: \.id, limit: ResearchPolicy.libraryArticles)

        // 3. Read the best of them in full, from what is already on the device.
        let read = min(found.count, ResearchPolicy.readArticles)
        if read > 0 { await progress("Read \(read) of your articles") }
        let articles = await fullest(Array(found.prefix(read))) + found.dropFirst(read)
        let handles = libraryChatHandles(articles: articles, conversation: conversation)
        let library = articles.isEmpty ? "The reader's articles have nothing on this." : zip(articles, handles).enumerated().map { index, pair in
            let (article, handle) = pair
            let excerpt = LibraryChatPolicy.queryExcerpt(text: article.plainBody, query: focus,
                maxCharacters: index < ResearchPolicy.readArticles ? 2500 : 600)
            let url = article.externalURL?.absoluteString ?? article.url?.absoluteString ?? ""
            return "[\(handle)] \(article.title) (\(article.feedTitle))\n\(AIRequestPolicy.publicationContext(article.publishedAt))\nURL: \(url)\n\(excerpt.isEmpty ? "(no text available)" : excerpt)"
        }.joined(separator: "\n\n")

        // 4. Find what the library leaves open.
        await progress("Looked for gaps in your feeds' coverage")
        let gapsReply = (try? await complete(settings: settings, instructions: ResearchPolicy.gapsPrompt,
            prompt: "Question: \(asked)\nTopic: \(plan.topic)\n\nThe reader's articles:\n\(library)", maxTokens: 500, jsonMode: true)) ?? ""
        let gaps = ResearchPolicy.gaps(from: gapsReply, topic: plan.topic)

        // 5. Fill the gaps from the web.
        let libraryURLs = Set(articles.compactMap { $0.url?.absoluteString } + articles.compactMap { $0.externalURL?.absoluteString })
        var web: [SearchResult] = []
        var perQuery: [[Int]] = []
        for query in gaps.webQueries {
            try Task.checkCancellation()
            await progress("Searched the web for \u{201c}\(query)\u{201d}")
            var indices: [Int] = []
            do {
                for result in try await NativeWebSearch.run(query: query, maxResults: ResearchPolicy.webResultsPerQuery)
                where !libraryURLs.contains(result.url) {
                    if let index = web.firstIndex(where: { $0.url == result.url }) {
                        indices.append(index)
                    } else {
                        web.append(result)
                        indices.append(web.count - 1)
                    }
                }
            } catch {
                await progress("Web search failed: \(error.localizedDescription)")
            }
            perQuery.append(indices)
        }

        // 6. Read the top web pages, taking each query's best result in turn.
        var toRead: [Int] = []
        for rank in 0..<ResearchPolicy.webResultsPerQuery {
            for indices in perQuery where indices.count > rank && !toRead.contains(indices[rank]) && toRead.count < ResearchPolicy.webPagesRead {
                toRead.append(indices[rank])
            }
        }
        var pages: [Int: String] = [:]
        if !toRead.isEmpty {
            var sites: [String] = []
            for index in toRead where !sites.contains(ResearchPolicy.domain(web[index].url)) { sites.append(ResearchPolicy.domain(web[index].url)) }
            await progress("Read \(toRead.count == 1 ? "1 web page" : "\(toRead.count) web pages") (\(sites.joined(separator: ", ")))")
            let targets = toRead.map { ($0, web[$0].url) }
            pages = await withTaskGroup(of: (Int, String?).self) { group in
                for (index, url) in targets {
                    group.addTask { (index, await readWebPage(url)) }
                }
                var out: [Int: String] = [:]
                for await (index, text) in group {
                    if let text, text.split(whereSeparator: \.isWhitespace).count >= 60 { out[index] = text }
                }
                return out
            }
        }
        let webText = web.isEmpty ? "None found." : web.enumerated().map { index, result in
            let body = pages[index].map { LibraryChatPolicy.queryExcerpt(text: $0, query: focus, maxCharacters: 1800) } ?? result.snippet
            return "[w\(index + 1)] \(result.title) (\(ResearchPolicy.domain(result.url)))\nURL: \(result.url)\n\(body)"
        }.joined(separator: "\n\n")

        // 7. Write the briefing.
        await progress("Writing the briefing")
        let today = Date().formatted(.iso8601.year().month().day())
        let gapsNote = gaps.gaps.isEmpty ? "" : "\n\nGaps the web sources were found to fill: \(gaps.gaps.joined(separator: "; "))"
        let raw = try await complete(
            settings: settings,
            instructions: ResearchPolicy.briefingPrompt(today: today),
            prompt: "Question: \(asked)\n\nThe reader's articles (cite as [n]):\n\(library)\n\nWeb sources (cite as [wN]):\n\(webText)\(gapsNote)",
            maxTokens: AIRequestPolicy.requestMaxTokens(ResearchPolicy.briefingTokens, provider: settings.ai.provider)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw NativeAIError.unavailable("The model returned an empty briefing. Try again.") }

        // Web sources renumbered in reading order, keeping only the ones cited.
        let order = ResearchPolicy.citedWebOrder(in: raw, count: web.count)
        let citations = order.map { n in
            WebCitation(title: web[n - 1].title, url: web[n - 1].url, snippet: web[n - 1].snippet, query: "")
        }
        return AIChatAnswer(text: ResearchPolicy.renumberWeb(raw, order: order), articles: articles,
                            webCitations: citations, articleHandles: handles, isResearch: true)
    }

    /// A web page's readable text, or nil when it cannot be fetched in time.
    private static func readWebPage(_ address: String) async -> String? {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        return try? ArticleExtractor.extract(from: html, baseURL: url)
    }
}

/// The research in flight, step by step, so a slow answer never looks stuck.
private struct ResearchProgressList: View {
    var steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Researching... this takes a minute or two")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SkimStyle.text)
            ForEach(Array((steps.isEmpty ? ["Starting..."] : steps).enumerated()), id: \.offset) { index, step in
                let current = steps.isEmpty || index == steps.count - 1
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if current {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(SkimStyle.accent)
                            .frame(width: 14)
                            // A spinner has no text baseline; centre it on the step's first line.
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(SkimStyle.accent)
                            .frame(width: 14)
                    }
                    Text(step)
                        .font(.system(size: 14))
                        .foregroundStyle(current ? SkimStyle.text : SkimStyle.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
