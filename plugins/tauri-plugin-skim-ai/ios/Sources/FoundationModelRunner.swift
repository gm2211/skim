import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Foundation Models tier (iOS 26+).
///
/// Bridges `AIService` → `SystemLanguageModel` via a cached `LanguageModelSession`.
/// The whole FM surface is gated behind `#if canImport(FoundationModels)` and
/// `@available(iOS 26.0, macOS 26.0, *)` so the app still builds and runs on
/// iOS 17+ hosts (falls back to the "unavailable" branch).
actor FoundationModelRunner {
    static let shared = FoundationModelRunner()

    struct AvailabilityPayload: Sendable {
        let available: Bool
        let status: String
        let message: String

        var dictionary: [String: Any?] {
            [
                "available": available,
                "status": status,
                "message": message,
            ]
        }
    }

    enum FMError: LocalizedError {
        case unavailable(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return "Apple Foundation Models unavailable: \(reason)"
            case .emptyResponse: return "Apple Foundation Models returned an empty response"
            }
        }
    }

    // Storage is held as `Any?` so the enclosing actor stays available on
    // iOS 17+; it is only unwrapped under the availability gate.
    private var cachedSessionAny: Any?
    private var cachedInstructions: String?
    private var backgroundObserverStarted = false

    init() {}

    // MARK: - Availability

    /// Rich availability for Settings. This keeps real devices from being
    /// flattened into a vague "device/OS" failure when Apple Intelligence is
    /// disabled or the model assets are still provisioning.
    var availability: AvailabilityPayload {
        currentAvailability()
    }

    var isAvailable: Bool {
        currentAvailability().available
    }

    private func currentAvailability() -> AvailabilityPayload {
        #if targetEnvironment(simulator)
        return AvailabilityPayload(
            available: false,
            status: "simulator",
            message: "Apple Intelligence does not run in the iOS Simulator. Test Foundation Models on a real iPhone, or use MLX/cloud providers here."
        )
        #else
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return AvailabilityPayload(
                    available: true,
                    status: "available",
                    message: "Apple Intelligence is enabled and the on-device Foundation Model is ready."
                )
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return AvailabilityPayload(
                        available: false,
                        status: "device-not-eligible",
                        message: "This device is not eligible for Apple Intelligence Foundation Models."
                    )
                case .appleIntelligenceNotEnabled:
                    return AvailabilityPayload(
                        available: false,
                        status: "apple-intelligence-disabled",
                        message: "Apple Intelligence is off. Enable it in Settings, then relaunch Skim."
                    )
                case .modelNotReady:
                    return AvailabilityPayload(
                        available: false,
                        status: "model-not-ready",
                        message: "Apple Intelligence is enabled, but the on-device model is still downloading or preparing. Keep the phone on power/Wi-Fi and try again shortly."
                    )
                @unknown default:
                    return AvailabilityPayload(
                        available: false,
                        status: "unknown-unavailable",
                        message: "Foundation Models are unavailable for a system reason this build does not recognize yet."
                    )
                }
            @unknown default:
                return AvailabilityPayload(
                    available: false,
                    status: "unknown",
                    message: "Foundation Models returned an unknown availability state."
                )
            }
        }
        #endif
        return AvailabilityPayload(
            available: false,
            status: "unsupported-os",
            message: "Apple Foundation Models require iOS 26 or later on supported Apple Intelligence hardware."
        )
        #endif
    }

    // MARK: - Completion

    /// Free-form completion. Routes through a cached `LanguageModelSession`.
    /// `jsonMode` currently just nudges the model toward JSON via the system prompt —
    /// typed guided generation is exposed via `triageStructured(...)`.
    func complete(
        systemPrompt: String,
        userPrompt: String,
        jsonMode: Bool,
        maxTokens: Int
    ) async throws -> String {
        #if targetEnvironment(simulator)
        throw FMError.unavailable("Apple Intelligence is not available in the iOS Simulator. Use the MLX provider instead, or test on a real iPhone with Apple Intelligence enabled.")
        #else
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let status = currentAvailability()
            guard status.available else {
                throw FMError.unavailable(status.message)
            }

            ensureBackgroundObserver()

            let effectiveSystem = jsonMode
                ? systemPrompt + "\n\nRespond with a single valid JSON object. No prose, no markdown fences."
                : systemPrompt

            let session = self.session(for: effectiveSystem)
            let options = GenerationOptions(maximumResponseTokens: maxTokens)

            let response = try await session.respond(to: userPrompt, options: options)
            let text = Self.extractText(from: response)
            guard !text.isEmpty else { throw FMError.emptyResponse }
            return text
        } else {
            throw FMError.unavailable("Requires iOS 26 or later")
        }
        #else
        throw FMError.unavailable("FoundationModels framework not available in this build")
        #endif
        #endif
    }

    // MARK: - Session management

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func session(for instructions: String) -> LanguageModelSession {
        if let cached = cachedSessionAny as? LanguageModelSession,
           cachedInstructions == instructions {
            return cached
        }
        let new = LanguageModelSession(instructions: instructions)
        cachedSessionAny = new
        cachedInstructions = instructions
        return new
    }
    #endif

    private func dropSession() {
        cachedSessionAny = nil
        cachedInstructions = nil
    }

    /// Lazily wire a background listener that drops the cached session to free
    /// memory. Called on first `complete(...)` instead of `init`, so we avoid
    /// touching UIKit from a cold actor bootstrap and so tests can ignore it.
    private func ensureBackgroundObserver() {
        #if canImport(UIKit)
        guard !backgroundObserverStarted else { return }
        backgroundObserverStarted = true
        let notifications = NotificationCenter.default.notifications(
            named: UIApplication.didEnterBackgroundNotification
        )
        Task { [weak self] in
            for await _ in notifications {
                guard let self else { return }
                await self.dropSession()
            }
        }
        #endif
    }

    // MARK: - Response shape helpers
    //
    // The concrete return type of `LanguageModelSession.respond(to:)` shifted
    // between Foundation Models betas — some seeds expose a direct `.content`
    // String, others wrap it in a `Response` struct with `.content` or `.text`.
    // We reflect on what's present so this compiles against whichever headers
    // the user's Xcode 26 ships.

    @available(iOS 26.0, macOS 26.0, *)
    private static func extractText(from response: Any) -> String {
        if let s = response as? String { return s }
        let mirror = Mirror(reflecting: response)
        for label in ["content", "text", "output"] {
            if let child = mirror.children.first(where: { $0.label == label }) {
                if let s = child.value as? String { return s }
                let inner = Mirror(reflecting: child.value)
                if let t = inner.children.first(where: { $0.label == "text" })?.value as? String {
                    return t
                }
            }
        }
        return String(describing: response)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func extractGenerable<T>(from response: Any, as _: T.Type) -> T {
        if let typed = response as? T { return typed }
        let mirror = Mirror(reflecting: response)
        for label in ["content", "value", "output"] {
            if let child = mirror.children.first(where: { $0.label == label }),
               let typed = child.value as? T {
                return typed
            }
        }
        fatalError("FoundationModelRunner: could not extract \(T.self) from response of type \(Swift.type(of: response))")
    }
}
