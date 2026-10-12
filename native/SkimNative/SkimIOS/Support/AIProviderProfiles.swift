import Foundation
import SkimCore

/// Keeps each AI provider's own API key, endpoint, and model, so switching
/// away and back restores them (spec: ai-providers/keys-kept-per-provider).
/// `AISettings` holds only the active provider's values; the others wait here,
/// keys in the Keychain and the rest in UserDefaults.
enum AIProviderProfiles {
    private static let keychainService = "com.skim.native.provider-keys"
    private static let defaultsPrefix = "skim.aiProviderProfile."

    /// Providers whose credentials are stashed. On-device providers have none,
    /// and MLX keeps its own model in `localModelPath`.
    static let credentialProviders: Set<String> = ["claude-subscription", "anthropic", "xai", "openai", "openrouter", "custom"]

    struct Profile: Codable, Equatable {
        var model: String?
        var endpoint: String?
    }

    /// `ai` switched to `provider`: the outgoing provider's key, endpoint, and
    /// model are saved, and the incoming provider's saved ones restored.
    static func switching(_ ai: AISettings, to provider: String, defaults: UserDefaults = .standard) -> AISettings {
        guard provider != ai.provider else { return ai }
        if credentialProviders.contains(ai.provider) {
            save(ai, defaults: defaults)
        }
        var next = ai
        next.provider = provider
        guard credentialProviders.contains(provider) else {
            // On-device providers take no key, and MLX reads its own model
            // from `localModelPath`, so nothing of the cloud provider stays.
            next.apiKey = nil
            next.endpoint = nil
            next.model = nil
            return next
        }
        next.apiKey = NativeKeychain.get(service: keychainService, account: provider)
        let profile = load(provider, defaults: defaults)
        next.endpoint = profile?.endpoint
        next.model = profile?.model
        return next
    }

    static func save(_ ai: AISettings, defaults: UserDefaults = .standard) {
        if let key = ai.apiKey, !key.isEmpty {
            NativeKeychain.set(key, service: keychainService, account: ai.provider)
        } else {
            NativeKeychain.delete(service: keychainService, account: ai.provider)
        }
        let profile = Profile(model: ai.model, endpoint: ai.endpoint)
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: defaultsPrefix + ai.provider)
        }
    }

    static func load(_ provider: String, defaults: UserDefaults = .standard) -> Profile? {
        guard let data = defaults.data(forKey: defaultsPrefix + provider) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }
}
