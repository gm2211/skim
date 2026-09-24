# Shared local inference policy

Native iOS and the desktop/plugin Swift adapters import this dependency-free
package for model-family detection, turn terminators, thinking-template flags,
sampling defaults, template cache readiness, and response cleanup. Model loading, generation APIs, model
selection, transport, and per-request sampling overrides remain in the adapters.

The presets preserve the existing native iOS values. Cleanup removes leading reasoning
blocks and trailing known family turn terminators; it does not remove arbitrary HTML tags,
generic type parameters, comparison expressions, or literal control tokens inside model answers.

Run the focused policy tests with `swift test --package-path shared/SkimInferencePolicy`.

Template readiness follows the resolved swift-transformers 1.0 loader: a standalone Jinja/JSON template or supported embedded string/default named template must be usable. It checks presence and selection, not Jinja execution. Incomplete existing caches remain selected for repair; downloading adds missing templates without deleting weights.
