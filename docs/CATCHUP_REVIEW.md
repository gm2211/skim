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

145 frontend tests, 122 Rust library tests, and 87 Swift package tests pass. TypeScript and the Vite production build pass. The Rust local-model integration test remains excluded because its separate GGUF model is unavailable. Both ABI adapters execute one shared policy fixture corpus. Cache-upgrade regressions were verified to fail with the upgrade disabled and pass when restored.

The in-app browser exercised the real Today React components in an isolated fixture harness at desktop width and 375×667. Reviewed collapsed/expanded references, long publication names, keyboard headline activation, compact reader transition, loading, empty, error and completed states. The harness used fixture command responses and a placeholder reader panel: it proves layout and interaction boundaries, not live journalism quality, real-provider answers, or native window compositing.

Rendered chat QA subsequently became available in the in-app browser. The actual Sidebar, Ask and ArticleDetail components were exercised with fixture responses at desktop width and 390×568. Search, citation opening, returning to preserved history/scope/draft, follow-up sending, and ordinary dialog close passed. This exposed and fixed composer focus loss, reader focus handoff, lost opener focus after a citation round trip, and an unnecessary 60-pixel phone header inset. Screenshots retain aligned glass surfaces and readable article layout. Native app access remains blocked by the locked Mac; browser fixtures do not prove native compositing or live answers.

An isolated Rust devbridge and repository newsstand exercised actual commands against a disposable library: OPML imported four feeds, refresh ingested ten articles, the same empty edition filled with six current-day stories, and another refresh preserved the populated snapshot. An additional syndicated feed produced single cards with both coverage and duplicate references; consumption marked every reference read. This exposed and fixed a devbridge compilation defect: the lede command must use the crate's runtime-generic `AppHandle` alias. These are real backend integration checks with fixture journalism; semantic paraphrases still remain separate.

## Shared semantic edition path

Both products now call the shared C prompt, numeric validation and importance adjustment before freezing a new edition. Only the configured provider is used, outside database locks, with a 30-second deadline. The complete eligible pool must contain at most 64 stories; larger pools retain deterministic selection. Foundation Models has a conservative input/output budget; no partial candidate pool or cloud fallback is substituted.

Valid groups retain all source references and each constituent story revision. Consumption suppresses every constituent until material news changes it. Existing populated editions stay frozen; stale revisions or source membership changes during inference discard the plan. Migrations backfill old items as singleton groups. Invalid, overlapping, out-of-range and low-confidence groups cannot remove candidates; omitted candidates remain singletons. Shared fixture tests cross the Swift and Rust ABI adapters.

Actual standalone inference with the cached `mlx-community/gemma-3-1b-it-4bit` model returned malformed JSON and incorrect indexes on eight original synthetic news reports (4.66 seconds). A shorter experimental prompt also failed. The recorded response is checked into `shared/fixtures/semantic-model-failure.json` and rejected by both adapters. This establishes safe rejection, **not semantic quality**. The standalone helper can run; it does not establish signed-parent runtime acceptance. Apple Foundation Models reports Apple Intelligence disabled on this host. No settings were changed.

## Release evidence

- Native iOS **0.1.13 (56)** archived, exported and uploaded successfully. Archive metadata was checked; App Store Connect currently reports `PROCESSING` for the internal-only build. Build 55 remains available to internal testers while processing finishes.
- Desktop **0.1.20** built and signed; `codesign --verify --deep --strict` and bundle metadata passed. Installation remains pending.
- The earlier signed desktop smoke check could not start on this host: both the new 0.1.18 bundle and installed 0.1.17 stalled in `_libsecinit_appsandbox` before `main()` or any helper child launched. A sampled process was blocked in `_xpc_pipe_routine` / `mach_msg2_trap`. Current native computer-control still reports the Mac locked. A fresh 0.1.20 signed-parent check is being verified separately; standalone helper inference does not establish this release gate.

All ten shared policy functions appear in the desktop 0.1.20 symbol table and iOS build 56 dSYM. The iOS dSYM UUID matches the archived executable (`29B14A73-C5E6-31DF-B95F-4FEAA8BFFDD2`). Both release build graphs compile the same C source, SHA-256 `7ce36b1073201172dac0f0c738f8a83102cf0d1e437808cca14ff33c692ff8c6`. Desktop executable SHA-256: `9788eb1893d6cfa832a8a319dec4f1f3cf9437717604bc0be5acb7eca99affbf`; archived iOS executable: `2d02a5ec3dc42a5f19eed92d5d293f6b9a25d85eaf341d97656a8c510942226d`.

## Remaining acceptance

`skim-do2h` tracks semantic grouping and importance on real feed coverage: low-overlap paraphrases, similar topics that are separate events, and important single-source stories. The bounded semantic path is now wired in both apps, but the cached 1B model failed the isolated quality check. Real-feed grouping/importance, reliable local-model output and candidate pools larger than 64 remain unaccepted. Numeric validation cannot establish whether a structurally valid model grouping is editorially correct.

`skim-dz1g` remains open for installed-app hands-on acceptance and live-provider quality. Initial installed-app exploration stopped at Terms acceptance; the current attempt to reconnect to the native app timed out. No acceptance was inferred or clicked.

`skim-62qe` tracks sharing the full desktop/iOS domain implementation. The bounded policy extraction is `skim-62qe.1`; Rust desktop and Swift iOS still own separate feature extraction, selection and stores. Matching fixes outside the extracted policy are parity evidence, not shared implementation.
