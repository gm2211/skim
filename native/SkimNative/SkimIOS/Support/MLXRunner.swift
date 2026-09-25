import Foundation
#if canImport(UIKit)
import UIKit
#endif
import Hub
import MLX
import MLXLMCommon
import MLXLLM

import SkimInferencePolicy

// Preserve the app-module names used by SettingsSheet while sharing their implementation.
typealias MLXModelFamily = SkimInferencePolicy.MLXModelFamily
typealias MLXSamplingPreset = SkimInferencePolicy.MLXSamplingPreset

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
    private var downloadTask: Task<Void, Error>?
    private var downloadingRepoId: String?
    private var downloadGeneration: Int = 0

    enum MLXError: LocalizedError {
        case unavailable(String)
        case downloadFailed(String)
        case integrityFailed(String)
        case loadFailed(String)
        case generationFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .downloadFailed(let message): return "MLX model download failed: \(message)"
            case .integrityFailed(let message): return "Model files corrupted — tap to re-download. (\(message))"
            case .loadFailed(let message): return "MLX model load failed: \(message)"
            case .generationFailed(let message): return "MLX generation failed: \(message)"
            case .cancelled: return "Download cancelled."
            }
        }
    }

    init() {
        // Note: we no longer eagerly wipe .incomplete files on startup. The background
        // URLSession preserves them so interrupted downloads can resume on next launch.
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

        guard ModelChatTemplate.isUsable(in: dir) else {
            return "model chat template missing or invalid — re-download this model"
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
        // Existing incomplete caches represent the user's chosen model. Keep
        // it selected so ensureLoaded surfaces the repair error instead of
        // silently switching models after an integrity-policy upgrade.
        if FileManager.default.fileExists(atPath: MLXRunner.cacheDirectory(forRepo: preferredRepoId).path) {
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

    var isDownloading: Bool { downloadTask != nil }

    func downloadModel(repoId: String) async throws {
        guard MLXRunner.isAvailableOnThisRuntime else {
            throw MLXError.unavailable("MLX downloads require a real iPhone. The Simulator cannot run the MLX backend.")
        }

        // If a download for this exact repo is already in flight, just await it
        // rather than starting a second, redundant download.
        if let existing = downloadTask, downloadingRepoId == repoId {
            try await existing.value
            return
        }

        let sink = progressSink
        let task = Task { () throws -> Void in
            let config = ModelConfiguration(id: repoId)
            // Use a background URLSession so the OS can continue (or restart) the download
            // even when the app is suspended or killed. Incomplete shard files are preserved
            // across launches so the Hub library can resume from where it left off.
            let hub = HubApi(useBackgroundSession: true)
            _ = try await MLXLMCommon.downloadModel(
                hub: hub,
                configuration: config,
                progressHandler: { progress in
                    sink?(progress.fractionCompleted)
                }
            )

            // MLXLMCommon.downloadModel only fetches *.safetensors and *.json. Newer
            // repos (Qwen3 2507, SmolLM3, Gemma 3n) ship their chat template as a
            // standalone chat_template.jinja, which the tokenizer loader reads from the
            // model folder. Fetch it too so the model still works offline.
            if !Task.isCancelled {
                _ = try await hub.snapshot(from: Hub.Repo(id: repoId), matching: ["*.jinja"])
            }

            // swift-transformers' HubApi.snapshot() returns normally (rather than
            // throwing) when the task is cancelled mid-download, so we must check
            // explicitly here before treating the download as having succeeded.
            if Task.isCancelled {
                throw MLXError.cancelled
            }
            try Task.checkCancellation()

            // Integrity check immediately after download completes
            if let integrityIssue = MLXRunner.integrityError(forRepo: repoId) {
                MLXRunner.cleanupPartialDownloads(repoId: repoId)
                throw MLXError.integrityFailed(integrityIssue)
            }
        }
        downloadGeneration += 1
        let myGeneration = downloadGeneration
        downloadTask = task
        downloadingRepoId = repoId

        do {
            try await task.value

            loadedContainer = nil
            loadedRepoId = nil
            loadingTask?.cancel()
            loadingTask = nil
            loadingRepoId = nil
            sink?(1.0)

            if downloadGeneration == myGeneration {
                downloadTask = nil
                downloadingRepoId = nil
            }
        } catch {
            if downloadGeneration == myGeneration {
                downloadTask = nil
                downloadingRepoId = nil
            }

            if error is CancellationError {
                MLXRunner.cleanupPartialDownloads(repoId: repoId)
                throw MLXError.cancelled
            }
            if let mlxErr = error as? MLXError {
                if case .cancelled = mlxErr {
                    MLXRunner.cleanupPartialDownloads(repoId: repoId)
                }
                throw mlxErr
            }
            throw MLXError.downloadFailed("\(error)")
        }
    }

    /// Cancels the in-flight download for the current repo, if any, and cleans up
    /// any partially downloaded files. Safe to call when no download is running.
    func cancelDownload() async {
        guard let task = downloadTask, let repoId = downloadingRepoId else {
            return
        }
        let myGeneration = downloadGeneration
        task.cancel()
        _ = try? await task.value
        MLXRunner.cleanupPartialDownloads(repoId: repoId)
        if downloadGeneration == myGeneration {
            downloadTask = nil
            downloadingRepoId = nil
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

    // MARK: - Core messages-based generation (shared implementation)

    /// Core completion from an arbitrary messages array. All other complete/stream
    /// variants delegate here after building their messages array.
    func complete(
        messages: [[String: String]],
        maxTokens: Int,
        temperature: Float? = nil,
        topP: Float? = nil,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        let container = try await ensureLoaded()
        try Task.checkCancellation()

        // Resolve sampling params: caller override > per-model preset > hardcoded fallback
        let preset = MLXSamplingPreset.preset(for: currentRepoId)
        let resolvedTemperature = temperature ?? preset.temperature
        let resolvedTopP = topP ?? preset.topP
        let resolvedRepPenalty = repetitionPenalty ?? preset.repetitionPenalty
        let resolvedRepCtxSize = repetitionContextSize ?? preset.repetitionContextSize

        // maxTokens is passed directly into GenerateParameters so the TokenIterator
        // can terminate internally without relying solely on the callback counting tokens.
        let params = GenerateParameters(
            maxTokens: maxTokens,
            temperature: resolvedTemperature,
            topP: resolvedTopP,
            repetitionPenalty: resolvedRepPenalty,
            repetitionContextSize: resolvedRepCtxSize
        )
        let family = MLXModelFamily.detect(from: currentRepoId)

        do {
            let raw = try await container.perform { (context: ModelContext) -> String in
                try Task.checkCancellation()
                let userInput = UserInput(
                    messages: LocalChatMessages.prepare(messages: messages.map { LocalChatMessage(role: $0["role"] ?? "user", content: $0["content"] ?? "") }),
                    additionalContext: family.supportsThinkingToggle ? ["enable_thinking": false] : nil
                )
                let lmInput = try await context.processor.prepare(input: userInput)
                try Task.checkCancellation()

                // Wrap in MLX.withError so C-layer errors (e.g. from MLXArray.eval during
                // token sampling) become catchable Swift errors instead of calling fatalError
                // and aborting the process. The scoped handler must be active on the same
                // thread/task that MLX eval runs on — placing it inside container.perform's
                // closure body guarantees that.
                let result = try MLX.withError {
                    try MLXLMCommon.generate(
                        input: lmInput,
                        parameters: params,
                        context: context
                    ) { (_: [Int]) in Task.isCancelled ? GenerateDisposition.stop : GenerateDisposition.more }
                }
                return result.output
            }
            try Task.checkCancellation()
            return LocalModelOutput.sanitize(raw, family: family)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MLX.MLXError {
            // MLX C-layer runtime error surfaced via scoped withError handler.
            // MLX.MLXError is mlx-swift's type (distinct from Skim's local MLXError);
            // map it into Skim's error hierarchy so callers see a consistent type.
            throw MLXError.generationFailed(error.localizedDescription)
        } catch let error as MLXError {
            throw error
        } catch {
            throw MLXError.generationFailed("\(error)")
        }
    }

    /// Core streaming generation from an arbitrary messages array.
    func stream(
        messages: [[String: String]],
        maxTokens: Int,
        temperature: Float? = nil,
        topP: Float? = nil,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int? = nil,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let container = try await ensureLoaded()

        // Resolve sampling params: caller override > per-model preset > hardcoded fallback
        let preset = MLXSamplingPreset.preset(for: currentRepoId)
        let resolvedTemperature = temperature ?? preset.temperature
        let resolvedTopP = topP ?? preset.topP
        let resolvedRepPenalty = repetitionPenalty ?? preset.repetitionPenalty
        let resolvedRepCtxSize = repetitionContextSize ?? preset.repetitionContextSize

        let params = GenerateParameters(
            maxTokens: maxTokens,
            temperature: resolvedTemperature,
            topP: resolvedTopP,
            repetitionPenalty: resolvedRepPenalty,
            repetitionContextSize: resolvedRepCtxSize
        )
        let family = MLXModelFamily.detect(from: currentRepoId)

        do {
            let raw = try await container.perform { (context: ModelContext) -> String in
                let userInput = UserInput(
                    messages: LocalChatMessages.prepare(messages: messages.map { LocalChatMessage(role: $0["role"] ?? "user", content: $0["content"] ?? "") }),
                    additionalContext: family.supportsThinkingToggle ? ["enable_thinking": false] : nil
                )
                let lmInput = try await context.processor.prepare(input: userInput)

                // Async withError wraps the streaming loop so any MLX C-layer error
                // emitted during token sampling (MLXArray.item / MLXArray.eval) is thrown
                // as a Swift error instead of aborting the process via fatalError.
                // Placed inside container.perform to ensure the scoped handler is active
                // on the same task where MLX evaluation actually runs.
                return try await MLX.withError {
                    var accumulated = ""
                    for await item in try MLXLMCommon.generate(
                        input: lmInput,
                        cache: nil,
                        parameters: params,
                        context: context
                    ) {
                        if let chunk = item.chunk {
                            accumulated += chunk
                            onToken(chunk)
                        }
                    }
                    return accumulated
                }
            }
            return LocalModelOutput.sanitize(raw, family: family)
        } catch let error as MLX.MLXError {
            // MLX C-layer runtime error surfaced via scoped withError handler.
            // Map to Skim's error hierarchy for consistent error handling by callers.
            throw MLXError.generationFailed(error.localizedDescription)
        } catch let error as MLXError {
            throw error
        } catch {
            throw MLXError.generationFailed("\(error)")
        }
    }

    // MARK: - Legacy single-turn wrappers (delegate to the messages-based core)

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
        let messages = LocalChatMessages.prepare(system: systemPrompt, user: userPrompt, jsonMode: jsonMode)
        return try await complete(
            messages: messages,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize
        )
    }

    /// Stream tokens as they are generated, calling `onToken` with each decoded chunk.
    /// Returns the full sanitized output when generation is complete.
    func stream(
        systemPrompt: String,
        userPrompt: String,
        jsonMode: Bool,
        maxTokens: Int,
        temperature: Float? = nil,
        topP: Float? = nil,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int? = nil,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let messages = LocalChatMessages.prepare(system: systemPrompt, user: userPrompt, jsonMode: jsonMode)
        return try await stream(
            messages: messages,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            onToken: onToken
        )
    }

}
