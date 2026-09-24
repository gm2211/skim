# Catch-up experience review — 2026-09-24

The acceptance target is a fast, attractive newspaper that groups related coverage, supports deeper summaries and article/library questions, and lets chat find relevant articles. This review does not claim that the full target or shared-core migration is complete.

## Changes verified in this slice

- Today fills the available desktop space until a reference is opened, then becomes a compact reading column. Larger newspaper layouts use aligned columns; narrow layouts keep a single readable column. Translucent surfaces and the existing native window material remain in place.
- Each story appears once. All reports, including syndicated copies, stay available behind an explicit disclosure. Headlines are keyboard-operable buttons, controls share dimensions, and read stories retain legible contrast.
- Empty editions can fill after feed refresh. Populated editions remain immutable. Previously consumed stories do not return merely because another syndicated copy arrived; a new material revision can bring them back.
- Fresh native databases receive the lede column. The migration previously attempted to alter the table before creating it.
- Library chat searches the complete selected scope before limiting results, including URLs and cached reader bodies. Word boundaries prevent “AI” from matching “daily.” Specific unmatched questions receive an honest no-match result; broad catch-up requests can still use recent coverage.
- Detailed summary word counts reach the provider settings and cache key. Late lede events and read-save results remain scoped to their originating edition. Failed saves and load errors are visible and retryable.
- Follow-ups such as “summarize that” retain the last user topic and referenced articles after opening a source marks it read. Opening and closing a cited article returns to the preserved Ask conversation. Article questions receive the visible generated summary as bounded, untrusted context, with the original article as evidence.
- Meaningful headline clauses are retained, reordered proper nouns can corroborate the same event, and syndicated copies no longer remove single-source ranking protection. Version-2 derived features refresh lazily from raw articles; existing story memberships, revisions and frozen editions remain unchanged.
- Desktop and iOS now execute one `shared/SkimStoryPolicy` implementation for confidence, classification thresholds/decisions, base ranking, unique-source protection and the stable identity hash. Feature extraction, selection, preferences and persistence remain separate.

## Evidence and limits

142 frontend tests, 111 Rust library tests, and 76 Swift package tests pass. TypeScript and the Vite production build pass. The Rust local-model integration test remains excluded because its separate GGUF model is unavailable. Both ABI adapters execute one shared policy fixture corpus. Cache-upgrade regressions were verified to fail with the upgrade disabled and pass when restored.

The in-app browser exercised the real Today React components in an isolated fixture harness at desktop width and 375×667. Reviewed collapsed/expanded references, long publication names, keyboard headline activation, compact reader transition, loading, empty, error and completed states. The harness used fixture command responses and a placeholder reader panel: it proves layout and interaction boundaries, not live journalism quality, real-provider answers, or native window compositing.

Rendered QA for the subsequent chat-continuity fixes could not run: computer-control reports a locked Mac with no available apps or browsers. Component interaction tests pass; this does not substitute for the blocked rendered checks.

An isolated Rust devbridge and repository newsstand exercised actual commands against a disposable library: OPML imported four feeds, refresh ingested ten articles, the same empty edition filled with six current-day stories, and another refresh preserved the populated snapshot. An additional syndicated feed produced single cards with both coverage and duplicate references; consumption marked every reference read. This exposed and fixed a devbridge compilation defect: the lede command must use the crate's runtime-generic `AppHandle` alias. These are real backend integration checks with fixture journalism; semantic paraphrases still remain separate.

## Release evidence

- Native iOS **0.1.13 (55)** archived, exported and uploaded successfully. Archive metadata was checked; App Store Connect reports `IN_BETA_TESTING` for internal testers. Earlier build 54 was also uploaded and processed during this review; build 55 contains the final shared-policy, grouping and chat fixes.
- Desktop **0.1.19** built and signed; `codesign --verify --deep --strict` and bundle metadata passed. Installation remains pending.
- The earlier signed desktop smoke check could not start on this host: both the new 0.1.18 bundle and installed 0.1.17 stall in `_libsecinit_appsandbox` before `main()` or any helper child launches. A sampled process is blocked in `_xpc_pipe_routine` / `mach_msg2_trap`. This identifies a host startup blocker, not successful model inference. Current computer-control also reports the Mac is locked. Native runtime and installed-binary verification remain open.

The six shared policy functions appear in the desktop 0.1.19 symbol table and iOS build 55 dSYM. The iOS dSYM UUID matches the archived executable (`F6F8E50D-8154-323C-A926-2B5578C067A7`). Both release build graphs compile the same C source, SHA-256 `0fef47ad1dc5d4f8bbf51e9e78259f581ed8e2a9c683e13632d77327382ece8a`. Desktop executable SHA-256: `11cae2c0f12583e6c2e560a3dd5a9e25c48bb946b836d8914ada6449fafd76ee`; archived iOS executable: `882adbde25cae890ed854d8dbb660c08e7682cadfdfb6b9211a50445e574e765`.

## Remaining acceptance

`skim-do2h` tracks semantic grouping and importance on real feed coverage: low-overlap paraphrases, similar topics that are separate events, and important single-source stories. Current lexical grouping and source-count/recency ranking are insufficient proof of those requirements.

`skim-dz1g` remains open for installed-app hands-on acceptance and live-provider quality. Initial installed-app exploration stopped at Terms acceptance; the current attempt to reconnect to the native app timed out. No acceptance was inferred or clicked.

`skim-62qe` tracks sharing the full desktop/iOS domain implementation. The bounded policy extraction is `skim-62qe.1`; Rust desktop and Swift iOS still own separate feature extraction, selection and stores. Matching fixes outside the extracted policy are parity evidence, not shared implementation.
