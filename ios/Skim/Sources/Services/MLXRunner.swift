import Foundation
#if canImport(UIKit)
import UIKit
#endif
import MLX
import MLXLMCommon
import MLXLLM

/// On-device LLM runtime backed by MLX + Qwen 2.5 3B Instruct (4-bit default).
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

    /// Default Qwen 2.5 3B Instruct 4-bit HF repo id. Can be overridden via `setModel(_:)`.
    static let defaultRepoId = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    private var currentRepoId: String = MLXRunner.defaultRepoId
    private var loadedContainer: ModelContainer?
    private var loadingTask: Task<ModelContainer, Error>?

    /// Optional progress sink; called from the hub loader as weights download.
    /// `MLXModelManager` installs this to drive the UI progress bar.
    private var progressSink: (@Sendable (Double) -> Void)?

    // MARK: - Errors

    enum MLXError: LocalizedError {
        case loadFailed(String)
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .loadFailed(let m): return "MLX model load failed: \(m)"
            case .generationFailed(let m): return "MLX generation failed: \(m)"
            }
        }
    }

    // MARK: - Init / lifecycle observers

    init() {
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

    /// Whether weights for the current repo are cached on disk. Does not load the model.
    nonisolated var isModelDownloaded: Bool {
        let repoId = MLXRunner.defaultRepoId // conservative: always check default
        let cfg = ModelConfiguration(id: repoId)
        let dir = cfg.modelDirectory()
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let hasWeights = contents.contains { $0.hasSuffix(".safetensors") }
        let hasConfig = contents.contains("config.json")
        return hasWeights && hasConfig
    }

    /// Whether weights for a specific repo are cached on disk.
    nonisolated static func isRepoDownloaded(_ repoId: String) -> Bool {
        let cfg = ModelConfiguration(id: repoId)
        let dir = cfg.modelDirectory()
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let hasWeights = contents.contains { $0.hasSuffix(".safetensors") }
        let hasConfig = contents.contains("config.json")
        return hasWeights && hasConfig
    }

    /// The currently selected repo id.
    func activeRepoId() -> String { currentRepoId }

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

    /// Ensure the model is loaded and cached. Triggers download on first call.
    @discardableResult
    func ensureLoaded() async throws -> ModelContainer {
        if let c = loadedContainer { return c }
        if let task = loadingTask { return try await task.value }

        let repoId = currentRepoId
        let sink = progressSink
        let task = Task { () throws -> ModelContainer in
            do {
                let cfg = ModelConfiguration(id: repoId)
                let container = try await LLMModelFactory.shared.loadContainer(
                    configuration: cfg
                ) { progress in
                    sink?(progress.fractionCompleted)
                }
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

    /// Run a single prompt/response. Returns the assistant text (possibly JSON when `jsonMode`).
    func complete(
        systemPrompt: String,
        userPrompt: String,
        jsonMode: Bool,
        maxTokens: Int
    ) async throws -> String {
        let container = try await ensureLoaded()

        // Gently steer toward JSON when requested — models without a real JSON mode
        // still respond well to explicit "respond with JSON only" instructions.
        let finalSystem: String
        if jsonMode {
            finalSystem = systemPrompt + "\n\nRespond with a single JSON object. No prose, no code fences."
        } else {
            finalSystem = systemPrompt
        }

        let params = GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0.3
        )

        do {
            // `perform` gives us the concrete `ModelContext` (model + tokenizer + processor)
            // inside the actor's isolation, so we can safely drive generation.
            let output = try await container.perform { (context: ModelContext) -> String in
                let messages: [Chat.Message] = [
                    .system(finalSystem),
                    .user(userPrompt)
                ]
                let userInput = UserInput(chat: messages)
                let lmInput = try await context.processor.prepare(input: userInput)

                var collected = ""
                let stream = try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: params,
                    context: context
                )
                for await item in stream {
                    if let chunk = item.chunk {
                        collected += chunk
                    }
                }
                return collected
            }
            return output
        } catch let e as MLXError {
            throw e
        } catch {
            throw MLXError.generationFailed("\(error)")
        }
    }
}
