import Testing
@testable import SkimInferencePolicy

@Test func familiesUseExpectedTurnTerminatorsAndThinkingFlags() {
    let cases: [(String, MLXModelFamily, Set<String>, Bool)] = [
        ("mlx-community/gemma-3-1b-it-4bit", .gemma, ["<end_of_turn>", "<eos>"], false),
        ("mlx-community/Llama-3.2-1B-Instruct-4bit", .llama, ["<|eot_id|>", "<|end_of_text|>"], false),
        ("mlx-community/Qwen3-1.7B-4bit", .qwen, ["<|im_end|>", "<|endoftext|>"], true),
        ("mlx-community/Phi-4-mini-instruct-4bit", .phi, ["<|end|>", "<|endoftext|>"], false),
        ("mlx-community/SmolLM3-3B-4bit", .smol, ["<|im_end|>", "<|endoftext|>"], true),
        ("other/unknown", .unknown, [], false)
    ]
    for (repo, expected, terminators, thinking) in cases {
        let family = MLXModelFamily.detect(from: repo)
        #expect(family == expected)
        #expect(family.extraEOSTokens == terminators)
        #expect(family.supportsThinkingToggle == thinking)
    }
    #expect(MLXModelFamily.detect(from: "ORG/QWEN3") == .qwen)
}

@Test func samplingPresetsPreserveShippingNativeValues() {
    let cases: [(String, Float, Float, Float)] = [
        ("gemma-3-1b-it-4bit", 0.3, 0.95, 1.15),
        ("gemma-3-4b-it-4bit", 0.35, 0.95, 1.1),
        ("Llama-3.2-1B-Instruct-4bit", 0.3, 0.9, 1.15),
        ("Llama-3.2-3B-Instruct-4bit", 0.3, 0.9, 1.1),
        ("Qwen3-1.7B-4bit", 0.3, 0.9, 1.1),
        ("Qwen3-4B-Instruct-2507-4bit", 0.3, 0.9, 1.05),
        ("SmolLM3-3B-4bit", 0.3, 0.95, 1.1),
        ("Phi-4-mini-instruct-4bit", 0.3, 0.95, 1.1),
        ("gemma-3n-E2B-it-lm-4bit", 0.35, 0.95, 1.1)
    ]
    #expect(MLXSamplingPreset.presets.count == cases.count)
    for (repo, temperature, topP, repetition) in cases {
        #expect(MLXSamplingPreset.preset(for: "mlx-community/\(repo)") == MLXSamplingPreset(
            temperature: temperature, topP: topP, repetitionPenalty: repetition, repetitionContextSize: 64))
    }
    #expect(MLXSamplingPreset.preset(for: "other/unknown") == MLXSamplingPreset.fallback)
}

@Test func completedThinkingIsRemovedBeforeJSONParsing() {
    let answer = LocalModelOutput.sanitize("<think>Compare reports.\nConsider {not JSON}.</think>\n{\"groups\":[]}<|im_end|>", family: .qwen)
    #expect(answer == "{\"groups\":[]}")
    #expect(LocalModelOutput.sanitize("<think></think> Answer <end_of_turn><eos>", family: .gemma) == "Answer")
}

@Test func truncatedThinkingCannotBecomeUserVisibleAnswer() {
    #expect(LocalModelOutput.sanitize("<think>Still reasoning about {JSON", family: .qwen).isEmpty)
    #expect(LocalModelOutput.sanitize("Answer\n<think>Unfinished", family: .smol) == "Answer\n<think>Unfinished")
}

@Test func ordinaryCodeHTMLAndComparisonsSurviveCleanup() {
    let text = "Use Array<String>, render <div>news</div>, and check 1 < 2 && 3 > 2."
    #expect(LocalModelOutput.sanitize(text, family: .gemma) == text)
    let json = #"{"code":"List<Int>","html":"<p>News</p>","comparison":"x < y > z"}"#
    #expect(LocalModelOutput.sanitize(json + "<|im_end|>", family: .qwen) == json)
}

@Test func onlyLeadingReasoningBlocksAreProtocol() {
    #expect(LocalModelOutput.sanitize(" \n<think>First</think> \n<think>Second</think> Answer", family: .qwen) == "Answer")
    #expect(LocalModelOutput.sanitize(" \n<think>First</think> \n<think>Unfinished", family: .qwen).isEmpty)
    let prose = "The literal <think>example</think> belongs to this answer."
    #expect(LocalModelOutput.sanitize(prose, family: .qwen) == prose)
    let code = "```xml\n<think>example</think>\n<|im_end|>\n```"
    #expect(LocalModelOutput.sanitize(code, family: .qwen) == code)
}

@Test func literalProtocolTokensInsideJSONRemainUnchanged() {
    let json = #"{"open":"<think>","close":"</think>","stop":"<|im_end|>","text":"<think>literal</think>"}"#
    #expect(LocalModelOutput.sanitize(json, family: .qwen) == json)
    #expect(LocalModelOutput.sanitize("<think>Reasoning</think>" + json + "<|im_end|>", family: .qwen) == json)
    let unfinishedLiteral = #"{"example":"<think>unfinished","stop":"<eos>"}"#
    #expect(LocalModelOutput.sanitize(unfinishedLiteral, family: .gemma) == unfinishedLiteral)
}

@Test func onlyTrailingFamilyTerminatorsAreRemoved() {
    let text = "The tokens <eos> and <end_of_turn> are literal examples."
    #expect(LocalModelOutput.sanitize(text + " <end_of_turn> \n<eos> ", family: .gemma) == text)
    #expect(LocalModelOutput.sanitize("Answer<|im_end|>", family: .gemma) == "Answer<|im_end|>")
}
