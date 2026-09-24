# Shared story policy

The functional Tauri desktop and native iOS app compile the same
`Sources/SkimStoryPolicy/SkimStoryPolicy.c` into their binaries. Desktop builds it
through `src-tauri/build.rs` and calls the safe Rust adapter in
`src-tauri/src/db/story_policy.rs`. Native `SkimCore` declares this local Swift
package as a dependency and calls it from `StoryClustering.swift`.

This module owns lexical confidence weighting, default matching thresholds,
duplicate/coverage/update/borderline classification, source/recency ranking,
single-source protection and the stable FNV identity hash. It also owns the
semantic edition prompt, bounded candidate count, numeric group validation and
importance score adjustment, pair-verification instructions and deterministic complete-clique partitioning. Every pair in an accepted merged group needs positive verification; a connected chain is insufficient. Both platforms call this policy before freezing
edition-local groups; provider calls, JSON decoding and persistence stay in adapters.
Scalar inputs and caller-owned UTF-8 bytes cross a fixed C ABI. No allocation or platform runtime
crosses the boundary. Both language test suites consume the contract at
`shared/fixtures/story-policy.json` and `shared/fixtures/semantic-policy.json`.
`shared/fixtures/semantic-model-failure.json` records a real local-model failure
on synthetic reports, replayed by both adapters. It proves rejection, not model quality.
`semantic-pairs.json` checks clique decisions; `semantic-verification-responses.json` replays actual local-model responses through both adapters. Pools over 64 candidates or more than 64 requested pairs use full deterministic fallback. Both calls share one total 30-second deadline.

Feature extraction, exact-match detection, candidate tie-breaking and selection,
preference inputs, article identity seeds, persistence and migrations remain
platform adapters or separate implementations. This is a bounded shared policy,
not completion of the domain-core migration. Existing story memberships and
frozen editions are not rewritten by this extraction.

Verified fragments use the shared consequence-rating prompt and metric validation. Each platform sends one event per request, keeps one total deadline, and publishes the rating stage atomically; failure retains verified membership with neutral importance. Model output never owns member references.
