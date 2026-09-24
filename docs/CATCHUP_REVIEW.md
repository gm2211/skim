# Catch-up experience review — 2026-09-24

The acceptance target is a fast, attractive newspaper that groups related coverage, supports deeper summaries and article/library questions, and lets chat find relevant articles. This review does not claim that the full target or shared-core migration is complete.

## Changes verified in this slice

- Today fills the available desktop space until a reference is opened, then becomes a compact reading column. Larger newspaper layouts use aligned columns; narrow layouts keep a single readable column. Translucent surfaces and the existing native window material remain in place.
- Each story appears once. All reports, including syndicated copies, stay available behind an explicit disclosure. Headlines are keyboard-operable buttons, controls share dimensions, and read stories retain legible contrast.
- Empty editions can fill after feed refresh. Populated editions remain immutable. Previously consumed stories do not return merely because another syndicated copy arrived; a new material revision can bring them back.
- Fresh native databases receive the lede column. The migration previously attempted to alter the table before creating it.
- Library chat searches the complete selected scope before limiting results, including URLs and cached reader bodies. Word boundaries prevent “AI” from matching “daily.” Specific unmatched questions receive an honest no-match result; broad catch-up requests can still use recent coverage.
- Detailed summary word counts reach the provider settings and cache key. Late lede events and read-save results remain scoped to their originating edition. Failed saves and load errors are visible and retryable.

## Evidence and limits

138 frontend tests, 103 Rust library tests, and 71 Swift package tests pass. TypeScript, the Vite production build, and the iOS Simulator build pass. The Rust local-model integration test remains excluded because its separate GGUF model is unavailable.

The in-app browser exercised the real Today React components in an isolated fixture harness at desktop width and 375×667. Reviewed collapsed/expanded references, long publication names, keyboard headline activation, compact reader transition, loading, empty, error and completed states. The harness used fixture command responses and a placeholder reader panel: it proves layout and interaction boundaries, not live journalism quality, real-provider answers, or native window compositing.

## Remaining acceptance

`skim-do2h` tracks semantic grouping and importance on real feed coverage: low-overlap paraphrases, similar topics that are separate events, and important single-source stories. Current lexical grouping and source-count/recency ranking are insufficient proof of those requirements.

`skim-dz1g` remains open for installed-app hands-on acceptance and live-provider quality. Initial installed-app exploration stopped at Terms acceptance; the current attempt to reconnect to the native app timed out. No acceptance was inferred or clicked.

`skim-62qe` tracks sharing the shipping desktop/iOS domain implementation. Rust desktop and Swift iOS still execute separate cores. Matching fixes and tests on both platforms are parity evidence, not shared implementation.
