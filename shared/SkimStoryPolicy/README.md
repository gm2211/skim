# Shared story policy

The functional Tauri desktop and native iOS app compile the same
`Sources/SkimStoryPolicy/SkimStoryPolicy.c` into their binaries. Desktop builds it
through `src-tauri/build.rs` and calls the safe Rust adapter in
`src-tauri/src/db/story_policy.rs`. Native `SkimCore` declares this local Swift
package as a dependency and calls it from `StoryClustering.swift` and `TodaySemantic.swift`.

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

## Release-path proof and remaining limits

Desktop **0.1.26** and iOS **0.1.13 (63)** release inspection records **21 shared C symbols**. The separate `SkimInferencePolicy` package contributes **71 shared Swift policy symbols each** to the desktop helper and iOS evidence. The bundled desktop helper's code section matches the freshly compiled helper; signing changes its whole-file digest. Exact hashes and the matching iOS executable/dSYM UUID are in the [release record](../../docs/releases/2026-09-24-source-preview-release.json).

The [quality record](../../docs/releases/2026-09-24-source-preview-quality.json) covers limited real-model chronology probes and the current browser/backend integration. Five of six lead previews were verified; rejected source markup retained the publisher-snippet fallback. These selected samples do not establish general model accuracy. The signed desktop parent still stalls before `main()` in sandbox initialization, and the locked Mac blocks installed native interactive acceptance. Artifact inclusion, App Store Connect processing, installed operation and full product parity remain distinct claims. Full Rust/Swift engine consolidation remains open; these shared policies do not replace platform inference, persistence or UI adapters.
