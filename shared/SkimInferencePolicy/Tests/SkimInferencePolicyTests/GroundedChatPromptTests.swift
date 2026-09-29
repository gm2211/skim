import Testing
@testable import SkimInferencePolicy

// MARK: - LocalModelTier.tier(for:)

@Test func tierParsingCoversAllShippedRepoIds() {
    // Every repo id from LocalModelPolicy.presets and from
    // native/SkimNative/SkimIOS/Support/NativeMLX.swift's modelOptions.
    let expectations: [(repoId: String, tier: LocalModelTier)] = [
        ("mlx-community/gemma-3-1b-it-4bit", .compact),
        ("mlx-community/gemma-3-4b-it-4bit", .mid),
        ("mlx-community/Llama-3.2-1B-Instruct-4bit", .compact),
        ("mlx-community/Llama-3.2-3B-Instruct-4bit", .mid),
        ("mlx-community/Qwen3-1.7B-4bit", .compact),
        ("mlx-community/Qwen3-4B-Instruct-2507-4bit", .mid),
        ("mlx-community/Qwen3-8B-4bit", .large),
        ("mlx-community/Qwen3-30B-A3B-4bit", .large),
        ("mlx-community/LFM2-1.2B-4bit", .compact),
        ("mlx-community/SmolLM3-3B-4bit", .mid),
        // No <digits>B token before the "4bit" quantization suffix; falls
        // through to matching that suffix as "4B" -> .mid. See the doc
        // comment on LocalModelTier.tier(for:) for the rationale — this
        // happens to be the correct bucket for the real ~3.8B model.
        ("mlx-community/Phi-4-mini-instruct-4bit", .mid),
        ("mlx-community/gemma-3n-E2B-it-lm-4bit", .compact),
    ]
    for (repoId, expected) in expectations {
        #expect(LocalModelTier.tier(for: repoId) == expected, "\(repoId) should be \(expected)")
    }
}

@Test func tierParsingUnparseableRepoIdDefaultsToCompact() {
    #expect(LocalModelTier.tier(for: "mlx-community/some-custom-checkpoint") == .compact)
}

@Test func tierParsingHandlesLowercaseB() {
    #expect(LocalModelTier.tier(for: "mlx-community/tiny-1b-model") == .compact)
}

// MARK: - ChatContextBudget

@Test func chatContextBudgetScalesByTier() {
    let compact = ChatContextBudget.forTier(.compact)
    let mid = ChatContextBudget.forTier(.mid)
    let large = ChatContextBudget.forTier(.large)
    #expect(compact == ChatContextBudget(evidenceChars: 5000, routerChars: 2000, webEvidenceChars: 3000, maxTokens: 360))
    #expect(mid == ChatContextBudget(evidenceChars: 8000, routerChars: 2400, webEvidenceChars: 4200, maxTokens: 500))
    #expect(large == ChatContextBudget(evidenceChars: 12000, routerChars: 2400, webEvidenceChars: 4200, maxTokens: 650))
}

// MARK: - samplingPreset(basedOn:)

@Test func samplingPresetCapsRepetitionPenaltyAndFixesTemperature() {
    let hotPreset = MLXSamplingPreset(temperature: 0.35, topP: 0.95, repetitionPenalty: 1.15, repetitionContextSize: 64)
    let tuned = GroundedChatPrompt.samplingPreset(basedOn: hotPreset)
    #expect(tuned.temperature == 0.2)
    #expect(tuned.topP == 0.9)
    #expect(tuned.repetitionPenalty == 1.1)
    #expect(tuned.repetitionContextSize == 64)

    let mildPreset = MLXSamplingPreset(temperature: 0.3, topP: 0.9, repetitionPenalty: 1.05, repetitionContextSize: 64)
    let tunedMild = GroundedChatPrompt.samplingPreset(basedOn: mildPreset)
    #expect(tunedMild.repetitionPenalty == 1.05)
}

// MARK: - systemPrompt(question:oneShot:)

@Test func systemPromptUsesShortLimitByDefault() {
    let prompt = GroundedChatPrompt.systemPrompt(question: "What happened to the mosquito?")
    #expect(prompt.contains("at most 3 more sentences"))
    #expect(!prompt.lowercased().contains("up to 8 sentences"))
}

@Test func systemPromptLongVariantTriggeredByList() {
    let prompt = GroundedChatPrompt.systemPrompt(question: "Can you list the steps in the process?")
    #expect(prompt.lowercased().contains("up to 8 sentences or a short list"))
    #expect(!prompt.contains("at most 3 more sentences"))
}

