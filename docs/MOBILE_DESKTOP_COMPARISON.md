# Mobile and desktop architecture comparison

## Latest verification: shared original-evidence pair verdicts

The functional Tauri desktop and native iOS release paths now compile one C parser and policy for single-pair semantic decisions. Both preserve original representative source text (up to 2,048 Unicode scalars), keep report identities in code and request a 160-token relation verdict. Rust/Swift production payloads, prompts and budgets are byte-identical across 17 checked pairs. Both retain their existing proposal/rating inputs, cancellation, atomic publication and 30-second deadline. New complete-pipeline regression tests cover evidence flow and rating fallback.

All 550 automated checks pass. Local-model evidence is narrower: 9/9 development labels and 7/8 fresh pair labels match; a full 13-report planner run still falsely merges trial remarks and later sentencing. Identical inputs can produce different verdicts across runs. [Quality record](releases/2026-09-24-semantic-verdict-quality.json) retains these failures. This shares production policy and fixes evidence/identity handling; it does not complete full-pool coverage, model accuracy or the remaining domain-engine migration.

Desktop 0.1.35 is installed; iOS 0.1.13 (72) is `VALID` and `IN_BETA_TESTING` for internal testers, with final state in the [release record](releases/2026-09-24-semantic-verdict-release.json). Artifacts contain 32 desktop/31 native shared C symbols plus 88 shared Swift policy symbols each. The native difference is an inlined one-pair constant, verified by disassembly. Installed native interaction remains unaccepted because the Mac is locked; the localhost UI awaits Terms approval.


Initial audit: 2026-09-20; shared policy, reader and cancellation update: 2026-09-24. Evidence includes source/build paths and inspection of the release artifacts described below. It does not establish installed-app runtime acceptance or complete feature parity. The feature matrix distinguishes resolved and remaining issues. Historical validation below refers to the initial audit; current checks and releases are recorded in `docs/CATCHUP_REVIEW.md`. Paths and line numbers may move with subsequent edits.

## Main finding

The functional desktop app and native iOS app still have separate domain engines, with bounded shared story and local-inference policy modules added on 2026-09-24. Desktop uses React, Tauri and Rust. Native iOS uses SwiftUI and the Swift `SkimCore` package, with substantial additional business logic in its application target. Both now compile and execute `shared/SkimStoryPolicy` for matching thresholds/classification, confidence, base ranking, single-source protection and stable identity hashing. They also share semantic edition instructions, group validation, pair-verification prompts, complete-clique partitioning, isolated event-rating instructions/validation and importance score adjustment. Today previews additionally share excerpt-selection/retry instructions, source bounds, exact-passage validation and cache evidence versioning. Library chat also shares the executable distinct-term relevance formula, so full-topic matches outrank partial headline matches before either adapter applies its context limit. Article and library chat now share question-aware selection of original source passages across the complete reader body, with Unicode casefold and scalar budgets; router/search contexts reselect at their own bounds. Detailed summaries now share built-in style and source-fidelity instructions, including tone aliases and uncertainty preservation, plus normalized word counts, bullet ranges, default token budgets and custom-count validation; configured-provider calls, response-format wrappers and storage adapters remain separate. Native iOS and the desktop Swift helper additionally consume `shared/SkimInferencePolicy` for model families, end-of-turn tokens, thinking flags, sampling presets, output cleanup, chat-template availability checks, structured MLX messages and typed Foundation Models conversation transcripts. Similar models, SQLite tables and remaining algorithms are still parallel implementations.

There is also a native macOS target that depends on `SkimCore`. It currently renders a placeholder rather than the reader application. Counting that package dependency as desktop/mobile sharing would conceal the actual production architecture.

This change moves native smart-folder policy into `SkimCore`, fixes rule and OPML compatibility defects, removes duplicate desktop JavaScript matching, adds a native Today route, and connects native personalization to edition generation. These are concrete ownership and behavior improvements. They do not connect the shipping Tauri desktop to Swift `SkimCore`, migrate existing desktop libraries into native storage, or establish complete feature parity.

## Which applications actually build

