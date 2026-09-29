import Foundation

/// A rough size bucket for an on-device MLX model, used to scale context
/// budgets and sampling for grounded chat-with-article prompting.
public enum LocalModelTier: Sendable, Equatable {
    case compact
    case mid
    case large

    /// Parses the first `<digits>[.<digits>]B` (billions of parameters)
    /// token in a repo id, with an optional leading `E` (as in
    /// `gemma-3n-E2B`), case-insensitively, and buckets it into a tier:
    /// `<= 2.0` compact, `<= 4.5` mid, else large.
    ///
    /// A repo id whose only size-shaped digit run is its quantization
    /// suffix (e.g. `mlx-community/Phi-4-mini-instruct-4bit`, which has no
    /// earlier `<digits>B` token) falls through to matching that "4bit"
    /// suffix as if it were "4B". This is a known quirk of the simple regex
    /// approach, but it happens to land Phi-4-mini (a real ~3.8B model) in
    /// `.mid`, the correct bucket, by coincidence. A repo id with no
    /// size-shaped token at all (unparseable) defaults to `.compact`, the
    /// smallest/safest budget.
    public static func tier(for repoId: String) -> LocalModelTier {
        guard let billions = parseBillions(repoId) else { return .compact }
        if billions <= 2.0 { return .compact }
        if billions <= 4.5 { return .mid }
        return .large
    }

    private static func parseBillions(_ repoId: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "[Ee]?(\\d+(?:\\.\\d+)?)[Bb]") else { return nil }
        let range = NSRange(repoId.startIndex..., in: repoId)
        guard let match = regex.firstMatch(in: repoId, range: range),
              let captureRange = Range(match.range(at: 1), in: repoId) else { return nil }
        return Double(repoId[captureRange])
    }
}

/// Character/token budgets for grounded chat-with-article prompting,
/// scaled by model tier so small on-device models aren't handed more
/// context than they can actually use well.
public struct ChatContextBudget: Sendable, Equatable {
    public let evidenceChars: Int
    public let routerChars: Int
    public let webEvidenceChars: Int
    public let maxTokens: Int

    public init(evidenceChars: Int, routerChars: Int, webEvidenceChars: Int, maxTokens: Int) {
        self.evidenceChars = evidenceChars
        self.routerChars = routerChars
        self.webEvidenceChars = webEvidenceChars
        self.maxTokens = maxTokens
    }

    public static func forTier(_ tier: LocalModelTier) -> ChatContextBudget {
        switch tier {
        case .compact:
            return ChatContextBudget(evidenceChars: 5000, routerChars: 2000, webEvidenceChars: 3000, maxTokens: 360)
        case .mid:
            return ChatContextBudget(evidenceChars: 8000, routerChars: 2400, webEvidenceChars: 4200, maxTokens: 500)
        case .large:
            return ChatContextBudget(evidenceChars: 12000, routerChars: 2400, webEvidenceChars: 4200, maxTokens: 650)
        }
    }
}

/// Builds a grounded, answer-first chat prompt for asking a local model a
/// question about one news article, plus the sampling settings tuned for
/// that use case.
public enum GroundedChatPrompt {
    private static let longFormPattern = "\\b(list|explain|detail|all|steps|why|summar)"

    /// The system instructions: answer-first, grounded strictly in the
    /// article, no chatbot preamble/headings/whole-article-summary. Uses a
    /// longer allowance (up to 8 sentences or a short list) when the
    /// question itself asks for something broader (list/explain/detail/
    /// all/steps/why/summar[y|ize]).
    public static func systemPrompt(question: String, oneShot: Bool = false) -> String {
        let limit = matches(question, pattern: longFormPattern)
            ? "up to 8 sentences or a short list"
            : "at most 3 more sentences"
        var prompt = "You answer a reader's question about one news article. Use only the article text provided. "
            + "First sentence: the direct answer to the question. Then \(limit) with specifics from the article "
            + "(names, numbers, places, what exactly was done). If the article does not answer it, say "
            + "\"The article doesn't say.\" No greeting, no preamble, no headings, do not summarize the whole article."
        if oneShot {
            prompt += "\n\n"
                + "Example — Article: \"The city council approved a $2M renovation of Miller Park on Tuesday, adding a splash pad and repaving two courts.\"\n"
                + "Question: \"What did the council approve?\" Answer: \"The council approved a $2M renovation of Miller Park, adding a splash pad and repaving two courts.\""
        }
        return prompt
    }

    /// Builds the exact two-turn `[system, user]` message array sent to the
    /// model. `priorExchange.label` replaces the default "A:" label (e.g.
    /// "Earlier summary") when the prior turn wasn't a plain chat answer.
    /// `priorExchange` question/answer and are each truncated to 300 chars.
    public static func build(
        system: String,
        articleContext: String,
        question: String,
        priorExchange: (question: String, answer: String, label: String)? = nil,
        webBlock: String? = nil
    ) -> [LocalChatMessage] {
        var user = "ARTICLE:\n\(articleContext)\nEND OF ARTICLE"

        if let webBlock, !webBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user += "\n\nADDITIONAL CONTEXT FROM THE WEB:\n\(webBlock)"
        }

        if let priorExchange {
            let label = priorExchange.label.isEmpty ? "A" : priorExchange.label
            let truncatedQuestion = truncate(priorExchange.question, to: 300)
            let truncatedAnswer = truncate(priorExchange.answer, to: 300)
            user += "\n\nEarlier in this chat (for reference only):\nQ: \(truncatedQuestion)\n\(label): \(truncatedAnswer)"
        }

        user += "\n\nQuestion: \(question)\nAnswer the question above directly, using the article."

        return [
            LocalChatMessage(role: "system", content: system),
            LocalChatMessage(role: "user", content: user),
        ]
    }

    /// Chat-tuned sampling: lower, steadier temperature than the model's
    /// general-purpose preset, and a repetition penalty capped at 1.1 (some
    /// presets run hotter than that, which over-penalizes short, factual,
    /// naturally repetitive answers like "The council approved... The
    /// council's approval...").
    public static func samplingPreset(basedOn preset: MLXSamplingPreset) -> MLXSamplingPreset {
        MLXSamplingPreset(
            temperature: 0.2,
            topP: 0.9,
            repetitionPenalty: min(preset.repetitionPenalty, 1.1),
            repetitionContextSize: preset.repetitionContextSize
        )
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
