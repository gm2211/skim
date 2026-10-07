import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import SkimInferencePolicy

/// Sampling and length settings for one generation.
public struct SkimSampling: Sendable, Equatable {
    public var maxTokens: Int
    public var temperature: Float
    public var topP: Float
    public var repetitionPenalty: Float?
    public var repetitionContextSize: Int

    public init(maxTokens: Int, temperature: Float, topP: Float, repetitionPenalty: Float?, repetitionContextSize: Int) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
    }

    var generateParameters: GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize
        )
    }
}

/// What one generation cost. Reported to the benchmark harness and to logs.
public struct SkimGenerationMetrics: Codable, Sendable, Equatable {
    /// Tokens in the rendered prompt.
    public var promptTokens: Int
    /// Leading prompt tokens served from the article prefix cache instead of being prefilled.
    public var reusedPromptTokens: Int
    public var generatedTokens: Int
    /// From the call (template + tokenize + prefill) to the first decoded text.
    public var timeToFirstTokenSeconds: Double
    public var prefillTokensPerSecond: Double
    public var decodeTokensPerSecond: Double
    public var totalSeconds: Double
    /// MLX peak active memory during the call, model weights included.
    public var peakMemoryBytes: Int

    public init(
        promptTokens: Int = 0,
        reusedPromptTokens: Int = 0,
        generatedTokens: Int = 0,
        timeToFirstTokenSeconds: Double = 0,
        prefillTokensPerSecond: Double = 0,
        decodeTokensPerSecond: Double = 0,
        totalSeconds: Double = 0,
        peakMemoryBytes: Int = 0
    ) {
        self.promptTokens = promptTokens
        self.reusedPromptTokens = reusedPromptTokens
        self.generatedTokens = generatedTokens
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.totalSeconds = totalSeconds
        self.peakMemoryBytes = peakMemoryBytes
    }
}

public struct SkimGeneration: Sendable {
    /// Raw model text; callers apply `LocalModelOutput.sanitize`.
    public let text: String
    public let metrics: SkimGenerationMetrics
}

public enum SkimEngineError: LocalizedError, Equatable {
    case promptTooLong(tokens: Int, limit: Int)
    /// A runtime error from the MLX C layer, caught instead of aborting.
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .promptTooLong(let tokens, let limit):
            return "This is too much text for the on-device model (\(tokens) tokens, it reads at most \(limit)). "
                + "Narrow the time range, or use a cloud provider for long requests."
        case .generationFailed(let message):
            return message
        }
    }
}

public enum SkimMLXRuntime {
    /// Caps the GPU buffer cache MLX keeps for reuse. On a phone, freed
    /// buffers held after a long prefill count against the app's memory limit.
    public static func setCacheLimit(bytes: Int) {
        Memory.cacheLimit = bytes
    }
}

/// A loaded on-device model plus the per-model state that makes repeat
/// requests cheaper.
///
/// Article chat sends a fresh `[system, user]` prompt per question, and the
/// user turn starts with the same multi-thousand-token article every time.
/// When the caller names a `reusablePrefixMarker` (the text that ends the
/// shared part, e.g. "END OF ARTICLE"), the model's cache state for
/// everything up to that marker is kept, and the next prompt that starts
/// with the same tokens prefills only its question. The model sees identical
/// tokens at identical positions either way; the one difference is that the
/// repetition penalty looks back only over the part that was prefilled.
public final class SkimMLXModel: @unchecked Sendable {
    public let directory: URL
    public let family: MLXModelFamily
    private let container: ModelContainer
    /// Only touched inside `container.perform`, which runs one call at a time.
    private let prefixStore = PrefixStore()

    /// Prefixes longer than this are not kept: on a phone, a long
    /// attention-only cache held between questions costs more memory than
    /// the prefill it saves is worth.
    public static let maxReusablePrefixTokens = 6_144

    private init(directory: URL, family: MLXModelFamily, container: ModelContainer) {
        self.directory = directory
        self.family = family
        self.container = container
    }