@Test func systemPromptLongVariantTriggeredByEachKeyword() {
    for question in [
        "Please explain how it works",
        "Give me all the details",
        "What were the steps taken",
        "Why did this happen",
        "Can you summarize the findings",
    ] {
        let prompt = GroundedChatPrompt.systemPrompt(question: question)
        #expect(prompt.lowercased().contains("up to 8 sentences"), "question: \(question)")
    }
}

@Test func systemPromptDoesNotFalsePositiveOnUnrelatedWords() {
    let prompt = GroundedChatPrompt.systemPrompt(question: "Who called the meeting?")
    #expect(prompt.contains("at most 3 more sentences"))
}

@Test func systemPromptOneShotAppendsExample() {
    let withExample = GroundedChatPrompt.systemPrompt(question: "What happened?", oneShot: true)
    let without = GroundedChatPrompt.systemPrompt(question: "What happened?", oneShot: false)
    #expect(withExample.contains("Example"))
    #expect(withExample.count > without.count)
}

// MARK: - build(system:articleContext:question:priorExchange:webBlock:)

@Test func buildReturnsExactlySystemAndUserRoles() {
    let messages = GroundedChatPrompt.build(
        system: "SYSTEM",
        articleContext: "Scientists used a dead mosquito's proboscis as a 3D-printing nozzle.",
        question: "Making nozzles out of dead things?"
    )
    #expect(messages.map { $0.role } == ["system", "user"])
    #expect(messages[0].content == "SYSTEM")
}

@Test func buildUserContentEndsWithQuestionAfterArticle() {
    let messages = GroundedChatPrompt.build(
        system: "SYSTEM",
        articleContext: "Article text here.",
        question: "Making nozzles out of dead things?"
    )
    let user = messages[1].content
    guard let articleEnd = user.range(of: "END OF ARTICLE") else {
        Issue.record("missing END OF ARTICLE marker")
        return
    }
    let tail = user[articleEnd.upperBound...]
    #expect(tail.contains("Question: Making nozzles out of dead things?"))
    #expect(user.hasSuffix("Question: Making nozzles out of dead things?\nAnswer the question above directly, using the article."))
    #expect(!user.contains("generated_summary"))
}

@Test func buildIncludesWebBlockWhenProvided() {
    let messages = GroundedChatPrompt.build(
        system: "SYSTEM",
        articleContext: "Article text.",
        question: "What happened?",
        webBlock: "Additional web-sourced fact."
    )
    #expect(messages[1].content.contains("Additional web-sourced fact."))
}

@Test func buildOmitsWebBlockWhenNilOrBlank() {
    let messagesNil = GroundedChatPrompt.build(system: "SYSTEM", articleContext: "Article.", question: "Q?", webBlock: nil)
    let messagesBlank = GroundedChatPrompt.build(system: "SYSTEM", articleContext: "Article.", question: "Q?", webBlock: "   ")
    #expect(!messagesNil[1].content.contains("WEB"))
    #expect(!messagesBlank[1].content.contains("WEB"))
}

@Test func buildIncludesPriorExchangeWithDefaultLabel() {
    let messages = GroundedChatPrompt.build(
        system: "SYSTEM",
        articleContext: "Article.",
        question: "Follow-up question?",
        priorExchange: (question: "Earlier question?", answer: "Earlier answer.", label: "")
    )
    let user = messages[1].content
    #expect(user.contains("Earlier in this chat (for reference only):"))
    #expect(user.contains("Q: Earlier question?"))
    #expect(user.contains("A: Earlier answer."))
}

@Test func buildIncludesPriorExchangeWithCustomLabel() {
    let messages = GroundedChatPrompt.build(
        system: "SYSTEM",
        articleContext: "Article.",
        question: "Follow-up question?",
        priorExchange: (question: "Earlier question?", answer: "Earlier answer.", label: "Earlier summary")
    )
    #expect(messages[1].content.contains("Earlier summary: Earlier answer."))
}

@Test func buildTruncatesPriorExchangeTo300Characters() {
    let longQuestion = String(repeating: "q", count: 500)
    let longAnswer = String(repeating: "a", count: 500)
    let messages = GroundedChatPrompt.build(
        system: "SYSTEM",
        articleContext: "Article.",
        question: "Follow-up?",
        priorExchange: (question: longQuestion, answer: longAnswer, label: "")
    )
    let user = messages[1].content
    #expect(user.contains("Q: " + String(repeating: "q", count: 300)))
    #expect(!user.contains(String(repeating: "q", count: 301)))
    #expect(user.contains("A: " + String(repeating: "a", count: 300)))
    #expect(!user.contains(String(repeating: "a", count: 301)))
}
