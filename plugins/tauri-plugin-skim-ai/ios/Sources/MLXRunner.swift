import Foundation
#if canImport(UIKit)
import UIKit
#endif
import Hub
import MLX
import MLXLMCommon
import MLXLLM

/// On-device LLM runtime backed by MLX + a small phone-friendly default model.
///
/// - Lazy-loads the model on first `complete()`.
/// - Caches the loaded `ModelContainer` inside the actor so subsequent calls skip load.
/// - Evicts the model on app background and when thermal state hits `.serious` / `.critical`.
///
/// Progress reporting for downloads is surfaced through `MLXModelManager`
/// (see `MLXModelManager.swift`), which drives the Settings "Manage models" screen.
actor MLXRunner {
    static let shared = MLXRunner()

    // MARK: - Config

    /// Default HF repo id. Can be overridden via `setModel(_:)`.
    static let defaultRepoId = "mlx-community/gemma-3-1b-it-4bit"

    private var currentRepoId: String = MLXRunner.defaultRepoId
    private var loadedContainer: ModelContainer?
    private var loadingTask: Task<ModelContainer, Error>?

    /// Optional progress sink; called from the hub loader as weights download.
    /// `MLXModelManager` installs this to drive the UI progress bar.
    private var progressSink: (@Sendable (Double) -> Void)?

    // MARK: - Errors

    enum MLXError: LocalizedError {
        case downloadFailed(String)
        case loadFailed(String)
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let m): return "MLX model download failed: \(m)"
            case .loadFailed(let m): return "MLX model load failed: \(m)"
            case .generationFailed(let m): return "MLX generation failed: \(m)"
            }
        }
    }

    // MARK: - Init / lifecycle observers

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

    // MARK: - Public API

    /// Whether default-repo weights are cached on disk. Does not load the model.
    nonisolated var isModelDownloaded: Bool {
        MLXRunner.isRepoDownloaded(MLXRunner.defaultRepoId)
    }

    /// Local on-disk path where HubApi caches a given model repo.
    /// Mirrors `HubApi`'s default layout: `~/Documents/huggingface/models/<org>/<repo>`.
    /// We compute this ourselves so we don't need to link the `Hub` product just
    /// to call `ModelConfiguration.modelDirectory()` (whose default-arg requires `Hub`).
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
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
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

    /// Whether weights for a specific repo are cached on disk.
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

    /// The currently selected repo id.
    func activeRepoId() -> String { currentRepoId }

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

    /// Switch which model is used. Evicts any loaded model if the repo changed.
    func setModel(repoId: String) {
        guard repoId != currentRepoId else { return }
        currentRepoId = repoId
        loadedContainer = nil
        loadingTask = nil
    }

    /// Install a progress sink (invoked by `MLXModelManager` while downloading).
    func setProgressSink(_ sink: (@Sendable (Double) -> Void)?) {
        self.progressSink = sink
    }

    /// Force-evict the loaded model. Safe to call any time.
    func evict() {
        loadedContainer = nil
        loadingTask = nil
    }

    /// Whether weights for an arbitrary repo are cached on disk — async variant
    /// so callers can `await` from an actor-isolated context without dropping
    /// to nonisolated.
    func isModelDownloaded(repoId: String) -> Bool {
        MLXRunner.isRepoDownloaded(repoId)
    }

    /// Download model weights/config without loading them into GPU memory.
    /// The Settings "Download" button must not call `ensureLoaded()`: loading
    /// immediately after a multi-GB download can terminate the app on memory
    /// constrained phones.
    func downloadModel(repoId: String) async throws {
        let sink = progressSink
        let cfg = ModelConfiguration(id: repoId)
        do {
            MLXRunner.cleanupPartialDownloads(repoId: repoId)
            _ = try await MLXLMCommon.downloadModel(
                hub: HubApi(),
                configuration: cfg,
                progressHandler: { progress in
                    sink?(progress.fractionCompleted)
                }
            )
            loadedContainer = nil
            loadingTask = nil
            sink?(1.0)
        } catch {
            MLXRunner.cleanupPartialDownloads(repoId: repoId)
            throw MLXError.downloadFailed("\(error)")
        }
    }

    /// Remove cached weights for `repoId`. Evicts the loaded container if it
    /// matches the deleted repo.
    func deleteModel(repoId: String) throws {
        let dir = MLXRunner.cacheDirectory(forRepo: repoId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        if currentRepoId == repoId {
            loadedContainer = nil
            loadingTask = nil
        }
    }

    /// Ensure the model is loaded and cached. Triggers download on first call.
    @discardableResult
    func ensureLoaded() async throws -> ModelContainer {
        if let c = loadedContainer { return c }
        if let task = loadingTask { return try await task.value }

        let repoId = currentRepoId
        guard MLXRunner.isRepoDownloaded(repoId) else {
            throw MLXError.loadFailed("Model \(repoId) is not downloaded.")
        }
        let sink = progressSink
        let task = Task { () throws -> ModelContainer in
            do {
                let cfg = ModelConfiguration(id: repoId)
                let container = try await LLMModelFactory.shared.loadContainer(
                    configuration: cfg,
                    progressHandler: { progress in
                        sink?(progress.fractionCompleted)
                    }
                )
                return container
            } catch {
                throw MLXError.loadFailed("\(error)")
            }
        }
        loadingTask = task

        do {
            let container = try await task.value
            loadedContainer = container
            loadingTask = nil
            return container
        } catch {
            loadingTask = nil
            throw error
        }
    }

    /// Run a single prompt/response. Returns the assistant text (JSON when `jsonMode`).
    func complete(
        systemPrompt: String,
        userPrompt: String,
        jsonMode: Bool,
        maxTokens: Int
    ) async throws -> String {
        let container = try await ensureLoaded()

        // Gently steer toward JSON when requested — MLX LLMs don't have a real
        // JSON mode, but the instruct tunes comply well with explicit guidance.
        let finalSystem: String
        if jsonMode {
            finalSystem = systemPrompt + "\n\nRespond with a single JSON object. No prose, no code fences."
        } else {
            finalSystem = systemPrompt
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": finalSystem],
            ["role": "user", "content": userPrompt]
        ]

        // MLXLMCommon 2.21 does not support maxTokens on GenerateParameters.
        // Instead we enforce the token budget via the didGenerate callback.
        let params = GenerateParameters(temperature: 0.3)
        let budget = maxTokens

        do {
            let output: String = try await container.perform { (context: ModelContext) -> String in
                let userInput = UserInput(messages: messages)
                let lmInput = try await context.processor.prepare(input: userInput)

                let result = try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: params,
                    context: context
                ) { tokens in
                    tokens.count >= budget ? .stop : .more
                }
                return result.output
            }
            return output
        } catch let e as MLXError {
            throw e
        } catch {
            throw MLXError.generationFailed("\(error)")
        }
    }
}
