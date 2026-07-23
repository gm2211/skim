import OSLog
import SkimCore
import SwiftUI
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

struct AIChatConversation: Sendable {
    struct Turn: Sendable {
        enum Role: String, Sendable {
            case user
            case assistant
        }

        var role: Role
        var text: String
    }

    var priorTurns: [Turn]
    var latestQuestion: String

    init(latestQuestion: String, priorMessages: [AIChatMessage] = []) {
        self.latestQuestion = latestQuestion
        self.priorTurns = priorMessages
            .filter { !$0.isError }
            .suffix(8)
            .map { message in
                Turn(
                    role: message.role == .user ? .user : .assistant,
                    text: message.text
                )
            }
    }

    var promptSection: String {
        let latest = latestQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !priorTurns.isEmpty else {
            return """
            Latest user question to answer now:
            \(latest)
            """
        }

        let transcript = priorTurns.map { turn in
            let role = turn.role == .user ? "User" : "Assistant"
            return "\(role): \(turn.text)"
        }
        .joined(separator: "\n\n")

        return """
        Previous conversation for context only. Do not answer these older turns again:
        \(transcript)

        Latest user question to answer now:
        \(latest)
        """
    }
}

struct AIChatRequest: Identifiable {
    let id = UUID()
    var sessionKey = UUID().uuidString
    var title: String
    var placeholder: String
    var answer: (AIChatConversation) async throws -> AIChatAnswer
}

