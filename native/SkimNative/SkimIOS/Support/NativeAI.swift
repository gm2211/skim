import SkimCore
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AIResultRequest: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var statusLabel = "Running AI..."
    var action: () async throws -> AIResultAnswer
}

struct AIResultAnswer {
    var text: String
    var articles: [Article]
}

struct AIChatRequest: Identifiable {
    let id = UUID()
    var title: String
    var placeholder: String
    var answer: (String) async throws -> AIChatAnswer
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

    static func quickCatchUp(articles: [Article], settings: AppSettings) async throws -> String {
        try await complete(
            settings: settings,
            instructions: """
            You write crisp catch-up reports for a news/RSS reader. Be useful, specific, and concise. Use Markdown headings and bullets. Whenever you mention a specific article, cite it with its numeric handle like [3] and its title so the app can make it clickable.
            """,
            prompt: """
            Create a Super Quick Catch-up from these articles. Group related items into themes, name what matters, and keep it scannable.

            \(articleDigest(articles, limit: 35))
            """,
            maxTokens: 700
        )
    }

    static func aiInbox(articles: [Article], settings: AppSettings) async throws -> String {
        try await complete(
            settings: settings,
            instructions: """
            You triage RSS articles for a smart inbox. Pick what seems most worth reading and explain why. Use Markdown bullets. Cite every selected article with its numeric handle like [3] and title so the app can make it clickable.
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

    static func summarize(article: Article, settings: AppSettings) async throws -> String {
        try await complete(
            settings: settings,
            instructions: summaryInstructions(settings.ai),
            prompt: """
            Summarize this article. Target length: \(summaryLengthDescription(settings.ai)).

            \(articleDigest([article], limit: 1))
            """,
            maxTokens: summaryMaxTokens(settings.ai)
        )
    }

    static func chat(question: String, article: Article, settings: AppSettings) async throws -> String {
        try await complete(
            settings: settings,
            instructions: "You answer questions about a single article using only the provided article text. If the answer is not in the article, say so.",
            prompt: """
            Article:
            \(articleDigest([article], limit: 1))

            Question:
            \(question)
            """,
            maxTokens: 650
        )
    }

    static func chat(question: String, articles: [Article], settings: AppSettings) async throws -> String {
        try await complete(
            settings: settings,
            instructions: """
            You answer questions across a set of RSS articles. When mentioning, ranking, recommending, or listing articles, cite each article with its numeric handle like [3] and its title. Keep handles attached to the relevant sentence or bullet so the app can make them clickable.
            """,
            prompt: """
            Articles:
            \(articleDigest(articles, limit: 35))

            Question:
            \(question)
            """,
            maxTokens: 850
        )
    }

    static func complete(
        settings: AppSettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        jsonMode: Bool = false
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
                    sampling: .greedy,
                    temperature: 0.2,
                    maximumResponseTokens: maxTokens
                )
            )
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
#endif
        throw NativeAIError.unavailable("Foundation Models are not available in this build.")
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
        let key = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let key else {
            throw NativeAIError.unavailable("Add a Claude API key or Claude subscription token in Settings.")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if settings.provider == "claude-subscription" {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20,claude-code-20250219", forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }

        let body: [String: Any] = [
            "model": settings.model?.nilIfEmpty ?? defaultModel(for: settings.provider),
            "system": instructions,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, provider: providerDisplayName(settings.provider))
        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        let content = decoded.content.compactMap(\.text).joined(separator: "\n").nilIfEmpty
        guard let content else {
            throw NativeAIError.unavailable("The Claude response was empty.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func summaryInstructions(_ settings: AISettings) -> String {
        let tone = settings.summaryTone?.nilIfEmpty ?? "concise"
        var instructions = "You summarize articles accurately in a \(tone) style. Preserve nuance, avoid hype, and mention uncertainty when the source is thin."
        if let custom = settings.summaryCustomPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            instructions += "\n\nUser summary instructions:\n\(custom)"
        }
        return instructions
    }

    private static func summaryLengthDescription(_ settings: AISettings) -> String {
        if let words = settings.summaryCustomWordCount, words > 0 {
            return "about \(words) words"
        }
        switch settings.summaryLength?.nilIfEmpty ?? "short" {
        case "tiny": return "1-2 sentences"
        case "medium": return "one paragraph plus 3 bullets"
        case "long": return "a detailed summary with key context"
        default: return "one concise paragraph plus 3 bullet takeaways"
        }
    }

    private static func summaryMaxTokens(_ settings: AISettings) -> Int {
        if let words = settings.summaryCustomWordCount, words > 0 {
            return max(160, min(1600, Int(Double(words) * 1.8)))
        }
        switch settings.summaryLength?.nilIfEmpty ?? "short" {
        case "tiny": return 180
        case "medium": return 520
        case "long": return 900
        default: return 420
        }
    }

    private static func articleDigest(_ articles: [Article], limit: Int) -> String {
        let selected = articles.prefix(limit)
        if selected.isEmpty {
            return "No articles are available."
        }

        return selected.enumerated().map { index, article in
            let text = article.plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = text.isEmpty ? "No reader text available." : text.prefixWords(95)
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
#endif
}

enum NativeAIError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            message
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

private struct AnthropicResponse: Decodable {
    struct ContentBlock: Decodable {
        var type: String?
        var text: String?
    }

    var content: [ContentBlock]
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

                    if isLoading {
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
                    Button("Run Again") { Task { await run() } }
                        .disabled(isLoading)
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
            let answer = try await request.action()
            result = answer.text
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
    @State private var messages: [AIChatMessage] = []
    @State private var input = ""
    @State private var isSending = false
    @FocusState private var focused: Bool
    private let bottomAnchorID = "chat-bottom-anchor"

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
                                    AIChatBubble(message: message)
                                        .id(message.id)
                                }
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
            .onAppear { focused = true }
        }
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
        input = ""
        messages.append(AIChatMessage(role: .user, text: question))
        isSending = true
        do {
            let answer = try await request.answer(question)
            messages.append(
                AIChatMessage(
                    role: .assistant,
                    text: answer.text,
                    referencedArticles: ArticleReferenceExtractor.references(in: answer.text, articles: answer.articles)
                )
            )
        } catch {
            messages.append(AIChatMessage(role: .assistant, text: error.localizedDescription, isError: true))
        }
        isSending = false
    }
}

private struct AIChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    var role: Role
    var text: String
    var referencedArticles: [Article] = []
    var isError = false
}

private struct AIChatBubble: View {
    var message: AIChatMessage

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