| Surface | Entry and build evidence | Core implementation | Meaning |
| --- | --- | --- | --- |
| Functional desktop | `src/App.tsx:461`, `src-tauri/src/lib.rs:63`, `src-tauri/tauri.conf.json:6` | Rust modules under `src-tauri/src/{db,feed,ai,commands}` | React invokes a Rust/Tauri backend. |
| Mac release | `docs/MAC_RELEASE.md:6`, `docs/MAC_RELEASE.md:34` | Tauri app plus Swift AI helper and DS4 helper | A Swift inference helper does not make the reader's domain core shared. |
| Native iOS/TestFlight | `scripts/upload-testflight.sh:6-8`; `native/SkimNative/project.yml:20-37` | Swift `SkimCore` plus `SkimIOS` application logic | The upload workflow selects the native `Skim iOS` scheme. |
| Native macOS | `native/SkimNative/project.yml:86-93`; `native/SkimNative/SkimMacOS/App/SkimMacOSApp.swift:7-18` | Links `SkimCore` but does not invoke a reading loop | Placeholder explicitly says native macOS is deferred. |
| Older Tauri mobile path | `src-tauri/src/lib.rs:62`; `src-tauri/src/lib.rs:155-157`; `src-tauri/Cargo.toml:47-49` | Conditional Tauri/Rust mobile support | Its existence does not establish that the native TestFlight application uses Rust. |

The Swift package targets iOS 26 and macOS 15 (`native/SkimCore/Package.swift:7-10`). The desktop bundle declares macOS 14 (`src-tauri/tauri.conf.json`, `bundle.macOS.minimumSystemVersion`). A wholesale Swift-core replacement would therefore require a deliberate deployment-target decision as well as a language bridge.

## Feature and ownership comparison

“Present” below means code and an application route were found. It does not mean those routes were exercised on devices during this audit.

| Capability | Functional desktop | Native iOS | Shared implementation? |
| --- | --- | --- | --- |
| Feed discovery, RSS/Atom refresh | `src-tauri/src/feed/fetcher.rs:46`; `commands/feeds.rs:107,254` | `SkimCore/FeedRefreshService.swift:29,95,200` | No; separate parsers, fetching and identity logic. |
| OPML import | `commands/feeds.rs:475,498` | `SkimCore/OPMLImportService.swift`; `SkimIOS/App/AppModel.swift:352` | No. |
| Feedly integration | Desktop preview/import, connection and OAuth commands at `commands/feeds.rs:339-634` | No corresponding native Feedly integration found in the audited iOS source | No; desktop feature gap. |
| Folders and smart folders | Rust-authoritative membership returned as `matching_feed_ids`; React consumes it | Swift store plus rule editor and `SkimCore` evaluator | Desktop duplicate matcher removed; Swift/Rust remain separate, tested against a common fixture corpus. |
| Read/unread, favorites and recent history | `commands/articles.rs:48-135,645`; `commands/ai.rs:1444` | `AppModel.swift:393-421`; `Views/ArticleListView.swift:687-698` | No; storage and ordering policies differ. |
| Article extraction and offline cache | `commands/articles.rs:364`; `commands/offline.rs:31-81` | `ArticleReaderContentLoader.swift:21-159`; `AppModel.swift:430-451` | No across shipping apps; native extraction can live in `SkimCore`. |
| Aggregator discussions | `commands/aggregator.rs:27` | `SkimCore/AggregatorService.swift:25` | No; independently implemented services. |
| Story clustering and revisions | `db/story_clustering.rs`; `db/story_policy.rs`; `db/queries.rs` | `SkimCore/StoryClustering.swift`; `SkimCore/SkimStore.swift` | Shared executable classification/ranking/hash policy; feature extraction, selection and persistence remain separate. |
| Today edition | Visible desktop route, `src/App.tsx:461,497`; `commands/editions.rs:6` | New route at `SkimIOS/Views/ArticleListView.swift:100-101,689`, backed by `TodayEditionView.swift` and `SkimCore` snapshots | Both have routes in source; engines remain separate and runtime parity still needs verification. |
| AI Inbox, summaries, Catch Up, Ask | `commands/ai.rs:334,1067,1520`; `commands/chat.rs:29,218` | `Views/ArticleListView.swift:171-172,255-285`; `Support/NativeAI.swift` | Partial: Today grouping/rating/preview policy is shared C, with shared local-inference policy. Chat evidence selection also shares C; other prompts, retrieval scopes, provider orchestration and caches remain separate. |
| Taste and ranking signals | SQLite `article_interactions`; `commands/ai.rs:1421,1711,1723` | UserDefaults taste now supplies feed weights and pins to Today; core adds stars | No; native integration fixed, but persistence, feedback semantics and weights are not exact desktop parity. |
| Local AI runtimes | llama.cpp and Mac helpers, including DS4 (`Cargo.toml:47-49`, `docs/MAC_RELEASE.md:32-44`) | Native MLX and Apple framework adapters | Platform-specific adapters remain; model presets, output cleanup, template checks and local message handling now use shared Swift policy. The full request/provider layer is not unified. |

