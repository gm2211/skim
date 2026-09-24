# Shared local inference policy

Native iOS and the desktop/plugin Swift adapters import this package, which has no external package dependencies,
for model-family detection, turn terminators, thinking-template flags,
sampling defaults, template cache readiness, and response cleanup. Model loading, generation APIs, model
selection, transport, and per-request sampling overrides remain in the adapters.

`LocalChatMessages` preserves structured MLX turns and handles model-family system-message rules. On iOS/macOS 26, `FoundationChatMessages` builds a fresh typed Foundation Models transcript from prior user/assistant turns and separates the latest user prompt. Both the production desktop helper and native iOS use it. Explicit caller instructions remain authoritative, including JSON or retry additions; the original system turn is not duplicated. Missing latest-user turns and unsupported historical roles fail instead of being silently coerced. Nil/empty messages retain the scalar request contract. Transcript construction does not load a model or generate historical replies.

Foundation transcript tests require an Xcode SDK containing FoundationModels and an iOS/macOS 26 host. The regular policy tests also run without that framework; check that the two Foundation XCTest cases execute when verifying this integration. Compilation and typed-entry tests do not prove live Foundation Models quality or availability.

The presets preserve the existing native iOS values. Cleanup removes leading reasoning
blocks and trailing known family turn terminators; it does not remove arbitrary HTML tags,
generic type parameters, comparison expressions, or literal control tokens inside model answers.

Run the focused policy tests with `swift test --package-path shared/SkimInferencePolicy`.

Template readiness follows the resolved swift-transformers 1.0 loader: a standalone Jinja/JSON template or supported embedded string/default named template must be usable. It checks presence and selection, not Jinja execution. Incomplete existing caches remain selected for repair; downloading adds missing templates without deleting weights.
