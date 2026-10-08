import Foundation
#if canImport(UIKit)
import UIKit
#endif
import SkimInferencePolicy
import SkimMLXEngine

// Preserve the app-module names used by SettingsSheet while sharing their implementation.
typealias MLXModelFamily = SkimInferencePolicy.MLXModelFamily
typealias MLXSamplingPreset = SkimInferencePolicy.MLXSamplingPreset

// MARK: - MLXRunner

actor MLXRunner {
    static let shared = MLXRunner()
    static let defaultRepoId = NativeMLX.defaultRepoId

    private var currentRepoId: String = MLXRunner.defaultRepoId
    private var loadedContainer: SkimMLXModel?
    private var loadedRepoId: String?
    private var loadingTask: Task<SkimMLXModel, Error>?
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
        // The kept article prefix is the cheapest thing to give back.
        Task { [weak self] in
            let stream = center.notifications(named: UIApplication.didReceiveMemoryWarningNotification)
            for await _ in stream {
                await self?.dropPrefixCache()
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

        let fallbacks = [NativeMLX.effectiveDefaultRepoId] + MLXRunner.downloadedRepoIds()
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

    func dropPrefixCache() async {
        await loadedContainer?.clearPrefixCache()
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
            // A background URLSession lets the OS continue (or restart) the
            // download while the app is suspended or killed; incomplete shard
            // files survive across launches so the download resumes.
            let downloader = SkimHubDownloader(useBackgroundSession: true)
            _ = try await downloader.downloadModel(repoId: repoId) { progress in
                sink?(progress.fractionCompleted)
            }

            // The Hub snapshot returns normally (rather than throwing) when
            // the task is cancelled mid-download, so check explicitly before
            // treating the download as having succeeded.
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

    /// The longest prompt handed to the model. MLX prefills the whole prompt
    /// at once and its memory grows with the prompt; past this, an iPhone runs
    /// out of the memory iOS allows an app and the system kills Skim outright,
    /// so an over-long request fails with a message instead.
    static let maxPromptTokens: Int = {
        let memory = ProcessInfo.processInfo.physicalMemory
        if memory < 15 * gigabyte / 2 { return 8_192 }      // 6 GB-class iPhones
        if memory < 25 * gigabyte / 2 { return 12_288 }     // 8-12 GB iPhones
        return 32_768
    }()

    /// On a phone-sized device, return freed GPU buffers to the system instead
    /// of keeping them cached for reuse: after a long prefill the cache alone
    /// can hold hundreds of megabytes, which counts against the app's limit.
    private static let memoryConfigured: Void = {
        if ProcessInfo.processInfo.physicalMemory < 25 * gigabyte / 2 {
            SkimMLXRuntime.setCacheLimit(bytes: 64 * 1024 * 1024)
        }
    }()

    private static let gigabyte = UInt64(1024 * 1024 * 1024)

    @discardableResult
    func ensureLoaded() async throws -> SkimMLXModel {
        guard MLXRunner.isAvailableOnThisRuntime else {
            throw MLXError.unavailable("MLX inference requires a real iPhone. The Simulator cannot run the MLX backend.")
        }
        _ = MLXRunner.memoryConfigured

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

        let family = MLXModelFamily.detect(from: repoId)
        let directory = MLXRunner.cacheDirectory(forRepo: repoId)
        let task = Task { () throws -> SkimMLXModel in
            do {
                return try await SkimMLXModel.load(directory: directory, family: family)
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

    /// Loads the selected model in the background so the first question
    /// doesn't pay for reading weights. Errors are left for the real request
    /// to report.
    func prewarm(repoId: String) async {
        guard MLXRunner.isAvailableOnThisRuntime, MLXRunner.isRepoDownloaded(repoId) else { return }
        setModel(repoId: repoId)
        _ = try? await ensureLoaded()
    }

    // MARK: - Core messages-based generation (shared implementation)

    /// Core completion from an arbitrary messages array. All other complete/stream
    /// variants delegate here after building their messages array.
    ///
    /// `reusablePrefixMarker` names the text that ends the part of the prompt
    /// the next request will repeat (the article in article chat), so its
    /// prefill can be reused instead of recomputed.
    func complete(
        messages: [[String: String]],
        maxTokens: Int,
        temperature: Float? = nil,
        topP: Float? = nil,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int? = nil,
        reusablePrefixMarker: String? = nil
    ) async throws -> String {
        try await generate(
            messages: messages,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            reusablePrefixMarker: reusablePrefixMarker,
            onToken: nil
        )
    }

    /// Core streaming generation from an arbitrary messages array.
    func stream(
        messages: [[String: String]],
        maxTokens: Int,
        temperature: Float? = nil,
        topP: Float? = nil,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int? = nil,
        reusablePrefixMarker: String? = nil,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        try await generate(
            messages: messages,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            reusablePrefixMarker: reusablePrefixMarker,
            onToken: onToken
        )
    }

    private func generate(
        messages: [[String: String]],
        maxTokens: Int,
        temperature: Float?,
        topP: Float?,
        repetitionPenalty: Float?,
        repetitionContextSize: Int?,
        reusablePrefixMarker: String?,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> String {
        try Task.checkCancellation()
        let model = try await ensureLoaded()
        try Task.checkCancellation()

        // Resolve sampling params: caller override > per-model preset.
        let preset = MLXSamplingPreset.preset(for: currentRepoId)
        let sampling = SkimSampling(
            maxTokens: maxTokens,
            temperature: temperature ?? preset.temperature,
            topP: topP ?? preset.topP,
            repetitionPenalty: repetitionPenalty ?? preset.repetitionPenalty,
            repetitionContextSize: repetitionContextSize ?? preset.repetitionContextSize
        )
        let prepared = LocalChatMessages.prepare(
            messages: messages.map { LocalChatMessage(role: $0["role"] ?? "user", content: $0["content"] ?? "") }
        )

        do {
            let result = try await model.generate(
                messages: prepared,
                sampling: sampling,
                reusablePrefixMarker: reusablePrefixMarker,
                maxPromptTokens: MLXRunner.maxPromptTokens,
                onChunk: onToken
            )
            try Task.checkCancellation()
            return LocalModelOutput.sanitize(result.text, family: model.family)
        } catch is CancellationError {
            throw CancellationError()
        } catch SkimEngineError.generationFailed(let message) {
            // An MLX C-layer runtime error, caught instead of aborting.
            throw MLXError.generationFailed(message)
        } catch let error as SkimEngineError {
            throw MLXError.unavailable(error.localizedDescription)
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