In this table, abbreviated `commands/`, `db/` and `Cargo.toml` paths are under `src-tauri/src/` or `src-tauri/`; `SkimCore/` and `SkimIOS/` refer to `native/SkimCore/Sources/SkimCore/` and `native/SkimNative/SkimIOS/` respectively.

## Audit findings: resolved and remaining

### Resolved: smart-folder contract, categories and desktop duplicate matching

The initial audit found native rules requiring `id` and `pattern_or_value`, title-based OPML category matching, and always-case-insensitive native regexes. Desktop used canonical `pattern`/`value` fields and default case-sensitive regexes, while React duplicated Rust matching using a different regex engine.

Native rules now decode desktop canonical fields without requiring a stored native ID. Missing mode defaults to `any`; invalid mode does not silently acquire that default. Legacy native rules preserve their old case-insensitive behavior. Encoding includes canonical `pattern`/`value` fields and expresses legacy case-insensitive matching with an inline flag. Canonical fields take precedence over conflicting editor metadata (`native/SkimCore/Sources/SkimCore/SmartFolderEval.swift:38-75,101-108`).

Native category rules now use `feed.opmlCategory` rather than feed title (`SmartFolderEval.swift:145-157`). OPML parsing preserves the nearest enclosing category, following desktop semantics rather than inventing a joined hierarchy path (`native/SkimCore/Sources/SkimCore/OPMLImportService.swift:29-49`). The field is persisted and retained through refresh/upsert (`native/SkimCore/Sources/SkimCore/SkimStore.swift:513,758-787`). This preserves newly imported metadata; it does not reconstruct categories lost by earlier imports.

Desktop folder responses now include Rust-evaluated `matching_feed_ids` (`src-tauri/src/commands/feeds.rs:660-679`). React consumes that membership instead of running JavaScript `RegExp` (`src/lib/smartFolder.ts:31-39`). This removes an actual duplicate policy implementation within desktop. Native and Rust still use different regex libraries; the tested shared corpus proves its cases, not unrestricted syntax equivalence.

Both evaluators fail closed when persisted rules are invalid, including the formerly dangerous case where dropping an invalid regex could make `all([])` match every feed (`src-tauri/src/commands/feeds.rs:986-1014`; `native/SkimCore/Sources/SkimCore/SmartFolderEval.swift:126-135`). A single checked-in corpus at `shared/fixtures/smart-folder-matches.json` is consumed by Swift and Rust tests (`SmartFolderTests.swift:101-118`; `src-tauri/src/commands/feeds.rs:912-938`). The Swift tests are under `native/SkimCore/Tests/SkimCoreTests/`.

### Improved, with remaining differences: Today personalization

At the initial audit snapshot, native Today received only followed/hidden story state, while desktop ranking consumed stars, explicit more/less feedback and priority overrides. That historical hidden-state observation predates the integrated upstream removal of hide behavior in PR #113; it does not describe the current native model.

Current native `TodayRankingPreferences` accepts distinct-feed taste weights and pinned article IDs. It adds capped stars, a pin bonus and finite, bounded mean feed taste (`native/SkimCore/Sources/SkimCore/TodayEdition.swift:3-25`). The store combines these with followed state (`SkimStore.swift:1047-1054`). Current native ranking does not hide stories or articles.

The application passes persisted native taste into this boundary (`native/SkimNative/SkimIOS/App/TasteModel.swift:126-133`; `AppModel.swift:157-160`). Reopening a frozen edition preserves its selection even when preferences change; this behavior is covered by `native/SkimCore/Tests/SkimCoreTests/TodayPersonalizationTests.swift:36`.

This fixes missing native preference integration, but does not make rankings identical. Native taste still uses UserDefaults and feed-level weights, while Rust uses SQLite interactions and different feedback/priority semantics. Identical articles do not yet guarantee identical editions across products. A versioned shared preference policy and state migration remain work for the common-engine migration.

### Resolved: update markers and edition section semantics

