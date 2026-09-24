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
importance score adjustment. Both platforms call this policy before freezing
edition-local groups; provider calls, JSON decoding and persistence stay in adapters.
Scalar inputs and caller-owned UTF-8 bytes cross a fixed C ABI. No allocation or platform runtime
crosses the boundary. Both language test suites consume the contract at
`shared/fixtures/story-policy.json` and `shared/fixtures/semantic-policy.json`.
`shared/fixtures/semantic-model-failure.json` records a real local-model failure
on synthetic reports, replayed by both adapters. It proves rejection, not model quality.

Feature extraction, exact-match detection, candidate tie-breaking and selection,
preference inputs, article identity seeds, persistence and migrations remain
platform adapters or separate implementations. This is a bounded shared policy,
not completion of the domain-core migration. Existing story memberships and
frozen editions are not rewritten by this extraction.
