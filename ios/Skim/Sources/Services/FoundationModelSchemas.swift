#if canImport(FoundationModels)
import FoundationModels

/// Typed schemas for Apple Foundation Models guided generation.
///
/// These mirror `AIService.TriageItem` / `AIService.TriageResponse` but are
/// annotated with `@Generable` so `LanguageModelSession.respond(to:, generating:)`
/// can produce them directly, avoiding string JSON parsing.
@available(iOS 26.0, macOS 15.1, *)
@Generable
struct TriageItem {
    let id: String
    let priority: Int
    let reason: String
}

@available(iOS 26.0, macOS 15.1, *)
@Generable
struct TriageResponse {
    let triage: [TriageItem]
}
#endif