The initial audit found Rust testing update markers in the normalized title and Swift testing article feature tokens, which could let lead/body wording change the classification. Swift now uses unfiltered title words for this marker check, and native edition sections use source membership type rather than summary text (`native/SkimCore/Sources/SkimCore/StoryClustering.swift:615-622`; `TodayEdition.swift:330-336`). Focused tests cover title-versus-lead markers and membership-based update sections (`native/SkimCore/Tests/SkimCoreTests/TodayPersonalizationTests.swift:5,72`). These fixes align the identified rules; they do not prove all clustering decisions equivalent.

### Resolved source-level gap: native Today navigation

Initially, native iOS exposed story/edition APIs but no Today screen. It now has a Today entry and navigation destination (`native/SkimNative/SkimIOS/Views/ArticleListView.swift:100-101,689`). `TodayEditionView.swift` renders ranked snapshot stories with optional report disclosure, 5/10/20-story choices, progress, consumed state, loading/error/empty states, preview retries and local-day renewal. `AppModel.swift:140-186` handles snapshot loading and consumption through `SkimCore`, including request identity guards.

This is a real application route, not only a package API. The initial rendering attempt exposed a timestamp-precision conflict; the historical validation below records its fix and successful fixture-based rendering. That error is not a currently reproduced failure. Current installed native-app acceptance remains open because the Mac is locked and native control is unavailable; source inspection, simulator fixtures and release-symbol evidence do not replace that gate.

### Remaining: Feedly and complete product parity

Desktop retains Feedly import, connection and OAuth paths. No equivalent native integration was added in this change. Native macOS also remains a placeholder. These are visible product differences, not issues resolved by the smart-folder extraction or Today route. Completing every desktop feature is not implied by this focused change.

### Remaining: article identities and persistence are separate

Desktop feed ingestion creates UUID article identifiers (`src-tauri/src/feed/fetcher.rs:138-140`). Swift derives a stable identifier from URL, then GUID, then a feed/title/date fallback (`native/SkimCore/Sources/SkimCore/FeedRefreshService.swift:139-140`). Article identity underlies references from read state, stars, cached content and story memberships; IDs cannot be treated as interchangeable during migration or sync.

Desktop opens `skim.db` and runs Rust migrations (`src-tauri/src/db/mod.rs:17-22`). Native opens `skim.sqlite` (`native/SkimNative/SkimIOS/App/AppModel.swift:123-127`) and creates/migrates tables through its own SQLite wrapper (`native/SkimCore/Sources/SkimCore/SkimStore.swift:490-686`). Similar table names and SQLite usage do not prove interchangeable database files.

Desktop has persistent themes, triage, summaries and article interactions (`src-tauri/src/db/migrations.rs:49-103`). Native also retains state outside SQLite, including taste in UserDefaults. A database-only move would miss such state. Settings have some legacy decoding support (`native/SkimCore/Sources/SkimCore/Models.swift:255-271`), but field-level compatibility is not a complete migration contract.

## What is shared today

`shared/SkimStoryPolicy` is compiled from the same C source by desktop Cargo and native SwiftPM. Both production callers use its matching, confidence, ranking, unique-source and identity policies, semantic grouping/verification/rating instructions and validation, and source-verified Today preview policy. Provider calls, JSON decoding, source snapshots and migrations remain platform adapters. Semantic planning still accepts pools of at most 64 candidates. Verification now uses shared request sizing to process all proposed pairs in batches of at most 64, with original report IDs and strict per-batch coverage checks. All batches must validate before publishing merged groups; failure stops further calls. One 30-second deadline covers the entire plan. Invalid plans fall back deterministically; rating-stage failure retains verified memberships with neutral scores for split groups.

A fresh nine-feed library reproduced the whole-pool cutoff at 107 eligible candidates: the actual desktop command froze a deterministic edition in 0.038 seconds. A subsequent 108-candidate full-pool experiment took 627 seconds, omitted 24 within-block assessments, and returned seven incomplete verification batches. It is rejected for production. Request batching fixes the pair-count cliff only; persistent full-pool preparation, explicit coverage and model quality remain open. See [the coverage study](releases/2026-09-24-semantic-coverage-quality.json).

Today previews accept a contiguous passage from one bounded source body, with only whitespace normalization, conservative sentence/paragraph boundaries, at most three sentences, 60 words and 600 Unicode scalars. A successful but invalid JSON response gets one plaintext retry through the same validator. Earlier unverified previews remain stored but hidden by evidence-version checks; immutable editions and read progress remain unchanged. This verifies a passage's presence in supplied evidence, not publisher truth, relevance or completeness. Detailed summaries and chat retain their separate behavior.

