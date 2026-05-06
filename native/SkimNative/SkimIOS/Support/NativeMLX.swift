import Foundation
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

    static let modelOptions: [MLXModelOption] = [
        MLXModelOption(repoId: "mlx-community/gemma-3-1b-it-4bit", label: "Gemma 3 1B (recommended for iPhone)", sizeGB: 0.7, isPhoneFriendly: true),
        MLXModelOption(repoId: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", label: "Qwen 2.5 1.5B", sizeGB: 1.0, isPhoneFriendly: true),
        MLXModelOption(repoId: "mlx-community/Llama-3.2-1B-Instruct-4bit", label: "Llama 3.2 1B", sizeGB: 0.8, isPhoneFriendly: true),
        MLXModelOption(repoId: "mlx-community/gemma-3-4b-it-4bit", label: "Gemma 3 4B", sizeGB: 2.4, isPhoneFriendly: false),
        MLXModelOption(repoId: "mlx-community/Qwen2.5-3B-Instruct-4bit", label: "Qwen 2.5 3B", sizeGB: 2.0, isPhoneFriendly: false),
        MLXModelOption(repoId: "mlx-community/Llama-3.2-3B-Instruct-4bit", label: "Llama 3.2 3B", sizeGB: 2.0, isPhoneFriendly: false),
        MLXModelOption(repoId: "mlx-community/Phi-3.5-mini-instruct-4bit", label: "Phi-3.5 Mini", sizeGB: 2.3, isPhoneFriendly: false)
    ]

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

    static func complete(
        settings: AISettings,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        jsonMode: Bool
    ) async throws -> String {
        let repoId = settings.localModelPath?.nilIfEmpty
            ?? settings.model?.nilIfEmpty
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
        let repoId = settings.localModelPath?.nilIfEmpty
            ?? settings.model?.nilIfEmpty
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
