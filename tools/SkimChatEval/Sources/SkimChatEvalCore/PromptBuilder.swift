import Foundation
import SkimCore
import SkimInferencePolicy

public struct BuiltPrompt: Sendable {
    public let messages: [LocalChatMessage]
    public let maxTokens: Int
    public let temperature: Float
    public let evidenceQuery: String
    public let evidenceMaxCharacters: Int
}

/// Builds the exact chat messages sent to a local model for one eval case,
/// in either of two layouts:
///
/// - New prompt (default): `GroundedChatPrompt` (answer-first system
///   instructions, `[system, user]` turns, tier-scaled evidence budget via
///   `expandedQuery`, tier-scaled `maxTokens`), matching the bd skim-p9ol
///   prompt work on `SkimInferencePolicy`.
/// - `--legacy-prompt`: the pre-existing production layout — a long
///   instructions system prompt with the article context and an optional
///   `generatedSummaryContext`-style block appended inline, one message per
///   prior turn, a fixed 12000-character evidence budget and a fixed
///   650-token cap. See `native/SkimNative/SkimIOS/Support/NativeAI.swift`
///   `buildLocalChatMessages`/`chatInstructions` and
///   `SkimCore.AIRequestPolicy.generatedSummaryContext`.
public enum ChatEvalPromptBuilder {
    /// Byte-identical to `NativeAI.chatInstructions(isLibrary: false, enableWebSearch: false)`.
    private static let legacySingleArticleInstructions =
        "You answer questions about a single article using the provided article text and any supplied web search results. "
        + "Use previous turns only to resolve references like 'that' or 'the second one'; prior assistant turns are context, not evidence. "
        + "Answer only the latest user question. Do not repeat a prior answer unless the latest question explicitly asks you to recap it. "
        + "If the answer is not supported by the supplied article text or web results, say so."

    private static let legacyEvidenceCharacters = 12000
    private static let legacyMaxTokens = 650

    public static func build(
        for testCase: ChatEvalCase,
        repoId: String,
        oneShot: Bool,
        legacyPrompt: Bool
    ) -> BuiltPrompt {
        let tier = LocalModelTier.tier(for: repoId)
        let budget = ChatContextBudget.forTier(tier)
        return legacyPrompt
            ? buildLegacy(for: testCase, budget: budget)
            : buildGrounded(for: testCase, budget: budget, oneShot: oneShot)
    }

    private static func buildGrounded(for testCase: ChatEvalCase, budget: ChatContextBudget, oneShot: Bool) -> BuiltPrompt {
        let query = ChatEvidencePolicy.expandedQuery(testCase.question)
        let articleContext = ChatEvidencePolicy.articleContext(
            title: testCase.title,
            feedTitle: testCase.feed,
            author: nil,
            publishedAt: nil,
            body: testCase.body,
            query: query,
            maxCharacters: budget.evidenceChars
        )
        let system = GroundedChatPrompt.systemPrompt(question: testCase.question, oneShot: oneShot)

        // GroundedChatPrompt.build only carries a single prior exchange.
        // Prefer an explicit prior turn (follow-up case); otherwise, when
        // the case simulates "chat opened from a generated summary", pass
        // the summary as a prior exchange labeled "Earlier summary" per the
        // doc comment on `GroundedChatPrompt.build`.
        let priorExchange: (question: String, answer: String, label: String)?
        if let lastTurn = testCase.priorTurns?.last {
            priorExchange = (question: lastTurn.question, answer: lastTurn.answer, label: "")
        } else if let summary = testCase.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            priorExchange = (question: "", answer: summary, label: "Earlier summary")
        } else {
            priorExchange = nil
        }

        let messages = GroundedChatPrompt.build(
            system: system,
            articleContext: articleContext,
            question: testCase.question,
            priorExchange: priorExchange,
            webBlock: nil
        )
        return BuiltPrompt(
            messages: messages,
            maxTokens: budget.maxTokens,
            temperature: 0,
            evidenceQuery: query,
            evidenceMaxCharacters: budget.evidenceChars
        )
    }

    private static func buildLegacy(for testCase: ChatEvalCase, budget: ChatContextBudget) -> BuiltPrompt {
        let query = testCase.question
        let articleContext = ChatEvidencePolicy.articleContext(
            title: testCase.title,
            feedTitle: testCase.feed,
            author: nil,
            publishedAt: nil,
            body: testCase.body,
            query: query,
            maxCharacters: legacyEvidenceCharacters
        )

        let systemContent = legacySingleArticleInstructions + "\n\nArticle:\n\(articleContext)"
        var messages: [LocalChatMessage] = [LocalChatMessage(role: "system", content: systemContent)]
        for turn in testCase.priorTurns ?? [] {
            messages.append(LocalChatMessage(role: "user", content: turn.question))
            messages.append(LocalChatMessage(role: "assistant", content: turn.answer))
        }
        let finalContent = [AIRequestPolicy.generatedSummaryContext(testCase.summary), testCase.question]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        messages.append(LocalChatMessage(role: "user", content: finalContent))

        return BuiltPrompt(
            messages: messages,
            maxTokens: legacyMaxTokens,
            temperature: 0,
            evidenceQuery: query,
            evidenceMaxCharacters: legacyEvidenceCharacters
        )
    }
}
