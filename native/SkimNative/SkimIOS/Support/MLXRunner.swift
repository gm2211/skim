import Foundation
#if canImport(UIKit)
import UIKit
#endif
import Hub
import MLX
import MLXLMCommon
import MLXLLM

// MARK: - Model family detection

enum MLXModelFamily {
    case gemma
    case llama
    case qwen
    case phi
    case unknown

    /// Stop strings that mark end-of-turn for this model family.
    var extraEOSTokens: Set<String> {
        switch self {
        case .gemma:
            return ["<end_of_turn>", "<eos>"]
        case .llama:
            return ["<|eot_id|>", "<|end_of_text|>"]
        case .qwen:
            return ["<|im_end|>", "<|endoftext|>"]
        case .phi:
            return ["<|end|>", "<|endoftext|>"]
        case .unknown:
            return []
        }
    }

    static func detect(from repoId: String) -> MLXModelFamily {
        let lower = repoId.lowercased()
        if lower.contains("gemma") { return .gemma }
        if lower.contains("llama") { return .llama }
        if lower.contains("qwen") { return .qwen }
        if lower.contains("phi") { return .phi }
        return .unknown
    }
}

// MARK: - Per-model sampling presets

struct MLXSamplingPreset {
    var temperature: Float
    var topP: Float
    var repetitionPenalty: Float
    var repetitionContextSize: Int

    /// Known-good defaults keyed by repo id.
    static let presets: [String: MLXSamplingPreset] = [
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
        // Qwen 2.5 1.5B
        "mlx-community/Qwen2.5-1.5B-Instruct-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.9, repetitionPenalty: 1.1, repetitionContextSize: 64
        ),
        // Qwen 2.5 3B
        "mlx-community/Qwen2.5-3B-Instruct-4bit": MLXSamplingPreset(
            temperature: 0.3, topP: 0.9, repetitionPenalty: 1.1, repetitionContextSize: 64
        ),
    ]

    static let fallback = MLXSamplingPreset(
        temperature: 0.3, topP: 0.95, repetitionPenalty: 1.1, repetitionContextSize: 64
    )

    static func preset(for repoId: String) -> MLXSamplingPreset {
        presets[repoId] ?? fallback
    }
}

// MARK: - MLXRunner

