import Foundation
#if canImport(UIKit)
import UIKit
#endif
import SkimCore

struct MLXModelOption: Identifiable, Hashable {
    var repoId: String
    var label: String
    var sizeGB: Double
    var isPhoneFriendly: Bool
    /// Offered on iPhone only with ~12 GB of RAM or more: its weights plus a
    /// long article prompt would push an 8 GB phone past the app memory limit.
    var needsHighMemoryPhone: Bool = false
    var minMemoryGB: Double = 0

    var id: String { repoId }

    /// The model's name without the "(iPhone, fastest)" hint, for compact
    /// chips where the full label would truncate.
    var shortLabel: String {
        guard let paren = label.range(of: " (") else { return label }
        return String(label[..<paren.lowerBound])
    }
}

enum NativeMLX {
    /// Fresh installations use the compact LFM2.5 model. Saved selections
    /// and existing downloads are preserved by `effectiveDefaultRepoId`.
    static let defaultRepoId = "mlx-community/LFM2.5-1.2B-Instruct-4bit"

    // Approximate decimal GB downloaded, not peak working memory. Mirrors
    // MLX_MODELS in src/lib/aiModels.ts. MLXLLM loads the text branch of the
    // canonical multimodal checkpoints; Skim currently supplies text only.
    static var modelOptions: [MLXModelOption] {
        [
            MLXModelOption(repoId: defaultRepoId, label: "LFM2.5 1.2B Instruct (iPhone, recommended)", sizeGB: 0.7, isPhoneFriendly: true),
            MLXModelOption(repoId: "mlx-community/Qwen3.5-2B-4bit", label: "Qwen3.5 2B (iPhone)", sizeGB: 1.8, isPhoneFriendly: true),
            MLXModelOption(repoId: "mlx-community/Qwen3.5-4B-4bit", label: "Qwen3.5 4B (Mac, recommended; 12 GB iPhones)", sizeGB: 3.1, isPhoneFriendly: false, needsHighMemoryPhone: true),
            MLXModelOption(repoId: "mlx-community/gemma-4-e2b-it-4bit", label: "Gemma 4 E2B (12 GB iPhones, Mac)", sizeGB: 3.6, isPhoneFriendly: false, needsHighMemoryPhone: true),
            MLXModelOption(repoId: "mlx-community/gemma-4-e4b-it-4bit", label: "Gemma 4 E4B (Mac, 16 GB+)", sizeGB: 5.2, isPhoneFriendly: false, minMemoryGB: 16),
            MLXModelOption(repoId: "mlx-community/Qwen3.5-9B-4bit", label: "Qwen3.5 9B (Mac, 16 GB+; 24 GB+ preferred)", sizeGB: 6.0, isPhoneFriendly: false, minMemoryGB: 16),
            MLXModelOption(repoId: "mlx-community/Qwen3.8-27B-4bit", label: "Qwen3.8 27B (Mac, 48 GB+)", sizeGB: 16.1, isPhoneFriendly: false, minMemoryGB: 48),
            MLXModelOption(repoId: "mlx-community/Qwen3.6-35B-A3B-4bit", label: "Qwen3.6 35B-A3B (Mac, 48 GB+)", sizeGB: 20.4, isPhoneFriendly: false, minMemoryGB: 48)
        ]
    }

    /// Removed from fresh recommendations, still selectable when saved.
    static let retiredModelOptions: [MLXModelOption] = [
        MLXModelOption(repoId: "mlx-community/gemma-3-1b-it-4bit", label: "Gemma 3 1B", sizeGB: 0.7, isPhoneFriendly: true),
        MLXModelOption(repoId: "mlx-community/LFM2-1.2B-4bit", label: "LFM2 1.2B", sizeGB: 0.7, isPhoneFriendly: true),
        MLXModelOption(repoId: "mlx-community/Qwen3-1.7B-4bit", label: "Qwen3 1.7B", sizeGB: 1.0, isPhoneFriendly: true),
        MLXModelOption(repoId: "mlx-community/Qwen3-4B-Instruct-2507-4bit", label: "Qwen3 4B Instruct", sizeGB: 2.3, isPhoneFriendly: false),
        MLXModelOption(repoId: "mlx-community/gemma-3-4b-it-4bit", label: "Gemma 3 4B", sizeGB: 2.4, isPhoneFriendly: false),
        MLXModelOption(repoId: "mlx-community/Qwen3-8B-4bit", label: "Qwen3 8B", sizeGB: 4.6, isPhoneFriendly: false),
        MLXModelOption(repoId: "mlx-community/Qwen3-30B-A3B-4bit", label: "Qwen3 30B-A3B", sizeGB: 17.2, isPhoneFriendly: false)
    ]