The cached 1B model failed earlier development samples. Qwen 4B now passes the limited labeled 45-story current-feed replay and the selected chronology excerpt probes. These are not representative quality acceptance, and pools beyond the current limits remain open. The real desktop browser/backend run produced five of six verified previews; a markup-bearing Greek selection was rejected and retained its publisher-snippet fallback. See [source-preview quality evidence](releases/2026-09-24-source-preview-quality.json) and [the current catch-up review](CATCHUP_REVIEW.md). Fixtures establish defined regression coverage; the common C implementation establishes bounded code sharing. Neither completes the end-to-end engine migration: feature extraction, exact-match checks, tie-breaking, selection, preferences and stores remain separate. See [shared policy boundaries](../shared/SkimStoryPolicy/README.md).

`SkimCore` is a real reusable Swift library. It owns native feed parsing/refresh, OPML, aggregator retrieval, domain records, SQLite operations, stories and editions. iOS constructs and calls these services (`native/SkimNative/SkimIOS/App/AppModel.swift:116-127`). The native macOS target links the same package but does not yet exercise those services in a functioning reader.

The new smart-folder fixture corpus is physically shared across Swift and Rust tests. Its passing cases establish contract evidence, not shared execution. The desktop and native implementations also align selected contract details, including snake-case story payloads, stable story IDs and thresholds. Rust's `shared_golden_normalization_and_stable_id` test embeds its expectations (`src-tauri/src/db/story_clustering.rs:910-924`); Swift has embedded wire-contract fixtures (`native/SkimCore/Tests/SkimCoreTests/SkimCoreTests.swift:470-549`). Those tests are useful but do not execute one implementation or exhaustively prove cross-platform behavior.

Three acceptance claims must remain distinct:

- **Code sharing:** both shipped products execute the same authoritative implementation for a domain capability.
- **Contract compatibility:** independent implementations agree on a defined, tested interchange boundary.
- **Feature parity:** users can complete the same supported task in both products, with platform-appropriate presentation.

One does not establish either of the others.

## Shared local inference policy and release packaging

The shipping Swift helper and native iOS target both import the same dependency-free `shared/SkimInferencePolicy` package. Duplicate native policy was removed. Desktop now preserves caller temperature (including zero), applies the existing native model presets, disables supported thinking templates, and removes leading reasoning/trailing terminators without damaging literal tokens in answers. Chat-template availability and structured local message roles also use this package. Model loading, generation, settings and transport stay in platform adapters.

The desktop bridge build previously searched a reusable scratch directory for the first matching release binary. Old toolchain output could win over the newly compiled product. Packaging now queries `swift build --show-bin-path` with the same build configuration and requires its exact executable and resource bundle; coexistence and missing-product regressions cover the failure. See `docs/CATCHUP_REVIEW.md` for artifact and model-quality evidence.

### Current release-artifact evidence

The inspected artifacts are desktop **0.1.29** and native iOS **0.1.13 (66)**. [The current release record](releases/2026-09-24-summary-policy-release.json) records **22 shared C symbols**, including `skim_summary_style_prompt`, and **71 shared Swift policy symbols each** in the desktop helper and iOS evidence. The bundled helper's machine-code section matches the freshly compiled helper; whole-file hashes differ after signing. The iOS executable/dSYM UUID is `F23AFDEF-BA12-3A6E-8BF7-511DAA49324B`. These prove release-path inclusion, not installed operation or native UI acceptance. The signed desktop parent again timed out after 120 seconds before `main()` in `_libsecinit_appsandbox`; native control still reports a locked Mac. Build 66 was uploaded; the release record captures Apple's processing and internal beta state.

The preceding reader fixes make summary caches depend on actual source evidence and preserve reader extraction for offline reuse. Native RSS summary/chat use the reader cache and bounded resolver; provider/model overrides, preset word counts, generated-summary context and local web citations match the intended desktop behavior. `AIRequestPolicy` centralizes these native entry-point rules within `SkimCore`; Rust desktop request policy is still separate. [Reader evidence](releases/2026-09-24-reader-ai-quality.json) records that release's 431 tests and real command/browser probes.