actor MLXRunner {
    static let shared = MLXRunner()
    static let defaultRepoId = "mlx-community/gemma-3-1b-it-4bit"

    private var currentRepoId: String = MLXRunner.defaultRepoId
    private var loadedContainer: ModelContainer?
    private var loadedRepoId: String?
    private var loadingTask: Task<ModelContainer, Error>?
    private var loadingRepoId: String?
    private var progressSink: (@Sendable (Double) -> Void)?

    enum MLXError: LocalizedError {
        case unavailable(String)
        case downloadFailed(String)
        case integrityFailed(String)
        case loadFailed(String)
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .downloadFailed(let message): return "MLX model download failed: \(message)"
            case .integrityFailed(let message): return "Model files corrupted — tap to re-download. (\(message))"
            case .loadFailed(let message): return "MLX model load failed: \(message)"
            case .generationFailed(let message): return "MLX generation failed: \(message)"
            }
        }
    }

    init() {
        Self.cleanupAllPartialDownloads()
        Task { await self.installObservers() }
    }

    private func installObservers() {
        let center = NotificationCenter.default

        #if canImport(UIKit)
        Task { [weak self] in
            let stream = center.notifications(named: UIApplication.didEnterBackgroundNotification)
            for await _ in stream {
                await self?.evict()
            }
        }
        #endif

        Task { [weak self] in
            let stream = center.notifications(named: ProcessInfo.thermalStateDidChangeNotification)
            for await _ in stream {
                let state = ProcessInfo.processInfo.thermalState
                if state == .serious || state == .critical {
                    await self?.evict()
                }
            }
        }
    }

    nonisolated static func cacheDirectory(forRepo repoId: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoId, isDirectory: true)
    }

    nonisolated static func cleanupAllPartialDownloads() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelsDir = documents
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: modelsDir,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return
        }

        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".incomplete") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated static func cleanupPartialDownloads(repoId: String) {
        let repoDir = cacheDirectory(forRepo: repoId)
        guard let enumerator = FileManager.default.enumerator(
            at: repoDir,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return
        }

        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".incomplete") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Integrity check

    /// Returns nil if the model directory looks complete, or an error string describing what is missing.
    nonisolated static func integrityError(forRepo repoId: String) -> String? {
        let dir = cacheDirectory(forRepo: repoId)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return "model directory not found"
        }

        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent(name).path)
        }
        func fileSize(_ name: String) -> Int {
            (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int) ?? 0
        }

        // config.json is always required
        guard exists("config.json") else {
            return "missing config.json"
        }

        // tokenizer: either tokenizer.json or tokenizer.model (sentencepiece)
        guard exists("tokenizer.json") || exists("tokenizer.model") else {
            return "missing tokenizer.json or tokenizer.model"
        }

        // Check for sharded model via index file
        let indexFile = "model.safetensors.index.json"
        if exists(indexFile) {
            // Parse the index and verify every shard listed exists with non-zero size
            let indexURL = dir.appendingPathComponent(indexFile)
            guard let data = try? Data(contentsOf: indexURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weightMap = json["weight_map"] as? [String: String]
            else {
                return "could not parse \(indexFile)"
            }
            let shards = Set(weightMap.values)
            for shard in shards {
                guard exists(shard) else {
                    return "missing weight shard: \(shard)"
                }
                guard fileSize(shard) > 0 else {
                    return "weight shard is empty: \(shard)"
                }
            }
        } else {
            // Single-file model: must have at least one .safetensors with non-zero size
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let shards = contents.filter { $0.hasSuffix(".safetensors") }
            guard !shards.isEmpty else {
                return "no .safetensors weight files found"
            }
            let allNonEmpty = shards.allSatisfy { fileSize($0) > 0 }
            guard allNonEmpty else {
                return "one or more weight shards have zero size"
            }
        }

        return nil  // all good
    }

    nonisolated static func isRepoDownloaded(_ repoId: String) -> Bool {
        integrityError(forRepo: repoId) == nil
    }

    nonisolated static func downloadedRepoIds() -> [String] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelsDir = documents
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        guard let orgs = try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        var repoIds: [String] = []
        for org in orgs {
            guard (try? org.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let repos = (try? FileManager.default.contentsOfDirectory(
                at: org,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            for repo in repos {
                guard (try? repo.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }
                let repoId = "\(org.lastPathComponent)/\(repo.lastPathComponent)"
                if isRepoDownloaded(repoId) {
                    repoIds.append(repoId)
                }
            }
        }
        return repoIds.sorted()
    }

    nonisolated static var isAvailableOnThisRuntime: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    func activeRepoId() -> String { currentRepoId }

    func setModel(repoId: String) {
        guard repoId != currentRepoId else { return }
        currentRepoId = repoId
        loadedContainer = nil
        loadedRepoId = nil
        loadingTask?.cancel()
        loadingTask = nil
        loadingRepoId = nil
    }

    func selectDownloadedModel(preferredRepoId: String) {
        if MLXRunner.isRepoDownloaded(preferredRepoId) {
            setModel(repoId: preferredRepoId)
            return
        }

        let fallbacks = [MLXRunner.defaultRepoId] + MLXRunner.downloadedRepoIds()
        if let fallback = fallbacks.first(where: { MLXRunner.isRepoDownloaded($0) }) {
            setModel(repoId: fallback)
        } else {
            setModel(repoId: preferredRepoId)
        }
    }

    func setProgressSink(_ sink: (@Sendable (Double) -> Void)?) {
        progressSink = sink
    }

    func evict() {
        loadedContainer = nil
        loadedRepoId = nil
        loadingTask?.cancel()
        loadingTask = nil
        loadingRepoId = nil
    }

    func isModelDownloaded(repoId: String) -> Bool {
        MLXRunner.isRepoDownloaded(repoId)
    }

    func downloadModel(repoId: String) async throws {
        guard MLXRunner.isAvailableOnThisRuntime else {
            throw MLXError.unavailable("MLX downloads require a real iPhone. The Simulator cannot run the MLX backend.")
        }

        let sink = progressSink
        let config = ModelConfiguration(id: repoId)
        do {
            MLXRunner.cleanupPartialDownloads(repoId: repoId)
            _ = try await MLXLMCommon.downloadModel(
                hub: HubApi(),
                configuration: config,
                progressHandler: { progress in
                    sink?(progress.fractionCompleted)
                }
            )

            // Integrity check immediately after download completes
            if let integrityIssue = MLXRunner.integrityError(forRepo: repoId) {
                MLXRunner.cleanupPartialDownloads(repoId: repoId)
                throw MLXError.integrityFailed(integrityIssue)
            }

            loadedContainer = nil
            loadedRepoId = nil
            loadingTask?.cancel()
            loadingTask = nil
            loadingRepoId = nil
            sink?(1.0)
        } catch let mlxErr as MLXError {
            MLXRunner.cleanupPartialDownloads(repoId: repoId)
            throw mlxErr
        } catch {
            MLXRunner.cleanupPartialDownloads(repoId: repoId)
            throw MLXError.downloadFailed("\(error)")
        }
    }

    func deleteModel(repoId: String) throws {
        let dir = MLXRunner.cacheDirectory(forRepo: repoId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        if currentRepoId == repoId {
            loadedContainer = nil
            loadedRepoId = nil
            loadingTask?.cancel()
            loadingTask = nil
            loadingRepoId = nil
        }
    }

    @discardableResult
    func ensureLoaded() async throws -> ModelContainer {
        guard MLXRunner.isAvailableOnThisRuntime else {
            throw MLXError.unavailable("MLX inference requires a real iPhone. The Simulator cannot run the MLX backend.")
        }

        let repoId = currentRepoId
        if let container = loadedContainer, loadedRepoId == repoId {
            return container
        }
        loadedContainer = nil
        loadedRepoId = nil

        if let task = loadingTask, loadingRepoId == repoId {
            return try await task.value
        }
        loadingTask?.cancel()
        loadingTask = nil
        loadingRepoId = nil

        guard MLXRunner.isRepoDownloaded(repoId) else {
            if let integrityIssue = MLXRunner.integrityError(forRepo: repoId) {
                throw MLXError.integrityFailed(integrityIssue)
            }
            throw MLXError.loadFailed("Model \(repoId) is not downloaded.")
        }

        let sink = progressSink
        let family = MLXModelFamily.detect(from: repoId)
        let task = Task { () throws -> ModelContainer in
            do {
                let config = ModelConfiguration(
                    id: repoId,
                    extraEOSTokens: family.extraEOSTokens
                )
                return try await LLMModelFactory.shared.loadContainer(
                    configuration: config,
                    progressHandler: { progress in
                        sink?(progress.fractionCompleted)
                    }
                )
            } catch {
                throw MLXError.loadFailed("Model files corrupted — tap to re-download. (\(error))")
            }
        }
        loadingTask = task
        loadingRepoId = repoId

        do {
            let container = try await task.value
            if currentRepoId == repoId {
                loadedContainer = container
                loadedRepoId = repoId
            }
            loadingTask = nil
            loadingRepoId = nil
            return container
        } catch {
            loadingTask = nil
            loadingRepoId = nil
            throw error
        }
    }

    func complete(
        systemPrompt: String,
        userPrompt: String,
        jsonMode: Bool,
        maxTokens: Int,
        temperature: Float? = nil,
        topP: Float? = nil,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int? = nil
    ) async throws -> String {
        let container = try await ensureLoaded()
        let finalSystem = jsonMode
            ? systemPrompt + "\n\nRespond with a single JSON object. No prose, no code fences."
            : systemPrompt
        let messages: [[String: String]] = [
            ["role": "system", "content": finalSystem],
            ["role": "user", "content": userPrompt]
        ]

        // Resolve sampling params: caller override > per-model preset > hardcoded fallback
        let preset = MLXSamplingPreset.preset(for: currentRepoId)
        let resolvedTemperature = temperature ?? preset.temperature
        let resolvedTopP = topP ?? preset.topP
        let resolvedRepPenalty = repetitionPenalty ?? preset.repetitionPenalty
        let resolvedRepCtxSize = repetitionContextSize ?? preset.repetitionContextSize

        let params = GenerateParameters(
            temperature: resolvedTemperature,
            topP: resolvedTopP,
            repetitionPenalty: resolvedRepPenalty,
            repetitionContextSize: resolvedRepCtxSize
        )
        let family = MLXModelFamily.detect(from: currentRepoId)
        let tokenBudget = maxTokens

        do {
            let raw = try await container.perform { (context: ModelContext) -> String in
                let userInput = UserInput(messages: messages)
                let lmInput = try await context.processor.prepare(input: userInput)

                let result = try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: params,
                    context: context
                ) { tokens in
                    tokens.count >= tokenBudget ? .stop : .more
                }
                return result.output
            }
            return sanitizeOutput(raw, family: family)
        } catch let error as MLXError {
            throw error
        } catch {
            throw MLXError.generationFailed("\(error)")
        }
    }

    // Strip any leaked stop tokens from the output.
    private func sanitizeOutput(_ text: String, family: MLXModelFamily) -> String {
        var result = text
        // Strip all known stop strings for this family
        for token in family.extraEOSTokens {
            result = result.replacingOccurrences(of: token, with: "")
        }
        // Also strip any remaining angle-bracket special tokens like <end_of_turn>, <eos>, <|...|>
        result = result.replacingOccurrences(
            of: "<[^>]{1,30}>",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "<\\|[^|]{1,30}\\|>",
            with: "",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
