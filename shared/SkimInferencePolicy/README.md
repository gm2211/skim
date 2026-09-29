# Shared local inference policy

Native iOS and the desktop/plugin Swift adapters import this package, which has no external package dependencies,
for model-family detection, turn terminators, thinking-template flags,
sampling defaults, template cache readiness, and response cleanup. Model loading, generation APIs, model
selection, transport, and per-request sampling overrides remain in the adapters.

`LocalChatMessages` preserves structured MLX turns and handles model-family system-message rules. On iOS/macOS 26, `FoundationChatMessages` builds a fresh typed Foundation Models transcript from prior user/assistant turns and separates the latest user prompt. Both the production desktop helper and native iOS use it. Explicit caller instructions remain authoritative, including JSON or retry additions; the original system turn is not duplicated. Missing latest-user turns and unsupported historical roles fail instead of being silently coerced. Nil/empty messages retain the scalar request contract. Transcript construction does not load a model or generate historical replies.

`LocalChatMessages.normalizedTurns` sits underneath `LocalChatMessages.prepare` (every caller gets it automatically) and repairs a raw turn sequence so it satisfies chat templates that require strict role alternation, e.g. Gemma's "Conversation roles must alternate" error: it merges a leading run of system turns into one, drops any assistant turn that appears before the first user turn (such as an injected article summary shown as the opening assistant turn), and merges consecutive same-role turns. A sequence that already alternates correctly passes through byte-identical.

`LocalModelTier` and `ChatContextBudget` scale grounded chat-with-article prompting to what a small on-device model can actually use well. `LocalModelTier.tier(for:)` buckets a repo id (compact/mid/large) by the billions-of-parameters token in its name (`<= 2.0` compact, `<= 4.5` mid, else large; unparseable repo ids default to the smallest/safest `.compact` bucket). `ChatContextBudget.forTier(_:)` returns the evidence/router/web-evidence character budgets and the answer `maxTokens` for that tier (compact 5000/2000/3000/360, mid 8000/2400/4200/500, large 12000/2400/4200/650).

`GroundedChatPrompt` builds the answer-first system instructions and the exact two-turn `[system, user]` message array (question last) sent to the model for chat-with-article: `systemPrompt(question:oneShot:)` asks for a direct first-sentence answer grounded strictly in the supplied article text, with no chatbot preamble, no headings, and no whole-article summary, using a longer allowance when the question itself asks for something broader (list/explain/detail/all/steps/why/summar[y|ize]). `build(system:articleContext:question:priorExchange:webBlock:)` assembles the user turn (article, optional web block, optional prior exchange truncated to 300 characters per side with a caller-supplied label such as "A" or "Earlier summary", then the question) and never duplicates the system turn. `samplingPreset(basedOn:)` derives chat-tuned sampling from a model's general-purpose preset: a lower, steadier temperature (0.2) and top-p (0.9), with the repetition penalty capped at 1.1 so short, naturally repetitive factual answers aren't over-penalized.

`ChatAnswerCleanup.clean(_:question:)` strips chatbot boilerplate that small local models tend to emit around an otherwise-good answer: leading openers ("Okay, here's my response:", "Sure!"), "Here's my answer: ..." lead-ins, header labels ("**Summary:**", "### Response"), an unpaired leading `**` left over from a stripped header, and trailing sign-offs ("Let me know if...", "Would you like..."). Only the very start and end of the text are touched — mid-text content, including markdown emphasis, is never modified. "summary" headers are only stripped when the question didn't itself ask for a summary/recap/tl;dr.

Foundation transcript tests require an Xcode SDK containing FoundationModels and an iOS/macOS 26 host. The regular policy tests also run without that framework; check that the two Foundation XCTest cases execute when verifying this integration. Compilation and typed-entry tests do not prove live Foundation Models quality or availability.

The presets preserve the existing native iOS values. Cleanup removes leading reasoning
blocks and trailing known family turn terminators; it does not remove arbitrary HTML tags,
generic type parameters, comparison expressions, or literal control tokens inside model answers.

Run the focused policy tests with `swift test --package-path shared/SkimInferencePolicy`.

Template readiness follows the resolved swift-transformers 1.0 loader: a standalone Jinja/JSON template or supported embedded string/default named template must be usable. It checks presence and selection, not Jinja execution. Incomplete existing caches remain selected for repair; downloading adds missing templates without deleting weights.