The preceding cancellation fixes serialize desktop cancellation with cache publication and add a native `AIPublicationGate` for late cache writes, queued tokens and dismissed/replaced result sheets. They fix parity defects but remain platform-specific adapters, not additional domain sharing across desktop and mobile. Desktop summary requests now specify compatible JSON schemas without fictional examples. [Cancellation quality evidence](releases/2026-09-24-summary-cancellation-quality.json) records 441 passing tests and before/after actual-command cancellation proof. Detailed-summary factual accuracy remains defective on some real-model samples; experimental repair and sentence verification were rejected after false acceptance of unsupported claims.

Built-in summary style now has one authoritative C implementation called by both production apps. It preserves uncertainty, attribution, negation and event timing, maps `detailed`/`descriptive` as aliases, and replaces the conflicting uncertainty directives. The Rust and Swift adapters retain their existing custom-prompt precedence, JSON/plain-text contracts and budgets. [The shared-summary quality record](releases/2026-09-24-summary-policy-quality.json) covers 445 main tests plus 19 shared-policy/packaging checks and actual command wiring. Independent review of 45 local-model outputs still found material factual defects, including with a larger model. This extraction does not establish model accuracy; native budget/range drift is tracked in `skim-62qe.4`.


## Recommended ownership and migration

For the existing functional desktop and native iOS products, the strongest long-term boundary is a platform-neutral domain engine, with explicit bindings into each application. A Rust library extracted from Tauri is the most direct candidate because the functional desktop already uses Rust and it can preserve non-Apple desktop support. SwiftUI can call a narrow C ABI or generated Swift binding. This is an architectural recommendation, not a bridge implemented or validated by this change.

That engine should own article/feed identity, normalization, smart-folder semantics, read/star/learning state, story clustering, revision rules, edition ranking/selection, AI context selection and prompt policy, plus versioned domain contracts. Tauri commands and Swift application models should translate UI actions into those APIs. UI layout, navigation, accessibility and native dialogs remain in React/SwiftUI. Keychain, networking integration, background scheduling, PDF/WebKit work, Apple Foundation Models, MLX and desktop inference processes remain adapters where platform dependencies require them.

If the product instead commits to an Apple-only native replacement, completing native macOS on `SkimCore` is another valid route. It only achieves shipping code sharing after the full desktop reader is implemented, its existing functionality/data are migrated, and the release workflow selects that product. Linking the current placeholder is insufficient. This route also needs explicit decisions about macOS 14 support and any non-Apple desktop support.

Migration should proceed in independently reversible stages:

1. **Define contracts and characterization fixtures.** Record current supported behavior and intentional platform differences. Use one checked-in corpus for rule JSON, feeds, article IDs, clustering, editions and AI context outputs. Execute it from both existing implementations to expose drift before choosing canonical behavior.
2. **Extract pure policy first.** Move deterministic domain modules behind a platform-neutral API without changing persistence or UI. Start with identity, smart-folder policy and story/edition decisions. Keep compatibility adapters explicit; do not create another parallel copy and call it shared.
3. **Connect both actual application paths.** Wire desktop and native iOS to that engine. Add a build check proving both release graphs consume the same core source/version. Delete superseded policy implementations after equivalent behavior is proven.
4. **Unify data ownership through versioned migration.** Preserve existing IDs through mappings, migrate all relevant stores, and validate feeds, articles, read/star state, folders, rules, reader cache, settings and learning signals. Retain an untouched rollback source until migration is verified. Secrets remain in platform secure storage.
5. **Consolidate AI business behavior.** Separate prompt/context/result validation from platform inference adapters. Preserve cancellation, refusal handling, citation provenance and provider errors through the common interface. Do not force identical runtimes on different hardware.
6. **Close intentional feature gaps.** Validate the new native Today experience and decide the remaining Feedly and other agreed parity items separately from core extraction. Validate actual user journeys on each app rather than inferring parity from API presence.

## Acceptance gates

Architectural completion requires build-graph evidence that the **functional released desktop and iOS apps** execute the common engine, plus removal of duplicate authoritative implementations. A common library that only one functioning app uses does not pass.

Behavioral completion requires cross-platform fixtures covering valid/invalid and legacy smart rules, regex policy, OPML categories, malformed feeds, article identity collisions, grouping boundary cases, update detection, deterministic tie-breaking, learning signals, frozen editions and cache fallbacks. Include cases that distinguish today's known drift rather than only examples both implementations already pass.

Data completion requires representative old-store migrations and restart verification with count/identity/state assertions, including state currently outside SQLite. Contract tests should reject unsupported versions explicitly instead of silently dropping rules or settings.