    /// Loads weights and tokenizer from a downloaded model folder.
    public static func load(directory: URL, family: MLXModelFamily) async throws -> SkimMLXModel {
        let configuration = ModelConfiguration(directory: directory, extraEOSTokens: family.extraEOSTokens)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: SkimHubDownloader(useBackgroundSession: false),
            using: SkimTokenizerLoader(),
            configuration: configuration
        )
        return SkimMLXModel(directory: directory, family: family, container: container)
    }

    /// Drops the kept article prefix (memory pressure, model switch).
    public func clearPrefixCache() async {
        let store = prefixStore
        await container.perform { _ in store.entry = nil }
    }

    /// Runs one chat-template generation.
    ///
    /// - Parameters:
    ///   - messages: `[["role": ..., "content": ...]]`, already normalized.
    ///   - reusablePrefixMarker: text ending the part of the prompt that the
    ///     next request is likely to repeat; nil disables prefix reuse.
    ///   - maxPromptTokens: longest prompt allowed before failing with
    ///     ``SkimEngineError/promptTooLong(tokens:limit:)``.
    ///   - onChunk: receives decoded text as it streams.
    public func generate(
        messages: [[String: String]],
        sampling: SkimSampling,
        reusablePrefixMarker: String? = nil,
        maxPromptTokens: Int,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> SkimGeneration {
        let family = self.family
        let store = prefixStore
        let additionalContext: [String: any Sendable]? = family.supportsThinkingToggle ? ["enable_thinking": false] : nil
        let parameters = sampling.generateParameters

        return try await container.perform { (context: ModelContext) -> SkimGeneration in
            let start = Date()
            Memory.peakMemory = 0

            let input = UserInput(
                messages: messages.map { $0 as [String: any Sendable] },
                additionalContext: additionalContext
            )
            let lmInput = try await context.processor.prepare(input: input)
            let promptTokenCount = lmInput.text.tokens.size
            guard promptTokenCount <= maxPromptTokens else {
                throw SkimEngineError.promptTooLong(tokens: promptTokenCount, limit: maxPromptTokens)
            }
            try Task.checkCancellation()

            // MLX.withError turns C-layer errors (e.g. from eval during
            // sampling) into Swift errors instead of a fatalError. It must
            // wrap the work on the task where MLX evaluates, so it lives
            // inside `perform`.
            do {
                return try await MLX.withError {
                    let plan = try PrefixPlan.make(
                        lmInput: lmInput,
                        marker: reusablePrefixMarker,
                        store: store,
                        context: context,
                        parameters: parameters
                    )

                    let iterator = try TokenIterator(
                        input: plan.input,
                        model: context.model,
                        cache: plan.cache,
                        state: plan.state,
                        parameters: parameters
                    )
                    let (stream, task) = generateTask(
                        promptTokenCount: plan.input.text.tokens.size,
                        modelConfiguration: context.configuration,
                        tokenizer: context.tokenizer,
                        iterator: iterator
                    )

                    var text = ""
                    var firstChunkAt: Date?
                    var info: GenerateCompletionInfo?
                    for await event in stream {
                        if Task.isCancelled { break }
                        switch event {
                        case .chunk(let chunk):
                            if firstChunkAt == nil { firstChunkAt = Date() }
                            text += chunk
                            onChunk?(chunk)
                        case .info(let completion):
                            info = completion
                        case .toolCall, .rejectedToolCall:
                            break
                        }
                    }
                    // The loop keeps running briefly after an early break; the
                    // cache must be quiet before the next request touches it.
                    await task.value
                    plan.finish(store: store)
                    try Task.checkCancellation()

                    let end = Date()
                    let prefillSeconds = (info?.promptTime ?? 0)
                    let prefilled = promptTokenCount - plan.reusedTokens
                    var metrics = SkimGenerationMetrics()
                    metrics.promptTokens = promptTokenCount
                    metrics.reusedPromptTokens = plan.reusedTokens
                    metrics.generatedTokens = info?.generationTokenCount ?? 0
                    metrics.timeToFirstTokenSeconds = (firstChunkAt ?? end).timeIntervalSince(start)
                    metrics.prefillTokensPerSecond = prefillSeconds > 0 ? Double(prefilled) / prefillSeconds : 0
                    metrics.decodeTokensPerSecond = info?.tokensPerSecond ?? 0
                    metrics.totalSeconds = end.timeIntervalSince(start)
                    metrics.peakMemoryBytes = Memory.peakMemory
                    return SkimGeneration(text: text, metrics: metrics)
                }
            } catch let error as MLX.MLXError {
                throw SkimEngineError.generationFailed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Article prefix reuse

/// The cache state for a prompt prefix, kept between requests.
final class PrefixStore: @unchecked Sendable {
    struct Entry {
        /// The prompt tokens up to and including the marker.
        let tokens: [Int]
        /// Attention-only caches can be rewound, so this is the live cache
        /// the last request generated into, trimmed back on reuse. Caches
        /// with recurrent or convolutional layers cannot be rewound, so they
        /// keep a pristine copy taken right after the prefix instead.
        let cache: [KVCache]
        let state: LMOutput.State?
        let isLive: Bool
    }

    var entry: Entry?
}

/// How one request uses (and refreshes) the prefix store.
struct PrefixPlan {
    let input: LMInput
    let cache: [KVCache]?
    let state: LMOutput.State?
    let reusedTokens: Int
    /// What to keep after generation, if anything.
    let keep: PrefixStore.Entry?

    /// A shorter shared run than this is not worth a cache rewind.
    static let minimumReuse = 64

    func finish(store: PrefixStore) {
        store.entry = keep
    }

    /// Plain attention caches can be trimmed back at any time. A sliding
    /// window cache (Gemma) reports trimmable only until it wraps, and
    /// recurrent or convolutional state (Qwen3.5, LFM) never is, so those
    /// keep a pristine copy instead.
    static func isRewindable(_ cache: [KVCache]) -> Bool {
        cache.allSatisfy { $0.isTrimmable && !($0 is RotatingKVCache) }
    }

    static func tokenArray(_ tokens: ArraySlice<Int>) -> MLXArray {
        MLXArray(tokens.map { Int32($0) })
    }

    static func make(
        lmInput: LMInput,
        marker: String?,
        store: PrefixStore,
        context: ModelContext,
        parameters: GenerateParameters
    ) throws -> PrefixPlan {
        let plain = PrefixPlan(input: lmInput, cache: nil, state: nil, reusedTokens: 0, keep: nil)
        let previous = store.entry
        store.entry = nil
        guard let marker, !marker.isEmpty, lmInput.text.mask == nil else { return plain }

        let tokens = lmInput.text.tokens.asArray(Int.self)
        let boundary = SkimInferencePolicy.PromptPrefix.boundary(
            in: tokens, marker: marker, decode: { context.tokenizer.decode(tokenIds: $0) })
            .flatMap { $0 <= SkimMLXModel.maxReusablePrefixTokens ? $0 : nil }

        // Rewindable cache: reuse the longest shared run (long articles are
        // excerpted per question, so prompts may share only the opening),
        // then keep the live cache for the next request.
        if let previous, previous.isLive, isRewindable(previous.cache) {
            let shared = SkimInferencePolicy.PromptPrefix.commonLength(tokens, previous.tokens)
            if shared >= minimumReuse {
                for layer in previous.cache {
                    let extra = layer.offset - shared
                    if extra > 0 { _ = layer.trim(extra) }
                }
                let keep = boundary.map {
                    PrefixStore.Entry(tokens: Array(tokens[..<$0]), cache: previous.cache, state: nil, isLive: true)
                }
                return PrefixPlan(
                    input: LMInput(tokens: tokenArray(tokens[shared...])),
                    cache: previous.cache,
                    state: previous.state,
                    reusedTokens: shared,
                    keep: keep
                )
            }
        }

        // Pristine copy: only an exact prefix match can be continued.
        if let previous, !previous.isLive,
           SkimInferencePolicy.PromptPrefix.extends(tokens, prefix: previous.tokens) {
            return PrefixPlan(
                input: LMInput(tokens: tokenArray(tokens[previous.tokens.count...])),
                cache: previous.cache.map { $0.copy() },
                state: previous.state,
                reusedTokens: previous.tokens.count,
                keep: previous
            )
        }

        guard let boundary else { return plain }
        let cache = try context.model.newCache(parameters: parameters)
        if isRewindable(cache) {
            // Generate as usual; the live cache will hold this prompt.
            return PrefixPlan(
                input: lmInput,
                cache: cache,
                state: nil,
                reusedTokens: 0,
                keep: PrefixStore.Entry(tokens: Array(tokens[..<boundary]), cache: cache, state: nil, isLive: true)
            )
        }

        // Prefill up to the marker, copy that state, then continue. Building
        // the iterator prefills the prefix into `cache`; the token it samples
        // is discarded.
        let prefix = Array(tokens[..<boundary])
        let prefill = try TokenIterator(
            input: LMInput(tokens: tokenArray(prefix[...])),
            model: context.model,
            cache: cache,
            parameters: parameters
        )
        eval(cache.flatMap { $0.state })
        return PrefixPlan(
            input: LMInput(tokens: tokenArray(tokens[boundary...])),
            cache: cache,
            state: prefill.state,
            reusedTokens: 0,
            keep: PrefixStore.Entry(tokens: prefix, cache: cache.map { $0.copy() }, state: prefill.state, isLive: false)
        )
    }
}
