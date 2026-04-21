import Foundation

/// Picks which AI tier to use for a given task.
/// Tiers (descending on-device preference):
///   1. Apple Foundation Models (iOS 26+, Apple Intelligence device)
///   2. MLX local model (if downloaded)
///   3. Claude subscription (OAuth bearer token)
///   4. Anthropic API key (fallback)
///   5. OpenAI / Ollama (manual config)
enum AITier: String, CaseIterable, Identifiable {
    case foundationModels
    case mlx
    case claudeSubscription
    case anthropicApiKey
    case openai
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .foundationModels: return "Apple Intelligence (on-device)"
        case .mlx: return "On-device model (MLX)"
        case .claudeSubscription: return "Claude subscription"
        case .anthropicApiKey: return "Anthropic API key"
        case .openai: return "OpenAI"
        case .ollama: return "Ollama (LAN)"
        }
    }
}

enum AITask {
    case triage       // batch classify, small JSON out
    case summarize    // 30-word output
    case chat         // long context, multi-turn, streaming
    case themes       // cross-article synthesis
    case autoOrganize // folder-name suggestion
}

@MainActor
final class ModelRouter: ObservableObject {
    @Published var preferredTier: AITier = .claudeSubscription
    @Published var mlxModelAvailable: Bool = false
    @Published var foundationModelsAvailable: Bool = false

    static let shared = ModelRouter()

    init() {
        // Probe Apple Foundation Models availability at startup so the
        // Settings UI can reflect the real state. The runner itself is an
        // actor, so we hop to it asynchronously and publish on the main actor.
        Task { @MainActor in
            self.foundationModelsAvailable = await FoundationModelRunner.shared.isAvailable
        }
        // Reflect current on-disk MLX weight state. `isModelDownloaded` is a
        // nonisolated property (FileManager check only), safe to read sync.
        self.mlxModelAvailable = MLXRunner.shared.isModelDownloaded
    }

    /// Re-check on-disk MLX weights. Call after downloads / deletions so the
    /// Settings UI updates without a relaunch.
    func refreshMLXAvailability() {
        self.mlxModelAvailable = MLXRunner.shared.isModelDownloaded
    }

    /// For a given task, choose the best available tier based on user preference,
    /// tier availability, and the task's needs.
    func tier(for task: AITask) -> AITier {
        switch task {
        case .chat, .themes, .autoOrganize:
            // Quality-sensitive tasks — prefer cloud unless user forced on-device.
            if preferredTier == .foundationModels, foundationModelsAvailable { return .foundationModels }
            if preferredTier == .mlx, mlxModelAvailable { return .mlx }
            return cloudFallback()
        case .triage, .summarize:
            // Good fit for on-device when available.
            if foundationModelsAvailable, preferredTier != .claudeSubscription {
                return .foundationModels
            }
            if mlxModelAvailable, preferredTier != .claudeSubscription {
                return .mlx
            }
            return cloudFallback()
        }
    }

    private func cloudFallback() -> AITier {
        if preferredTier == .openai || preferredTier == .ollama || preferredTier == .anthropicApiKey {
            return preferredTier
        }
        return .claudeSubscription
    }
}
