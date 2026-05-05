import SkimCore
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AIResultRequest: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var action: () async throws -> String
}

struct AIChatRequest: Identifiable {
    let id = UUID()
    var title: String
    var placeholder: String
    var answer: (String) async throws -> String
}

enum NativeAI {
    static func quickCatchUp(articles: [Article]) async throws -> String {
        try await complete(
            instructions: "You write crisp catch-up reports for a news/RSS reader. Be useful, specific, and concise.",
            prompt: """
            Create a Super Quick Catch-up from these articles. Group related items into themes, name what matters, and keep it scannable.

            \(articleDigest(articles, limit: 35))
            """,
            maxTokens: 700
        )
    }

    static func aiInbox(articles: [Article]) async throws -> String {
        try await complete(
            instructions: "You triage RSS articles for a smart inbox. Pick what seems most worth reading and explain why.",
            prompt: """
            Rank the most interesting articles from this list. Return 8-12 picks with a short reason for each. Favor novelty, depth, engineering relevance, and things a curious technical reader would not want to miss.

            \(articleDigest(articles, limit: 45))
            """,
            maxTokens: 750
        )
    }

    static func summarize(article: Article) async throws -> String {
        try await complete(
            instructions: "You summarize articles accurately. Preserve nuance, avoid hype, and mention uncertainty when the source is thin.",
            prompt: """
            Summarize this article in one concise paragraph, then give 3 bullet takeaways.

            \(articleDigest([article], limit: 1))
            """,
            maxTokens: 420
        )
    }

    static func chat(question: String, article: Article) async throws -> String {
        try await complete(
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

    static func chat(question: String, articles: [Article]) async throws -> String {
        try await complete(
            instructions: "You answer questions across a set of RSS articles. Cite article titles naturally when using them.",
            prompt: """
            Articles:
            \(articleDigest(articles, limit: 35))

            Question:
            \(question)
            """,
            maxTokens: 850
        )
    }

    static func complete(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
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

struct AIResultSheet: View {
    var request: AIResultRequest
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var result = ""
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
                            Text("Asking Apple Foundation Models...")
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
                        Text(result)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(SkimStyle.text)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                }
                .padding(24)
            }
            .background(SkimStyle.background.ignoresSafeArea())
            .navigationTitle(request.title)
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
        do {
            result = try await request.action()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct AIChatSheet: View {
    var request: AIChatRequest
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [AIChatMessage] = []
    @State private var input = ""
    @State private var isSending = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty {
                            ContentUnavailableView("Ask Skim", systemImage: "bubble.left.and.text.bubble.right", description: Text(request.placeholder))
                                .foregroundStyle(SkimStyle.secondary)
                                .padding(.top, 80)
                        } else {
                            ForEach(messages) { message in
                                AIChatBubble(message: message)
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
                    }
                    .padding(18)
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
            .background(SkimStyle.background.ignoresSafeArea())
            .navigationTitle(request.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { focused = true }
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
            messages.append(AIChatMessage(role: .assistant, text: answer))
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
    var isError = false
}

private struct AIChatBubble: View {
    var message: AIChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 42)
            }

            Text(message.text)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(message.isError ? Color.red.opacity(0.95) : SkimStyle.text)
                .lineSpacing(4)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .background(
                    message.role == .user ? SkimStyle.accent.opacity(0.28) : SkimStyle.surface,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .textSelection(.enabled)

            if message.role == .assistant {
                Spacer(minLength: 42)
            }
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