    /// Pure memory filter, also used by tests. Allow for reported totals
    /// slightly below marketed RAM. Phone tiers leave room for article prefill.
    static func offeredOptions(isPhone: Bool, memoryGB: Double) -> [MLXModelOption] {
        modelOptions.filter { option in
            if isPhone {
                return option.isPhoneFriendly || (option.needsHighMemoryPhone && memoryGB >= 11.5)
            }
            return option.minMemoryGB == 0 || memoryGB >= option.minMemoryGB - 0.5
        }
    }

    @MainActor
    static var offeredOptions: [MLXModelOption] {
        #if canImport(UIKit)
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        #else
        let isPhone = false
        #endif
        return offeredOptions(isPhone: isPhone, memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / pow(1024, 3))
    }

    static var isAvailable: Bool {
        MLXRunner.isAvailableOnThisRuntime
    }

    static func option(for repoId: String) -> MLXModelOption {
        modelOptions.first(where: { $0.repoId == repoId })
            ?? retiredModelOptions.first(where: { $0.repoId == repoId })
            ?? MLXModelOption(repoId: repoId, label: repoId, sizeGB: 0, isPhoneFriendly: false)
    }

    static func isDownloaded(_ repoId: String) async -> Bool {
        await MLXRunner.shared.isModelDownloaded(repoId: repoId)
    }

    static func isDownloadedSync(_ repoId: String) -> Bool {
        MLXRunner.isRepoDownloaded(repoId)
    }

    /// Resolves the repo id the given settings would run against, using the
    /// existing precedence: an explicit local model path, then a repo-shaped
    /// `settings.model`, then the runtime default. A leaked cloud model id
    /// (e.g. "claude-sonnet-4-5") never contains "/" and is never returned.
    static func resolvedRepoId(_ settings: AISettings) -> String {
        let modelRepo = settings.model?.nilIfEmpty.flatMap { $0.contains("/") ? $0 : nil }
        return settings.localModelPath?.nilIfEmpty
            ?? modelRepo
            ?? effectiveDefaultRepoId
    }

    static func downloadedRepoIds() -> [String] {
        MLXRunner.downloadedRepoIds()
    }

    /// An unpinned existing installation keeps a downloaded model rather
    /// than being forced to download the new default. Explicit pins win above.
    static var effectiveDefaultRepoId: String {
        effectiveDefaultRepoId(downloaded: Set(downloadedRepoIds()))
    }

    static func effectiveDefaultRepoId(downloaded: Set<String>) -> String {
        if downloaded.contains(defaultRepoId) { return defaultRepoId }
        for previous in ["mlx-community/Qwen3-1.7B-4bit", "mlx-community/gemma-3-1b-it-4bit"] {
            if downloaded.contains(previous) { return previous }
        }
        return downloaded.sorted().first ?? defaultRepoId
    }

    static func download(
        repoId: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        await MLXRunner.shared.setProgressSink(progress)
        defer {
            Task {
                await MLXRunner.shared.setProgressSink(nil)
            }
        }
        try await MLXRunner.shared.downloadModel(repoId: repoId)
    }

    /// Loads the model `settings` would use, if it is downloaded, so a sheet
    /// that is about to ask it something doesn't wait on reading weights.
    static func prewarm(settings: AISettings) {
        guard isAvailable else { return }
        let repoId = resolvedRepoId(settings)
        guard MLXRunner.isRepoDownloaded(repoId) else { return }
        Task.detached(priority: .utility) {
            await MLXRunner.shared.prewarm(repoId: repoId)
        }
    }

    static func delete(repoId: String) async throws {
        try await MLXRunner.shared.deleteModel(repoId: repoId)
    }

    static func cancelDownload() async {
        await MLXRunner.shared.cancelDownload()
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let mlxError = error as? MLXRunner.MLXError, case .cancelled = mlxError {
            return true
        }
        return false
    }

