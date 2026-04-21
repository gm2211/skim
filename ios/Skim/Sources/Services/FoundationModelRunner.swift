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
/// `@available(iOS 26.0, macOS 15.1, *)` so the app still builds and runs on
/// iOS 17+ hosts (falls back to the "unavailable" branch).
actor FoundationModelRunner {
    static let shared = FoundationModelRunner()

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

    /// True only on iOS 26+ devices whose `SystemLanguageModel.default.isAvailable`
    /// reports true (i.e. Apple Intelligence is provisioned and enabled).
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 15.1, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
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
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 15.1, *) {
            guard SystemLanguageModel.default.isAvailable else {
                throw FMError.unavailable("Apple Intelligence is not enabled on this device")
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
    }

    /// Guided-generation triage path. Returns decoded `AIService.TriageItem`s
    /// without string-JSON parsing. Available only on iOS 26+.
    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 15.1, *)
    func triageStructured(
        systemPrompt: String,
        userPrompt: String
    ) async throws -> [AIService.TriageItem] {
        guard SystemLanguageModel.default.isAvailable else {
            throw FMError.unavailable("Apple Intelligence is not enabled on this device")
        }

        ensureBackgroundObserver()

        let session = self.session(for: systemPrompt)
        let response = try await session.respond(
            to: userPrompt,
            generating: TriageResponse.self
        )
        let payload = Self.extractGenerable(from: response, as: TriageResponse.self)
        return payload.triage.map { item in
            AIService.TriageItem(
                id: item.id,
                priority: min(5, max(1, item.priority)),
                reason: item.reason
            )
        }
    }
    #endif

    // MARK: - Session management

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 15.1, *)
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

    @available(iOS 26.0, macOS 15.1, *)
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

    @available(iOS 26.0, macOS 15.1, *)
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