Product completion requires rendered and interactive checks for feed import/refresh, list filtering, read/star behavior, article/offline reading, AI flows and agreed Today/Feedly parity on desktop and iPhone/iPad. Package tests, compiler success and API availability are narrower evidence.

Release completion requires the existing platform release gates, version/build metadata checks, and verification of the exact built artifacts. This audit does not produce or upload an archive, change the chosen desktop product, or claim those runtime/release checks passed.

## Historical audit validation and remaining completion boundary

The following records the initial audit integration, not the current release test counts or versions. Current validation and artifact evidence are linked above.

Historical integrated validation: **46 Swift package tests**, **76 TypeScript/React tests**, and **52 Rust library tests** passed. The GGUF-dependent `test_summarize_local_model` requires a separately downloaded model and was excluded after confirming that prerequisite is absent. TypeScript compilation, the Vite production build, and the native iOS Simulator build passed. The frontend suite includes one pre-existing Catchup expectation corrected to match the current error detail plus settings action.

An isolated simulator harness renders the unchanged Today view against the actual SkimCore store and a synthetic library. Phone and tablet renders first exposed a real `Conflicting edition` failure: SQLite bindings round timestamps to milliseconds, but immutable edition comparisons used the original higher precision. Edition and consumed-item timestamps now normalize to the persistence precision; a real-clock regression covers generation, frozen reopen, empty editions, and consumed-item retries. Corrected populated, completed, and empty states rendered successfully and were visually inspected on a short iPhone and iPad. This proves fixture-based rendering and core integration, not taps/navigation through the shipping app; direct Simulator UI control was unavailable.

Upstream PR #113 (hide removal) and #112 (disclaimer update) are preserved. That historical release bumped metadata to **0.1.13 (48)** before archiving. TestFlight upload and Apple processing are verified separately in the PR handoff; no production desktop binary deployment or full feature-parity claim follows from these checks.

The remaining full migration is tracked in Beads epic `skim-62qe`. The shipped desktop/mobile code-sharing objective remains incomplete until both functional products consume one core. Feedly support and data migration also remain differences; the changes documented here do not silently declare those complete.

## Question-aware evidence follow-up

Both production apps now execute `skim_chat_evidence_spans` through safe Rust/Swift adapters. One 12-case corpus covers distant facts with qualifiers, topic words already present in the lead, Unicode punctuation/casefold, original byte spans, scalar budgets and large unpunctuated sources. Contextual conversation handling remains platform code and uses user messages only. This extraction does not unify stores, feed engines or complete retrieval orchestration.

The [actual desktop quality record](releases/2026-09-24-chat-evidence-quality.json) proves the old cutoff omitted facts that both new prompts retain. It also records a remaining Qwen library-answer finality error despite correct source evidence. All 530 automated checks pass, but general model accuracy and installed native acceptance remain open.

The [release record](releases/2026-09-24-chat-evidence-release.json) verifies `skim_chat_evidence_spans` among 28 shared C symbols in desktop 0.1.32 and native 0.1.13 (69), now available in internal TestFlight. Installed desktop acceptance remains pending; 0.1.17 is still installed.

## Conversation transport follow-up

Native OpenAI-compatible and Anthropic chat previously flattened prior user/assistant turns into a single user message. Desktop and native Foundation Models also flattened history despite the public framework supporting typed transcript entries. The current fix preserves cloud roles and makes both production Foundation paths call the same `SkimInferencePolicy.FoundationChatMessages` implementation. It builds a fresh transcript of instructions and prior prompts/responses, then sends the latest user question once. Scalar summary requests, selected evidence, citation handles, provider routing and sampling remain unchanged. Native article instructions now permit supplied web evidence without treating prior assistant output as factual evidence.

This addresses transport and evidence-authority drift. The [88-output factual study](releases/2026-09-24-chat-fidelity-quality.json) rejected stronger generic chat wording; model factual reliability remains open independently.

The [release record](releases/2026-09-24-chat-roles-release.json) confirms the shared transcript builder in both desktop 0.1.33 and native 0.1.13 (70), with 28 shared C functions and 88 Swift policy symbols. Build 70 is available in internal TestFlight; 538 checks pass. Installed desktop remains 0.1.17, its signed replacement still stalls before `main()`, and Apple Intelligence is disabled on this host. Those runtime boundaries remain open separately from production build-graph sharing.
