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
        case loadFailed(String)
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .downloadFailed(let message): return "MLX model download failed: \(message)"
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

    nonisolated static func isRepoDownloaded(_ repoId: String) -> Bool {
        let dir = cacheDirectory(forRepo: repoId)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let hasWeights = contents.contains { $0.hasSuffix(".safetensors") }
        let hasConfig = contents.contains("config.json")
        return hasWeights && hasConfig
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
            loadedContainer = nil
            loadedRepoId = nil
            loadingTask?.cancel()
            loadingTask = nil
            loadingRepoId = nil
            sink?(1.0)
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
                throw MLXError.loadFailed("\(error)")
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
        maxTokens: Int
    ) async throws -> String {
        let container = try await ensureLoaded()
        let finalSystem = jsonMode
            ? systemPrompt + "\n\nRespond with a single JSON object. No prose, no code fences."
            : systemPrompt
        let messages: [[String: String]] = [
            ["role": "system", "content": finalSystem],
            ["role": "user", "content": userPrompt]
        ]
        let params = GenerateParameters(
            temperature: 0.3,
            repetitionPenalty: 1.1,
            repetitionContextSize: 64
        )
        let family = MLXModelFamily.detect(from: currentRepoId)

        do {
            let raw = try await container.perform { (context: ModelContext) -> String in
                let userInput = UserInput(messages: messages)
                let lmInput = try await context.processor.prepare(input: userInput)

                let result = try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: params,
                    context: context
                ) { tokens in
                    tokens.count >= maxTokens ? .stop : .more
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
