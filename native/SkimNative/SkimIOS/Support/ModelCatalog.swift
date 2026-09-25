import Foundation
import SkimCore

/// One selectable entry in an inline model picker menu.
struct ModelChoice: Identifiable, Hashable {
    var id: String
    var label: String
    var isAvailable: Bool
    var detail: String?
}

/// The set of choices available for a given provider: either a concrete list
/// (fetched remotely or built from the local MLX catalog) or a fixed single
/// value with nothing else to pick (Apple Intelligence, a custom endpoint's
/// free-text model).
enum ModelChoices {
    case list([ModelChoice])
    case fixed(String)
}

/// Provider-independent catalog of selectable models, shared by every inline
/// model picker surface (Quick Catch-up, Ask Skim chat, Summarize, Today).
/// Kept free of SwiftUI so it stays trivially unit-testable.
enum ModelCatalog {

    // MARK: - Current selection

    /// The model id currently in effect for `ai`, matching the precedence
    /// `NativeMLX.complete`/`SettingsSheet` use to resolve an MLX repo id.
    static func currentID(_ ai: AISettings) -> String? {
        switch ai.provider {
        case "mlx":
            return ai.localModelPath?.nilIfEmpty ?? ai.model?.nilIfEmpty ?? NativeMLX.defaultRepoId
        default:
            return ai.model?.nilIfEmpty
        }
    }

    /// A short, human-readable label for the current selection, for the
    /// compact inline picker button and the read-only chat-override display.
    static func currentLabel(_ ai: AISettings) -> String {
        switch ai.provider {
        case "mlx":
            let repoId = currentID(ai) ?? NativeMLX.defaultRepoId
            return NativeMLX.option(for: repoId).label
        case "foundation-models":
            return "Apple Intelligence"
        default:
            return ai.model?.nilIfEmpty ?? "Default model"
        }
    }

    // MARK: - Choice lists

    /// Pure MLX catalog builder: the shipped model list, marked by download
    /// state, plus a synthesized "(legacy)" entry when `current` has fallen
    /// out of the catalog. Mirrors `MLXSettingsPanel.pickerOptions`.
    static func mlxChoices(downloaded: Set<String>, current: String) -> [ModelChoice] {
        var choices = NativeMLX.modelOptions.map { option in
            ModelChoice(
                id: option.repoId,
                label: option.label,
                isAvailable: downloaded.contains(option.repoId),
                detail: nil
            )
        }
        if !choices.contains(where: { $0.id == current }) {
            let legacy = NativeMLX.option(for: current)
            choices.append(
                ModelChoice(
                    id: legacy.repoId,
                    label: "\(legacy.repoId) (legacy)",
                    isAvailable: downloaded.contains(legacy.repoId),
                    detail: nil
                )
            )
        }
        return choices
    }

    /// In-memory cache for a remote provider's fetched model list, so
    /// reopening an inline picker within the same session doesn't refetch on
    /// every appearance. Keyed by provider; a 10-minute TTL bounds staleness.
    @MainActor
    private static var remoteCache: [String: (choices: [ModelChoice], fetchedAt: Date)] = [:]
    private static let cacheTTL: TimeInterval = 10 * 60

    /// The selectable choices for `ai`'s current provider. MLX resolves
    /// synchronously from local download state; remote providers fetch (and
    /// cache) their live model list; fixed providers return a single value.
    /// A failed remote fetch degrades to a single-entry list holding the
    /// currently configured model, so the menu still renders something.
    @MainActor
    static func choices(for ai: AISettings) async -> ModelChoices {
        switch ai.provider {
        case "mlx":
            let downloaded = Set(NativeMLX.downloadedRepoIds())
            let current = currentID(ai) ?? NativeMLX.defaultRepoId
            return .list(mlxChoices(downloaded: downloaded, current: current))

        case "claude-subscription", "xai", "openai":
            let current = currentID(ai)
            if let cached = remoteCache[ai.provider], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
                return .list(cached.choices)
            }
            do {
                let models: [AIModelInfo]
                if ai.provider == "claude-subscription" {
                    models = try await NativeAI.fetchAnthropicModels(settings: ai)
                } else {
                    models = try await NativeAI.fetchOpenAICompatibleModels(settings: ai)
                }
                var built = models.map { ModelChoice(id: $0.id, label: $0.displayName, isAvailable: true, detail: nil) }
                if let current = current?.nilIfEmpty, !built.contains(where: { $0.id == current }) {
                    built.append(ModelChoice(id: current, label: current, isAvailable: true, detail: nil))
                }
                remoteCache[ai.provider] = (built, Date())
                return .list(built)
            } catch {
                let fallback = current?.nilIfEmpty.map { [ModelChoice(id: $0, label: $0, isAvailable: true, detail: nil)] } ?? []
                return .list(fallback)
            }

        case "foundation-models":
            return .fixed("Apple Intelligence")

        default:
            return .fixed(ai.model?.nilIfEmpty ?? "Default model")
        }
    }

    // MARK: - Applying a selection

    /// Applies a chosen model id to `ai`, returning the updated settings.
    /// MLX writes both `localModelPath` and `model` (matching SettingsSheet's
    /// own MLX selection binding, since `NativeMLX.complete` prefers
    /// `localModelPath`). `forChat` additionally clears any chat-specific
    /// model override so the inline pick takes effect immediately rather
    /// than being shadowed by a stale `chatModel`.
    static func applying(_ id: String, to ai: AISettings, forChat: Bool) -> AISettings {
        var next = ai
        if ai.provider == "mlx" {
            next.localModelPath = id.nilIfEmpty
            next.model = id.nilIfEmpty
        } else {
            next.model = id.nilIfEmpty
        }
        if forChat {
            next.chatModel = nil
        }
        return next
    }

    /// Whether chat is currently pinned away from the base AI settings via
    /// Settings' chat override (a different provider and/or a different
    /// model than the one this catalog would otherwise show).
    static func hasChatOverride(_ ai: AISettings) -> Bool {
        if let provider = ai.chatProvider?.nilIfEmpty, provider != "same" {
            return true
        }
        return ai.chatModel?.nilIfEmpty != nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
