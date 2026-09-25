import Foundation

// MARK: - Model family detection

public enum MLXModelFamily: Sendable {
    case gemma
    case llama
    case qwen
    case phi
    case smol
    case lfm
    case unknown

    /// Stop strings that mark end-of-turn for this model family.
    public var extraEOSTokens: Set<String> {
        switch self {
        case .gemma:
            return ["<end_of_turn>", "<eos>"]
        case .llama:
            return ["<|eot_id|>", "<|end_of_text|>"]
        case .qwen:
            return ["<|im_end|>", "<|endoftext|>"]
        case .phi:
            return ["<|end|>", "<|endoftext|>"]
        case .smol:
            return ["<|im_end|>", "<|endoftext|>"]
        case .lfm:
            return ["<|im_end|>", "<|endoftext|>"]
        case .unknown:
            return []
        }
    }

    /// Whether this family's chat template supports toggling "thinking"/reasoning
    /// output via the `enable_thinking` additionalContext flag.
    public var supportsThinkingToggle: Bool {
        switch self {
        case .qwen, .smol:
            return true
        default:
            return false
        }
    }

    public static func detect(from repoId: String) -> MLXModelFamily {
        let lower = repoId.lowercased()
        if lower.contains("smollm") { return .smol }
        if lower.contains("lfm2") { return .lfm }
        if lower.contains("gemma") { return .gemma }
        if lower.contains("llama") { return .llama }
        if lower.contains("qwen") { return .qwen }
        if lower.contains("phi") { return .phi }
        return .unknown
    }
}

// MARK: - Per-model sampling presets

public struct MLXSamplingPreset: Sendable, Equatable {
    public var temperature: Float
    public var topP: Float
    public var repetitionPenalty: Float
    public var repetitionContextSize: Int

    public init(temperature: Float, topP: Float, repetitionPenalty: Float, repetitionContextSize: Int) {
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
    }

    /// Known-good defaults keyed by repo id.
    public static let presets: [String: MLXSamplingPreset] = [
        // Gemma 3 1B
        "mlx-community/gemma-3-1b-it-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.95, repetitionPenalty: 1.15, repetitionContextSize: 64
        ),
        // Gemma 3 4B
        "mlx-community/gemma-3-4b-it-4bit": MLXSamplingPreset(
            temperature: 0.35, topP: 0.95, repetitionPenalty: 1.1, repetitionContextSize: 64
        ),
        // Llama 3.2 1B
        "mlx-community/Llama-3.2-1B-Instruct-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.9, repetitionPenalty: 1.15, repetitionContextSize: 64
        ),
        // Llama 3.2 3B
        "mlx-community/Llama-3.2-3B-Instruct-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.9, repetitionPenalty: 1.1, repetitionContextSize: 64
        ),
        // Qwen3 1.7B
        "mlx-community/Qwen3-1.7B-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.9, repetitionPenalty: 1.1, repetitionContextSize: 64
        ),
        // Qwen3 4B Instruct (2507)
        "mlx-community/Qwen3-4B-Instruct-2507-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.9, repetitionPenalty: 1.05, repetitionContextSize: 64
        ),
        // Qwen3 8B
        "mlx-community/Qwen3-8B-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.9, repetitionPenalty: 1.05, repetitionContextSize: 64
        ),
        // Qwen3 30B-A3B
        "mlx-community/Qwen3-30B-A3B-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.9, repetitionPenalty: 1.05, repetitionContextSize: 64
        ),
        // LFM2 1.2B (Liquid AI recommends a low temperature and light repetition penalty)
        "mlx-community/LFM2-1.2B-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.95, repetitionPenalty: 1.05, repetitionContextSize: 64
        ),
        // SmolLM3 3B
        "mlx-community/SmolLM3-3B-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.95, repetitionPenalty: 1.1, repetitionContextSize: 64
        ),
        // Phi-4 Mini
        "mlx-community/Phi-4-mini-instruct-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.95, repetitionPenalty: 1.1, repetitionContextSize: 64
        ),
        // Gemma 3n E2B
        "mlx-community/gemma-3n-E2B-it-lm-4bit": MLXSamplingPreset(
            temperature: 0.35, topP: 0.95, repetitionPenalty: 1.1, repetitionContextSize: 64
        ),
    ]

    public static let fallback = MLXSamplingPreset(
        temperature: 0.3, topP: 0.95, repetitionPenalty: 1.1, repetitionContextSize: 64
    )

    public static func preset(for repoId: String) -> MLXSamplingPreset {
        presets[repoId] ?? fallback
    }
}

/// Removes only leading reasoning blocks and trailing family turn terminators.
/// Tokens inside the answer remain literal content, including JSON and code.
public enum LocalModelOutput {
    public static func sanitize(_ text: String, family: MLXModelFamily) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix("<think>") {
            guard let end = result.range(of: "</think>") else { return "" }
            result = String(result[end.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Match suffixes repeatedly so adjacent terminators and surrounding
        // whitespace are handled without replacing identical tokens in content.
        while let token = family.extraEOSTokens.first(where: { result.hasSuffix($0) }) {
            result.removeLast(token.count)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