    static func complete(
        settings: AISettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        jsonMode: Bool
    ) async throws -> String {
        // Only use settings.model as a repo id when it actually looks like one (contains "/").
        // A leaked cloud model id (e.g. "claude-sonnet-4-5") must not be passed to MLX.
        let modelRepo = settings.model?.nilIfEmpty.flatMap { $0.contains("/") ? $0 : nil }
        let repoId = settings.localModelPath?.nilIfEmpty
            ?? modelRepo
            ?? effectiveDefaultRepoId
        await MLXRunner.shared.selectDownloadedModel(preferredRepoId: repoId)

        // Use caller's maxTokens unless user has overridden it in settings
        let resolvedMaxTokens = settings.mlxMaxTokens ?? maxTokens

        return try await MLXRunner.shared.complete(
            systemPrompt: instructions,
            userPrompt: prompt,
            jsonMode: jsonMode,
            maxTokens: resolvedMaxTokens,
            temperature: settings.mlxTemperature.map { Float($0) },
            topP: settings.mlxTopP.map { Float($0) },
            repetitionPenalty: settings.mlxRepetitionPenalty.map { Float($0) },
            repetitionContextSize: settings.mlxRepetitionContextSize
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Multi-turn completion from an arbitrary messages array. Used by local MLX chat
    /// to pass real system + prior-turn + final-user messages through the chat template.
    ///
    /// Sampling precedence for `temperature`/`topP`/`repetitionPenalty`: an explicit
    /// user setting (`settings.mlx*`) wins, then the caller-supplied override (e.g. a
    /// use-case-tuned preset like `GroundedChatPrompt.samplingPreset`), then the
    /// per-model preset applied downstream in `MLXRunner`.
    ///
    /// `reusablePrefixMarker` is the text ending the part of the prompt that
    /// follow-up requests repeat (see `PromptPrefix.articleMarker`); the model
    /// state for it is kept so the next question skips that prefill.
    static func complete(
        settings: AISettings,
        messages: [[String: String]],
        maxTokens: Int,
        temperature: Double? = nil,
        topP: Double? = nil,
        repetitionPenalty: Double? = nil,
        reusablePrefixMarker: String? = nil
    ) async throws -> String {
        let repoId = resolvedRepoId(settings)
        await MLXRunner.shared.selectDownloadedModel(preferredRepoId: repoId)

        let resolvedMaxTokens = settings.mlxMaxTokens ?? maxTokens

        return try await MLXRunner.shared.complete(
            messages: messages,
            maxTokens: resolvedMaxTokens,
            temperature: settings.mlxTemperature.map { Float($0) } ?? temperature.map { Float($0) },
            topP: settings.mlxTopP.map { Float($0) } ?? topP.map { Float($0) },
            repetitionPenalty: settings.mlxRepetitionPenalty.map { Float($0) } ?? repetitionPenalty.map { Float($0) },
            repetitionContextSize: settings.mlxRepetitionContextSize,
            reusablePrefixMarker: reusablePrefixMarker
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streaming variant of `complete`. Calls `onToken` with each decoded chunk as it is generated,
    /// then returns the full sanitized output. Use this for summary and chat paths so the UI can
    /// display tokens progressively rather than waiting for the full generation to finish.
    static func stream(
        settings: AISettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        jsonMode: Bool = false,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        // Only use settings.model as a repo id when it actually looks like one (contains "/").
        // A leaked cloud model id (e.g. "claude-sonnet-4-5") must not be passed to MLX.
        let modelRepo = settings.model?.nilIfEmpty.flatMap { $0.contains("/") ? $0 : nil }
        let repoId = settings.localModelPath?.nilIfEmpty
            ?? modelRepo
            ?? effectiveDefaultRepoId
        await MLXRunner.shared.selectDownloadedModel(preferredRepoId: repoId)

        let resolvedMaxTokens = settings.mlxMaxTokens ?? maxTokens

        return try await MLXRunner.shared.stream(
            systemPrompt: instructions,
            userPrompt: prompt,
            jsonMode: jsonMode,
            maxTokens: resolvedMaxTokens,
            temperature: settings.mlxTemperature.map { Float($0) },
            topP: settings.mlxTopP.map { Float($0) },
            repetitionPenalty: settings.mlxRepetitionPenalty.map { Float($0) },
            repetitionContextSize: settings.mlxRepetitionContextSize,
            onToken: onToken
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
