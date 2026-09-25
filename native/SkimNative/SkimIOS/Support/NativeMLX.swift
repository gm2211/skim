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

    var id: String { repoId }
}

enum NativeMLX {
    static let defaultRepoId = MLXRunner.defaultRepoId

    // Sorted ascending by size; mirrors MLX_MODELS in src/lib/aiModels.ts.
    // Models dropped from this list still work for anyone who saved them:
    // pickers add a "(legacy)" entry for the current selection.
    static let modelOptions: [MLXModelOption] = [
        MLXModelOption(repoId: "mlx-community/gemma-3-1b-it-4bit", label: "Gemma 3 1B (iPhone, fastest)", sizeGB: 0.7, isPhoneFriendly: true),
        MLXModelOption(repoId: "mlx-community/LFM2-1.2B-4bit", label: "LFM2 1.2B (iPhone, fast)", sizeGB: 0.7, isPhoneFriendly: true),
        MLXModelOption(repoId: "mlx-community/Qwen3-1.7B-4bit", label: "Qwen3 1.7B (iPhone, best quality)", sizeGB: 1.0, isPhoneFriendly: true),
        MLXModelOption(repoId: "mlx-community/Qwen3-4B-Instruct-2507-4bit", label: "Qwen3 4B Instruct (Mac, recommended)", sizeGB: 2.3, isPhoneFriendly: false),
        MLXModelOption(repoId: "mlx-community/gemma-3-4b-it-4bit", label: "Gemma 3 4B (Mac)", sizeGB: 2.4, isPhoneFriendly: false),
        MLXModelOption(repoId: "mlx-community/Qwen3-8B-4bit", label: "Qwen3 8B (Mac, 16 GB+)", sizeGB: 4.6, isPhoneFriendly: false),
        MLXModelOption(repoId: "mlx-community/Qwen3-30B-A3B-4bit", label: "Qwen3 30B-A3B (Mac, 32 GB+, best quality)", sizeGB: 17.2, isPhoneFriendly: false)
    ]

    /// Models offered in pickers on this device. iPhones skip the Mac-sized
    /// tier (4 GB+), which does not fit in phone memory.
    @MainActor
    static var offeredOptions: [MLXModelOption] {
        #if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .phone {
            return modelOptions.filter { $0.sizeGB < 4 }
        }
        #endif
        return modelOptions
    }

    static var isAvailable: Bool {
        MLXRunner.isAvailableOnThisRuntime
    }

    static func option(for repoId: String) -> MLXModelOption {
        modelOptions.first(where: { $0.repoId == repoId })
            ?? MLXModelOption(repoId: repoId, label: repoId, sizeGB: 0, isPhoneFriendly: false)
    }

    static func isDownloaded(_ repoId: String) async -> Bool {
        await MLXRunner.shared.isModelDownloaded(repoId: repoId)
    }

    static func isDownloadedSync(_ repoId: String) -> Bool {
        MLXRunner.isRepoDownloaded(repoId)
    }

    static func downloadedRepoIds() -> [String] {
        MLXRunner.downloadedRepoIds()
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
            ?? defaultRepoId
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
    static func complete(
        settings: AISettings,
        messages: [[String: String]],
        maxTokens: Int
    ) async throws -> String {
        // Only use settings.model as a repo id when it actually looks like one (contains "/").
        // A leaked cloud model id (e.g. "claude-sonnet-4-5") must not be passed to MLX.
        let modelRepo = settings.model?.nilIfEmpty.flatMap { $0.contains("/") ? $0 : nil }
        let repoId = settings.localModelPath?.nilIfEmpty
            ?? modelRepo
            ?? defaultRepoId
        await MLXRunner.shared.selectDownloadedModel(preferredRepoId: repoId)

        let resolvedMaxTokens = settings.mlxMaxTokens ?? maxTokens

        return try await MLXRunner.shared.complete(
            messages: messages,
            maxTokens: resolvedMaxTokens,
            temperature: settings.mlxTemperature.map { Float($0) },
            topP: settings.mlxTopP.map { Float($0) },
            repetitionPenalty: settings.mlxRepetitionPenalty.map { Float($0) },
            repetitionContextSize: settings.mlxRepetitionContextSize
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
            ?? defaultRepoId
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
