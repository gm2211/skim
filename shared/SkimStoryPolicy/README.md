# Shared story and summary policy

The functional Tauri desktop and native iOS app compile the same
`Sources/SkimStoryPolicy/SkimStoryPolicy.c` into their binaries. Desktop builds it
through `src-tauri/build.rs` and calls the safe Rust adapter in
`src-tauri/src/db/story_policy.rs`. Native `SkimCore` declares this local Swift
package as a dependency and calls it from `StoryClustering.swift`, `TodaySemantic.swift` and `AIRequestPolicy.swift`.

This module owns lexical confidence weighting, default matching thresholds,
duplicate/coverage/update/borderline classification, source/recency ranking,
single-source protection and the stable FNV identity hash. It also owns the
semantic edition prompt, bounded candidate count, numeric group validation and
importance score adjustment, pair-verification instructions and deterministic complete-clique partitioning, isolated event-rating instructions/validation, and source-verified Today preview selection/retry policy. Every pair in an accepted merged group needs positive verification; a connected chain is insufficient. Both platforms call this policy before freezing
edition-local groups; provider calls, JSON decoding and persistence stay in adapters.
Scalar inputs and caller-owned UTF-8 bytes cross a fixed C ABI. The excerpt validator makes bounded temporary allocations internally and frees them before returning; no allocation ownership or platform runtime crosses the boundary. Both language test suites consume the contract at
`shared/fixtures/story-policy.json` and `shared/fixtures/semantic-policy.json`.
`shared/fixtures/semantic-model-failure.json` records a real local-model failure
on synthetic reports, replayed by both adapters. It proves rejection, not model quality.
`semantic-pairs.json` checks clique decisions; `semantic-verification-responses.json` replays actual local-model responses through both adapters. Pools over 64 candidates or more than 64 requested pairs use full deterministic fallback. Grouping, pair verification and sequential per-event ratings share one total 30-second deadline. Failure before verification falls back deterministically; rating-stage failure retains verified membership with neutral importance for split groups.

Feature extraction, exact-match detection, candidate tie-breaking and selection,
preference inputs, article identity seeds, persistence and migrations remain
platform adapters or separate implementations. This is a bounded shared policy,
not completion of the domain-core migration. Existing story memberships and
frozen editions are not rewritten by this extraction.

Verified fragments use the shared consequence-rating prompt and metric validation. Each platform sends one event per request, keeps one total deadline, and publishes the rating stage atomically; failure retains verified membership with neutral importance. Model output never owns member references.

## Source-verified Today previews

Both adapters use the same selection prompt, plaintext-retry prompt, source/excerpt bounds, evidence version and exact-passage validator. Each preview must match one bounded source body; report headers and cross-report combinations are not evidence. Adapters pass raw UTF-8 source text to C, which normalizes whitespace while retaining paragraph boundaries. Excerpts are canonical whitespace-normalized UTF-8. Validation requires conservative sentence/paragraph boundaries, one to three sentences, at most 60 words and 600 Unicode scalars, no square-bracket reference markup, and source input no larger than 65,536 bytes. The scan is bounded, including abbreviation checks.

A successful but invalid JSON response receives at most one plaintext retry using the same configured provider/model, temperature zero and 300-token output limit. The entire retry passes the same validator; provider errors do not trigger another call. The Rust and Swift adapters each run the shared `today-excerpts.json` corpus. They preserve old preview bytes but hide noncurrent evidence versions, and stamp the current version only on newly verified previews. Frozen snapshots and reading state are unchanged. This does not verify source truth, editorial relevance or completeness, and does not change detailed summaries or chat.

## Detailed-summary style

`skim_summary_style_prompt` returns immutable static UTF-8 instructions for concise, detailed/descriptive, casual and technical tones. Unknown or absent tones fall back to concise. Both adapters map invalid embedded-NUL input to that fallback. The common text preserves source uncertainty, attribution, negation and event timing and treats source text as untrusted data. Rust `article_summary_system_prompt` and native `AIRequestPolicy.summaryInstructions` call it in the actual summary paths. Their JSON/plain-text wrappers and custom-instruction precedence remain adapter policy. The shared `summary-style.json` corpus characterizes both bindings.

`skim_summary_plan` owns requested words, bullet ranges and default output budgets. Presets ignore stale custom values; unknown lengths and invalid custom values resolve to the complete Short plan. The custom range is 20–1000, validated as int64 before narrowing or arithmetic. Both bindings run the 19-case `summary-plan.json` corpus. Both caches use version 4 and the full effective plan, so fallback Short and valid custom 30 cannot collide despite equal word counts. Native explicit MLX token overrides remain platform policy. This bounds requests without guaranteeing output length, context fit or factual accuracy.

This shared instruction source removes duplication and conflicting directives; it does not make generated claims reliable. The [summary quality record](../../docs/releases/2026-09-24-summary-policy-quality.json) records remaining factual failures on small, independently reviewed local-model samples. Full-source evidence, compatible prompts and correct bindings are necessary but insufficient for output accuracy.

## Library-chat relevance

`skim_chat_rank` takes four UInt32 term masks (title, URL, source and body). It rewards distinct term coverage by 512 before field weights (6/4/2/1), so even the largest 32-term field bonus cannot let fewer matched terms outrank more. Both production retrieval adapters call it before limiting context to 15 articles; the nine-case `chat-ranking.json` fixture crosses both bindings. Tokenization, scope filtering, cache evidence selection and follow-up classification remain separate adapters. Native retrieval scans scoped rows without the previous 500-row visibility cutoff and retains only its best 15 rows.

## Release-path proof and remaining limits

Desktop **0.1.30** and iOS **0.1.13 (67)** artifacts contain **26 shared C symbols**, including summary style, length plan and bounds. The separate `SkimInferencePolicy` package contributes **71 shared Swift policy symbols each** to the desktop helper and iOS evidence. The bundled desktop helper's code section matches the freshly compiled helper; signing changes its whole-file digest. Exact hashes, the matching iOS executable/dSYM UUID, and Apple's processing/beta state are in the [release record](../../docs/releases/2026-09-24-summary-limits-release.json).

The signed desktop parent still stalls before `main()` in sandbox initialization, and the locked Mac blocks installed native interactive acceptance. Artifact inclusion, TestFlight availability, installed operation and full product parity remain distinct claims. Full Rust/Swift engine consolidation remains open; these shared policies do not replace platform inference, persistence or UI adapters.