struct AIChatAnswer {
    var text: String
    var articles: [Article]
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

enum NativeAI {
    static func loadingStatusLabel(for ai: AISettings) -> String {
        switch ai.provider {
        case "foundation-models":
            return "Asking Apple Intelligence..."
        case "mlx":
            let repoId = ai.localModelPath?.nilIfEmpty ?? ai.model?.nilIfEmpty ?? NativeMLX.defaultRepoId
            return "Running \(NativeMLX.option(for: repoId).label)..."
        case "claude-subscription":
            return "Asking Claude Pro/Max..."
        case "custom":
            return "Calling \(ai.model?.nilIfEmpty ?? "custom provider")..."
        case "anthropic":
            return "Asking Claude..."
        case "openai":
            return "Calling OpenAI..."
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

    static func quickCatchUp(articles: [Article], settings: AppSettings) async throws -> String {
        try await complete(
            settings: settings,
            instructions: """
            You write crisp catch-up reports for a news/RSS reader. Be useful, specific, and concise. Use Markdown headings and bullets. Whenever you mention a specific article, cite it with its numeric handle like [3] and its title so the app can make it clickable.
            """,
            prompt: """
            Create a Super Quick Catch-up from these articles. Group related items into themes, name what matters, and keep it scannable.

            \(articleDigest(articles, limit: catchUpArticleLimit))
            """,
            maxTokens: 700
        )
    }

    /// Structured catch-up items returned by the AI.
    struct CatchUpItem {
        var title: String
        var summary: String
        /// 1-based index into the articles array passed to `quickCatchUpStructured`.
        var articleIndex: Int?
    }

    /// Returns structured catch-up items. On JSON parse failure returns `nil` so the
    /// caller can fall back to the plain-text path.
    ///
    /// When the provider is "foundation-models" on iOS 26+, uses `@Generable`
    /// guided generation to bypass the JSON parse / repair path entirely.
    static func quickCatchUpStructured(articles: [Article], settings: AppSettings) async throws -> [CatchUpItem]? {
        // FM guided-generation fast path — no JSON parsing required.
#if canImport(FoundationModels)
        if #available(iOS 26.0, *), settings.ai.provider == "foundation-models" {
            return try await quickCatchUpStructuredFM(articles: articles)
        }
#endif

        let raw = try await complete(
            settings: settings,
            instructions: """
            You write crisp catch-up items for a news/RSS reader. Output ONLY valid JSON. No prose. No markdown fences. The format is exactly:
            {"items":[{"title":"...","summary":"...","articleIndex":3},{"title":"...","summary":"...","articleIndex":null}]}
            Rules:
            - "title": short headline (≤10 words).
            - "summary": 1–2 sentence plain-text summary, no markdown.
            - "articleIndex": 1-based integer matching the [N] tag in the article list, or null if the item covers multiple articles.
            - Return 5–12 items covering the most important stories.
            - Output ONLY the JSON object above. No text before or after. No code block.
            """,
            prompt: """
            Create a Quick Catch-up from these articles.

            \(articleDigest(articles, limit: catchUpArticleLimit))
            """,
            maxTokens: 1200
        )

        return parseCatchUpItems(raw)
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

    static func aiInbox(articles: [Article], settings: AppSettings) async throws -> String {
        // FM guided-generation fast path — schema-constrained output, no JSON parsing.
#if canImport(FoundationModels)
        if #available(iOS 26.0, *), settings.ai.provider == "foundation-models" {
            return try await aiInboxFM(articles: articles)
        }
#endif

        return try await complete(
            settings: settings,
            instructions: """
            You triage RSS articles for a smart inbox. Pick what seems most worth reading and explain why. Use Markdown bullets. Cite every selected article with its numeric handle like [3] and title so the app can make it clickable. Output ONLY plain Markdown — no JSON, no code fences.
            """,
            prompt: """
            Rank the most interesting articles from this list. Return 8-12 picks with a short reason for each. Favor novelty, depth, engineering relevance, and things a curious technical reader would not want to miss.

            User interests:
            \(settings.ai.triageUserPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "No explicit interests configured.")

            \(articleDigest(articles, limit: 45))
            """,
            maxTokens: 750
        )
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
        let key = summaryCacheKey(articleID: article.id, ai: settings.ai)
        if let cached = SummaryLRUCache.shared.get(key) {
            return cached
        }
        let wordCount = summaryTargetWordCount(settings.ai)
        // Pass wordCount into instructions so the system prompt carries the full directive.
        // The user turn contains only the article body to avoid FM echoing the instruction
        // text back as part of the response (a known issue with some Foundation Models builds).
        let result = try await complete(
            settings: settings,
            instructions: summaryInstructions(settings.ai, wordCount: wordCount),
            prompt: """
            Article to summarize:

            \(articleDigest([article], limit: 1, wordsPerArticle: 2200))
            """,
            maxTokens: summaryMaxTokens(wordCount)
        )
        SummaryLRUCache.shared.set(key, value: result)
        return result
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
        let key = summaryCacheKey(articleID: article.id, ai: settings.ai)
        if let cached = SummaryLRUCache.shared.get(key) {
            await onToken(cached)
            return cached
        }
        let wordCount = summaryTargetWordCount(settings.ai)
        let prompt = """
        Summarize this article. Write a summary of approximately \(wordCount) words.

        \(articleDigest([article], limit: 1, wordsPerArticle: 2200))
        """
        let instructions = summaryInstructions(settings.ai)
        let maxTok = summaryMaxTokens(wordCount)

        let result: String
        if settings.ai.provider == "mlx" {
            result = try await NativeMLX.stream(
                settings: settings.ai,
                instructions: instructions,
                prompt: prompt,
                maxTokens: maxTok,
                jsonMode: false,
                onToken: { chunk in
                    Task { @MainActor in onToken(chunk) }
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

        SummaryLRUCache.shared.set(key, value: result)
        return result
    }

    /// Evicts the cached summary for the given article + settings combination.
    static func clearSummaryCache(articleID: String, ai: AISettings) {
        SummaryLRUCache.shared.remove(summaryCacheKey(articleID: articleID, ai: ai))
    }

    private static func summaryCacheKey(articleID: String, ai: AISettings) -> String {
        let model = ai.model?.nilIfEmpty ?? ai.provider
        let wordCount = summaryTargetWordCount(ai)
        return [
            articleID,
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
        let header = "Web search results for \"\(query)\" (use for facts not in the article; answer in prose):"
        let body = results.enumerated().map { index, result in
            let label = "(W\(index + 1))"
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
        let digest = articleContext.prefixWords(400)
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
    private static func buildLocalChatMessages(
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
            ["role": turn.role == .user ? "user" : "assistant", "content": turn.text]
        }

        let finalUser: [String: String] = ["role": "user", "content": conversation.latestQuestion]

        return [systemMessage] + priorTurnMessages + [finalUser]
    }

    /// Local MLX chat with optional web-search augmentation (2-pass: router + answer).
    /// Falls back to a plain local answer on any failure in the router or search step.
    private static func chatLocalWithSearch(
        conversation: AIChatConversation,
        articleContext: String,
        instructions: String,
        answerMaxTokens: Int,
        settings: AppSettings
    ) async throws -> String {
        let skipRouter = canSkipRouter(conversation: conversation, articleCount: 1)

        let decision: LocalSearchDecision
        if skipRouter {
            decision = .answer
        } else {
            decision = await routeLocalChat(
                conversation: conversation,
                articleContext: articleContext,
                settings: settings
            )
        }

        switch decision {
        case .answer:
            let msgs = buildLocalChatMessages(
                instructions: instructions,
                articleContext: articleContext,
                conversation: conversation,
                webBlock: nil
            )
            return try await NativeMLX.complete(
                settings: settings.ai,
                messages: msgs,
                maxTokens: answerMaxTokens
            )

        case .search(let query):
            let results = (try? await NativeWebSearch.run(query: query, maxResults: 4)) ?? []
            guard !results.isEmpty else {
                // Empty results: fall back to answering from article only (multi-turn, no web block)
                let msgs = buildLocalChatMessages(
                    instructions: instructions,
                    articleContext: articleContext,
                    conversation: conversation,
                    webBlock: nil
                )
                return try await NativeMLX.complete(
                    settings: settings.ai,
                    messages: msgs,
                    maxTokens: answerMaxTokens
                )
            }
            let webBlock = formatWebResultsBlock(query: query, results: results)
            // Trim article digest when search fires to stay within 1B token budget
            let trimmedContext = articleContext.prefixWords(700)
            let answerInstructions = instructions + "\n\nWeb search results are provided below; use them for facts the article doesn't cover; if they don't help, say what you couldn't find."
            let msgs = buildLocalChatMessages(
                instructions: answerInstructions,
                articleContext: trimmedContext,
                conversation: conversation,
                webBlock: webBlock
            )
            return try await NativeMLX.complete(
                settings: settings.ai,
                messages: msgs,
                maxTokens: answerMaxTokens
            )
        }
    }

    static func chat(question: String, article: Article, settings: AppSettings) async throws -> String {
        try await chat(
            conversation: AIChatConversation(latestQuestion: question),
            article: article,
            settings: settings
        )
    }

    static func chat(conversation: AIChatConversation, article: Article, settings: AppSettings) async throws -> String {
        let toolsOK = ["anthropic", "claude-subscription"].contains(settings.ai.provider)
        let baseInstructions = "You answer questions about a single article using only the provided article text and the conversation context. Answer only the latest user question. Use previous turns only to resolve references like 'that' or 'the second one'. Do not repeat a prior answer unless the latest question explicitly asks you to recap it. If the answer is not in the article, say so."
        let instructions = toolsOK
            ? baseInstructions + "\n\nIf the provided article context doesn't answer the latest question, call the `web_search` tool to fetch fresh web results, then answer using them. Prefer the article context when it suffices."
            : baseInstructions

        // Local MLX web-search path (skim-7oi1)
        if localWebSearchEnabled(settings.ai) {
            let articleContext = articleDigest([article], limit: 1, wordsPerArticle: 1800)
            return try await chatLocalWithSearch(
                conversation: conversation,
                articleContext: articleContext,
                instructions: baseInstructions,
                answerMaxTokens: 650,
                settings: settings
            )
        }

        // MLX without web search: still use multi-turn messages for better instruct-model behavior
        if settings.ai.provider == "mlx" {
            let articleContext = articleDigest([article], limit: 1, wordsPerArticle: 1800)
            let msgs = buildLocalChatMessages(
                instructions: baseInstructions,
                articleContext: articleContext,
                conversation: conversation,
                webBlock: nil
            )
            return try await NativeMLX.complete(
                settings: settings.ai,
                messages: msgs,
                maxTokens: 650
            )
        }

        return try await complete(
            settings: settings,
            instructions: instructions,
            prompt: """
            Article:
            \(articleDigest([article], limit: 1, wordsPerArticle: 1800))

            \(conversation.promptSection)
            """,
            maxTokens: 650,
            enableWebSearch: toolsOK
        )
    }

    static func chat(question: String, articles: [Article], settings: AppSettings) async throws -> String {
        try await chat(
            conversation: AIChatConversation(latestQuestion: question),
            articles: articles,
            settings: settings
        )
    }

    static func chat(conversation: AIChatConversation, articles: [Article], settings: AppSettings) async throws -> String {
        let toolsOK = ["anthropic", "claude-subscription"].contains(settings.ai.provider)
        let baseInstructions = """
            You answer questions across a set of RSS articles using the provided article list and conversation context. Answer only the latest user question. Use previous turns only to resolve references like 'that' or 'the second one'. Do not repeat prior answers unless the latest question explicitly asks. When mentioning, ranking, recommending, or listing articles, cite each article with its numeric handle like [3] and its title. Keep handles attached to the relevant sentence or bullet so the app can make them clickable.
            """
        let instructions = toolsOK
            ? baseInstructions + "\n\nIf the provided article context doesn't answer the latest question, call the `web_search` tool to fetch fresh web results, then answer using them. Prefer the article context when it suffices."
            : baseInstructions
        // Note (skim-7oi1 v1): local MLX web search is scoped to single-article chat only.
        // Multi-article chat falls through to the plain complete() path.
        return try await complete(
            settings: settings,
            instructions: instructions,
            prompt: """
            Articles:
            \(articleDigest(articles, limit: 35))

            \(conversation.promptSection)
            """,
            maxTokens: 850,
            enableWebSearch: toolsOK
        )
    }

    static func complete(
        settings: AppSettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        jsonMode: Bool = false,
        enableWebSearch: Bool = false
    ) async throws -> String {
        let ai = settings.ai
        switch ai.provider {
        case "none":
            throw NativeAIError.unavailable("AI features are disabled in Settings.")
        case "foundation-models":
            return try await completeWithFoundationModels(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
        case "openai", "openrouter", "custom":
            return try await completeOpenAICompatible(settings: ai, instructions: instructions, prompt: prompt, maxTokens: maxTokens)
        case "anthropic", "claude-subscription":
            if enableWebSearch {
                return try await completeAnthropicWithTools(settings: ai, instructions: instructions, prompt: prompt, maxTokens: maxTokens)
            }
            return try await completeAnthropic(settings: ai, instructions: instructions, prompt: prompt, maxTokens: maxTokens)
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

    static func completeWithFoundationModels(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel(useCase: .general)
            switch model.availability {
            case .available:
                break
            case .unavailable(let reason):
                throw NativeAIError.unavailable("Apple Intelligence is not available: \(reasonDescription(reason)).")
            }

            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(
                    sampling: .random(top: 50),
                    temperature: 0.7,
                    maximumResponseTokens: maxTokens
                )
            )
            let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return stripEchoedPrompt(raw, prompt: prompt)
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

    private static func completeOpenAICompatible(settings: AISettings, instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        let key = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let provider = settings.provider
        if provider != "custom", key == nil {
            throw NativeAIError.unavailable("Add an API key for \(providerDisplayName(provider)) in Settings.")
        }

        var request = URLRequest(url: openAICompatibleURL(settings))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if provider == "openrouter" {
            request.setValue("Skim", forHTTPHeaderField: "X-Title")
        }

        let body: [String: Any] = [
            "model": settings.model?.nilIfEmpty ?? defaultModel(for: provider),
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, provider: providerDisplayName(provider))
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content.nilIfEmpty else {
            throw NativeAIError.unavailable("The \(providerDisplayName(provider)) response was empty.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func completeAnthropic(settings: AISettings, instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        if settings.provider == "claude-subscription" {
            return try await completeAnthropicSubscription(settings: settings, instructions: instructions, prompt: prompt, maxTokens: maxTokens)
        }
        // API-key path (provider == "anthropic")
        let key = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let key else {
            throw NativeAIError.unavailable("Add a Claude API key in Settings.")
        }
        let request = try buildAnthropicRequest(settings: settings, accessToken: key, isSubscription: false, instructions: instructions, prompt: prompt, maxTokens: maxTokens)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, provider: providerDisplayName(settings.provider))
        return try decodeAnthropicContent(data: data)
    }

    /// Handles the claude-subscription path with Keychain token storage, migration,
    /// and automatic one-shot refresh on 401.
    private static func completeAnthropicSubscription(settings: AISettings, instructions: String, prompt: String, maxTokens: Int) async throws -> String {
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

        let request = try buildAnthropicRequest(settings: settings, accessToken: accessToken, isSubscription: true, instructions: instructions, prompt: prompt, maxTokens: maxTokens)
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
            let retryRequest = try buildAnthropicRequest(settings: settings, accessToken: newToken, isSubscription: true, instructions: instructions, prompt: prompt, maxTokens: maxTokens)
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
    private static func buildAnthropicRequestFull(
        settings: AISettings,
        accessToken: String,
        isSubscription: Bool,
        instructions: String,
        messages: [[String: Any]],
        maxTokens: Int,
        tools: [[String: Any]]? = nil
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
        var body: [String: Any] = [
            "model": resolveAnthropicModel(settings),
            "system": instructions,
            "messages": messages,
            "temperature": 0.2,
            "max_tokens": maxTokens
        ]
        if let tools {
            body["tools"] = tools
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Thin wrapper preserving the original single-message, no-tools signature
    /// used by all non-chat callers (summarize, triage, inbox). Byte-for-byte
    /// equivalent to the old `buildAnthropicRequest`.
    private static func buildAnthropicRequest(settings: AISettings, accessToken: String, isSubscription: Bool, instructions: String, prompt: String, maxTokens: Int) throws -> URLRequest {
        try buildAnthropicRequestFull(
            settings: settings,
            accessToken: accessToken,
            isSubscription: isSubscription,
            instructions: instructions,
            messages: [["role": "user", "content": prompt]],
            maxTokens: maxTokens,
            tools: nil
        )
    }

    private static func decodeAnthropicContent(data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        let content = decoded.content.compactMap(\.text).joined(separator: "\n").nilIfEmpty
        guard let content else {
            throw NativeAIError.unavailable("The Claude response was empty.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private static func completeAnthropicWithTools(
        settings: AISettings,
        instructions: String,
        prompt: String,
        maxTokens: Int
    ) async throws -> String {
        let isSubscription = settings.provider == "claude-subscription"

        // Resolve access token (mirrors completeAnthropic / completeAnthropicSubscription)
        let accessToken: String
        if isSubscription {
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
        var messages: [[String: Any]] = [["role": "user", "content": prompt]]

        let maxIterations = 3
        var currentToken = accessToken

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
            let data: Data
            let response: URLResponse
            (data, response) = try await URLSession.shared.data(for: request)

            if isSubscription, let http = response as? HTTPURLResponse, http.statusCode == 401 {
                let newToken: String
                do {
                    newToken = try await NativeClaudeOAuth.refreshStoredTokens()
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
                let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                try validate(response: retryResponse, data: retryData, provider: providerDisplayName(settings.provider))
                return try decodeAnthropicContent(data: retryData)
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
                    throw NativeAIError.unavailable("The Claude response was empty.")
                }
                return trimmed
            }

            if iteration == maxIterations {
                // Hit iteration cap; return whatever text we have.
                let trimmed = joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "(No response)" : trimmed
            }

            // --- Build assistant turn (text block + tool_use blocks) ---
            var assistantContentBlocks: [[String: Any]] = []
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
            messages.append(["role": "assistant", "content": assistantContentBlocks])

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
                            let payload: [String: Any] = [
                                "query": query,
                                "results": results.map { ["title": $0.title, "url": $0.url, "snippet": $0.snippet] }
                            ]
                            let payloadData = try JSONSerialization.data(withJSONObject: payload)
                            let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
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
            messages.append(["role": "user", "content": resultBlocks])
        }

        // Should never reach here due to loop structure, but satisfy the compiler.
        throw NativeAIError.unavailable("Tool-use loop exited without a final response.")
    }

    private static func openAICompatibleURL(_ settings: AISettings) -> URL {
        let base: String
        switch settings.provider {
        case "openai":
            base = "https://api.openai.com"
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
            let text = String(data: data, encoding: .utf8) ?? "No response body."
            throw NativeAIError.unavailable("\(provider) request failed (\(status)): \(text.prefix(500))")
        }
    }

    /// Returns the correct Anthropic model id, guarding against a leaked MLX repo id
    /// (e.g. "mlx-community/gemma-3-1b-it-4bit") that the shared `ai.model` field may
    /// contain when the user previously used local inference and then signed into Claude.
    private static func resolveAnthropicModel(_ settings: AISettings) -> String {
        let m = settings.model?.nilIfEmpty
        if let m, m.hasPrefix("claude") { return m }
        return defaultModel(for: settings.provider)
    }

    private static func defaultModel(for provider: String) -> String {
        switch provider {
        case "anthropic", "claude-subscription":
            return "claude-sonnet-4-5"
        case "openrouter":
            return "openai/gpt-4o-mini"
        default:
            return "gpt-4o-mini"
        }
    }

    private static func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "openai": "OpenAI"
        case "openrouter": "OpenRouter"
        case "anthropic": "Claude API"
        case "claude-subscription": "Claude subscription"
        case "custom": "Custom provider"
        default: provider
        }
    }

    private static func summaryInstructions(_ settings: AISettings, wordCount: Int? = nil) -> String {
        let tone = settings.summaryTone?.nilIfEmpty ?? "concise"
        var instructions = "You summarize articles accurately in a \(tone) style. Preserve nuance, avoid hype, and mention uncertainty when the source is thin."
        if let wordCount {
            instructions += " Write approximately \(wordCount) words. Output only the summary — no preamble, no restating the title, no metadata."
        }
        if let custom = settings.summaryCustomPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            instructions += "\n\nUser summary instructions:\n\(custom)"
        }
        return instructions
    }

    private static func summaryTargetWordCount(_ settings: AISettings) -> Int {
        if let words = settings.summaryCustomWordCount, words > 0 {
            return words
        }
        return 150
    }

    private static func summaryMaxTokens(_ wordCount: Int) -> Int {
        Int(Double(wordCount) * 1.5) + 50
    }

    private static func articleDigest(_ articles: [Article], limit: Int, wordsPerArticle: Int = 95) -> String {
        let selected = articles.prefix(limit)
        if selected.isEmpty {
            return "No articles are available."
        }

        return selected.enumerated().map { index, article in
            let text = article.plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = text.isEmpty ? "No reader text available." : text.prefixWords(wordsPerArticle)
            return """
            [\(index + 1)] \(article.title)
            Feed: \(article.feedTitle)
            Author: \(article.author ?? "unknown")
            Excerpt: \(excerpt)
            """
        }
        .joined(separator: "\n\n")
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

    // MARK: - @Generable triage types (Foundation Models guided generation)
    //
    // These types are used with `session.respond(to:generating:)` to produce
    // schema-constrained output, eliminating JSON parsing errors entirely.
    // Only used when the provider is "foundation-models" on iOS 26+.

    /// Guided-generation output for AI Inbox triage.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct FMTriageEntry {
        /// 1-based index into the articles array.
        @Guide(description: "1-based index of the article in the provided list")
        var articleIndex: Int
        /// Short explanation of why this article is worth reading.
        @Guide(description: "One sentence explanation of why this article is worth reading")
        var reason: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct FMTriageProposal {
        /// Ranked list of picked articles, best first.
        @Guide(description: "8 to 12 articles ranked by interest, best first")
        var ranked: [FMTriageEntry]
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

    /// Uses Foundation Models guided generation to produce structured AI Inbox picks.
    /// Returns a formatted Markdown string equivalent to the free-text `aiInbox` path,
    /// but bypasses JSON parsing by using `@Generable` schema-constrained output.
    @available(iOS 26.0, macOS 26.0, *)
    static func aiInboxFM(articles: [Article]) async throws -> String {
        let model = SystemLanguageModel(useCase: .general)
        guard case .available = model.availability else {
            throw NativeAIError.unavailable("Apple Intelligence is not available.")
        }
        let session = LanguageModelSession(
            model: model,
            instructions: """
            You triage RSS articles for a smart inbox. Rank the most interesting articles and provide a short reason for each pick.
            """
        )
        let digest = articleDigest(articles, limit: 45)
        let response = try await session.respond(
            to: """
            Rank 8–12 articles from this list. Favor novelty, depth, and things a curious technical reader would not want to miss.

            \(digest)
            """,
            generating: FMTriageProposal.self,
            options: GenerationOptions(sampling: .random(top: 50), temperature: 0.7, maximumResponseTokens: 800)
        )
        let proposal = response.content
        // Convert to Markdown bullets matching the free-text path format.
        let lines = proposal.ranked.compactMap { entry -> String? in
            let idx = entry.articleIndex
            guard articles.indices.contains(idx - 1) else { return nil }
            let article = articles[idx - 1]
            return "- [\(idx)] **\(article.title)** — \(entry.reason)"
        }
        guard !lines.isEmpty else {
            throw NativeAIError.unavailable("Foundation Models returned no triage picks.")
        }
        return lines.joined(separator: "\n")
    }

    /// Uses Foundation Models guided generation for structured catch-up items.
    /// Bypasses `repairTriageJSON` — guided generation guarantees valid output.
    @available(iOS 26.0, macOS 26.0, *)
    static func quickCatchUpStructuredFM(articles: [Article]) async throws -> [CatchUpItem] {
        let model = SystemLanguageModel(useCase: .general)
        guard case .available = model.availability else {
            throw NativeAIError.unavailable("Apple Intelligence is not available.")
        }
        let session = LanguageModelSession(
            model: model,
            instructions: "You write crisp catch-up summaries for a news/RSS reader."
        )
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
            "Your Claude session has expired. Sign in again in Settings."
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
    @State private var isLoading = true
    @State private var result = ""
    @State private var referencedArticles: [Article] = []
    @State private var errorMessage: String?

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
                        Text(errorMessage)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Color.red.opacity(0.92))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                        if let continueInChat = request.continueInChat, !isLoading, errorMessage == nil {
                            Button {
                                let captured = result
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    continueInChat(captured)
                                }
                            } label: {
                                Label("Chat", systemImage: "bubble.left")
                            }
                        }
                        if let clearAction = request.clearAction {
                            Button("Clear", role: .destructive) {
                                clearAction()
                                dismiss()
                            }
                            .disabled(isLoading)
                        } else {
                            Button("Run Again") { Task { await run() } }
                                .disabled(isLoading)
                        }
                    }
                }
            }
            .task { await run() }
        }
    }

    private func run() async {
        isLoading = true
        errorMessage = nil
        result = ""
        referencedArticles = []
        do {
            let answer: AIResultAnswer
            if let streamAction = request.streamAction {
                // Streaming path: tokens arrive progressively; show them as they land.
                answer = try await streamAction { @MainActor chunk in
                    result += chunk
                }
                // Use the canonical final text from the answer (sanitized by the runner).
                result = answer.text
            } else {
                answer = try await request.action()
                result = answer.text
            }
            referencedArticles = ArticleReferenceExtractor.references(in: answer.text, articles: answer.articles)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
        if let parsed = try? AttributedString(markdown: text) {
            return parsed
        }
        return AttributedString(text)
    }
}

struct AIChatSheet: View {
    var request: AIChatRequest
    @Environment(\.dismiss) private var dismiss
    @Binding private var messages: [AIChatMessage]
    @State private var input = ""
    @State private var isSending = false
    @State private var showReauth = false
    @FocusState private var focused: Bool
    private var initialAssistantMessage: String?
    private let bottomAnchorID = "chat-bottom-anchor"

    init(request: AIChatRequest, messages: Binding<[AIChatMessage]>, initialAssistantMessage: String? = nil) {
        self.request = request
        _messages = messages
        self.initialAssistantMessage = initialAssistantMessage
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if messages.isEmpty {
                                ContentUnavailableView("Ask Skim", systemImage: "bubble.left.and.text.bubble.right", description: Text(request.placeholder))
                                    .foregroundStyle(SkimStyle.secondary)
                                    .padding(.top, 80)
                            } else {
                                ForEach(messages) { message in
                                    AIChatBubble(message: message, onReauth: { showReauth = true })
                                        .id(message.id)
                                }
                                AIDisclaimerLabel()
                                    .padding(.top, 4)
                            }

                            if isSending {
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

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                        }
                        .padding(18)
                    }
                    .onChange(of: messages.count) { _, _ in
                        scrollToLatest(proxy)
                    }
                    .onChange(of: isSending) { _, _ in
                        scrollToLatest(proxy)
                    }
                }

                HStack(spacing: 10) {
                    TextField("Ask...", text: $input, axis: .vertical)
                        .focused($focused)
                        .lineLimit(1...4)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(SkimStyle.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(SkimStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? SkimStyle.secondary : SkimStyle.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
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
            }
            .onAppear {
                seedInitialMessageIfNeeded()
                focused = true
            }
            .sheet(isPresented: $showReauth) {
                ClaudeReauthSheet()
            }
        }
    }

    private func seedInitialMessageIfNeeded() {
        guard messages.isEmpty,
              let seed = initialAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !seed.isEmpty
        else { return }
        messages = [AIChatMessage(role: .assistant, text: seed)]
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.smooth(duration: 0.22)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func send() async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        let toSend = question
        let priorMessages = messages
        let conversation = AIChatConversation(latestQuestion: toSend, priorMessages: priorMessages)
        input = ""
        focused = true
        messages.append(AIChatMessage(role: .user, text: toSend))
        isSending = true
        do {
            let answer = try await request.answer(conversation)
            messages.append(
                AIChatMessage(
                    role: .assistant,
                    text: answer.text,
                    referencedArticles: ArticleReferenceExtractor.references(in: answer.text, articles: answer.articles)
                )
            )
        } catch {
            let reauth: Bool = {
                if case NativeAIError.requiresReauthentication = error { return true }
                return false
            }()
            messages.append(AIChatMessage(role: .assistant, text: error.localizedDescription, isError: true, needsReauth: reauth))
        }
        isSending = false
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
    var referencedArticles: [Article] = []
    var isError = false
    var needsReauth = false
}

private struct AIChatBubble: View {
    var message: AIChatMessage
    var onReauth: (() -> Void)? = nil

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 42)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(message.text)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(message.isError ? Color.red.opacity(0.95) : SkimStyle.text)
                    .lineSpacing(4)
                    .textSelection(.enabled)

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

                if !message.referencedArticles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(message.referencedArticles) { article in
                            NavigationLink(value: article.id) {
                                ChatArticleReferenceRow(article: article)
                            }
                            .buttonStyle(.plain)
                        }
                    }
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

private enum ArticleReferenceExtractor {
    static func references(in text: String, articles: [Article]) -> [Article] {
        var references: [Article] = []
        var seenIDs: Set<String> = []

        for index in numericHandles(in: text) {
            let zeroBased = index - 1
            guard articles.indices.contains(zeroBased) else { continue }
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
        let pattern = #"\[(\d{1,3})\]"#
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
