# Mobile and desktop architecture comparison

Audit date: 2026-09-20. Evidence describes this repository's build paths and source, not an inspection of installed binaries or an assertion of production feature parity. The feature matrix describes the final source changes below; the findings distinguish the initial audit from resolved and remaining issues. Paths and line numbers identify the audited source and may move with subsequent edits.

## Main finding

The functional desktop app and the native iOS app do **not** run the same core implementation. Desktop uses React, Tauri and Rust. Native iOS uses SwiftUI and the Swift `SkimCore` package, with substantial additional business logic in its application target. Similar models, SQLite tables, algorithms and golden expectations constitute parallel implementations, not shared executable code.

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
| Story clustering and revisions | `db/story_clustering.rs:316`; `db/queries.rs` | `SkimCore/StoryClustering.swift:329`; `SkimCore/SkimStore.swift:163` | No; similar deterministic policy copied across languages. |
| Today edition | Visible desktop route, `src/App.tsx:461,497`; `commands/editions.rs:6` | New route at `SkimIOS/Views/ArticleListView.swift:100-101,689`, backed by `TodayEditionView.swift` and `SkimCore` snapshots | Both have routes in source; engines remain separate and runtime parity still needs verification. |
| AI Inbox, summaries, Catch Up, Ask | `commands/ai.rs:334,1067,1520`; `commands/chat.rs:29,218` | `Views/ArticleListView.swift:171-172,255-285`; `Support/NativeAI.swift` | No; provider orchestration, prompts, context and caches duplicated. |
| Taste and ranking signals | SQLite `article_interactions`; `commands/ai.rs:1421,1711,1723` | UserDefaults taste now supplies feed weights, pins and hidden IDs to Today; core adds stars | No; native integration fixed, but persistence, feedback semantics and weights are not exact desktop parity. |
| Local AI runtimes | llama.cpp and Mac helpers, including DS4 (`Cargo.toml:47-49`, `docs/MAC_RELEASE.md:32-44`) | Native MLX and Apple framework adapters | Platform-specific adapters are appropriate; shared request and policy layers are still missing. |

In this table, abbreviated `commands/`, `db/` and `Cargo.toml` paths are under `src-tauri/src/` or `src-tauri/`; `SkimCore/` and `SkimIOS/` refer to `native/SkimCore/Sources/SkimCore/` and `native/SkimNative/SkimIOS/` respectively.

## Audit findings: resolved and remaining

### Resolved: smart-folder contract, categories and desktop duplicate matching

The initial audit found native rules requiring `id` and `pattern_or_value`, title-based OPML category matching, and always-case-insensitive native regexes. Desktop used canonical `pattern`/`value` fields and default case-sensitive regexes, while React duplicated Rust matching using a different regex engine.

Native rules now decode desktop canonical fields without requiring a stored native ID. Missing mode defaults to `any`; invalid mode does not silently acquire that default. Legacy native rules preserve their old case-insensitive behavior. Encoding includes canonical `pattern`/`value` fields and expresses legacy case-insensitive matching with an inline flag. Canonical fields take precedence over conflicting editor metadata (`native/SkimCore/Sources/SkimCore/SmartFolderEval.swift:38-75,101-108`).

Native category rules now use `feed.opmlCategory` rather than feed title (`SmartFolderEval.swift:145-157`). OPML parsing preserves the nearest enclosing category, following desktop semantics rather than inventing a joined hierarchy path (`native/SkimCore/Sources/SkimCore/OPMLImportService.swift:29-49`). The field is persisted and retained through refresh/upsert (`native/SkimCore/Sources/SkimCore/SkimStore.swift:513,758-787`). This preserves newly imported metadata; it does not reconstruct categories lost by earlier imports.

Desktop folder responses now include Rust-evaluated `matching_feed_ids` (`src-tauri/src/commands/feeds.rs:660-679`). React consumes that membership instead of running JavaScript `RegExp` (`src/lib/smartFolder.ts:31-39`). This removes an actual duplicate policy implementation within desktop. Native and Rust still use different regex libraries; the tested shared corpus proves its cases, not unrestricted syntax equivalence.

Both evaluators fail closed when persisted rules are invalid, including the formerly dangerous case where dropping an invalid regex could make `all([])` match every feed (`src-tauri/src/commands/feeds.rs:986-1014`; `native/SkimCore/Sources/SkimCore/SmartFolderEval.swift:126-135`). A single checked-in corpus at `shared/fixtures/smart-folder-matches.json` is consumed by Swift and Rust tests (`SmartFolderTests.swift:101-118`; `src-tauri/src/commands/feeds.rs:912-938`). The Swift tests are under `native/SkimCore/Tests/SkimCoreTests/`.

### Improved, with remaining differences: Today personalization

The initial audit found native Today receiving only followed/hidden story state, while desktop ranking consumed stars, explicit more/less feedback and priority overrides (`src-tauri/src/db/story_clustering.rs:743-774`). Native now accepts a `TodayRankingPreferences` input with distinct-feed taste weights, pinned article IDs and hidden article IDs. It adds capped stars, a pin bonus and finite, bounded mean feed taste (`native/SkimCore/Sources/SkimCore/TodayEdition.swift:3-29`). The store combines these with followed state and hides stories whose source articles are all hidden (`SkimStore.swift:1045-1059`).

The application passes persisted native taste into this boundary (`native/SkimNative/SkimIOS/App/TasteModel.swift:123-134`; `AppModel.swift:157-160`). Reopening a frozen edition preserves its selection even when preferences change; this behavior is covered by `native/SkimCore/Tests/SkimCoreTests/TodayPersonalizationTests.swift:36`.

This fixes missing native preference integration, but does not make rankings identical. Native taste still uses UserDefaults and feed-level weights, while Rust uses SQLite interactions and different feedback/priority semantics. Identical articles do not yet guarantee identical editions across products. A versioned shared preference policy and state migration remain work for the common-engine migration.

### Resolved: update markers and edition section semantics

The initial audit found Rust testing update markers in the normalized title and Swift testing article feature tokens, which could let lead/body wording change the classification. Swift now uses unfiltered title words for this marker check, and native edition sections use source membership type rather than summary text (`native/SkimCore/Sources/SkimCore/StoryClustering.swift:615-622`; `TodayEdition.swift:330-336`). Focused tests cover title-versus-lead markers and membership-based update sections (`native/SkimCore/Tests/SkimCoreTests/TodayPersonalizationTests.swift:5,72`). These fixes align the identified rules; they do not prove all clustering decisions equivalent.

### Resolved source-level gap: native Today navigation

Initially, native iOS exposed story/edition APIs but no Today screen. It now has a Today entry and navigation destination (`native/SkimNative/SkimIOS/Views/ArticleListView.swift:100-101,689`). `TodayEditionView.swift` renders persisted snapshots, sectioned stories, 5/10/20-story choices, progress, consumed state, loading/error/empty states, and local-day renewal. `AppModel.swift:140-186` handles snapshot loading and consumption through `SkimCore`, including request identity guards.

This is a real application route in source rather than only a package API. Functional and visual parity require the actual native build and rendered interaction checks; source inspection alone does not establish them.

### Remaining: Feedly and complete product parity

Desktop retains Feedly import, connection and OAuth paths. No equivalent native integration was added in this change. Native macOS also remains a placeholder. These are visible product differences, not issues resolved by the smart-folder extraction or Today route. Completing every desktop feature is not implied by this focused change.

### Remaining: article identities and persistence are separate

Desktop feed ingestion creates UUID article identifiers (`src-tauri/src/feed/fetcher.rs:138-140`). Swift derives a stable identifier from URL, then GUID, then a feed/title/date fallback (`native/SkimCore/Sources/SkimCore/FeedRefreshService.swift:139-140`). Article identity underlies references from read state, stars, cached content and story memberships; IDs cannot be treated as interchangeable during migration or sync.

Desktop opens `skim.db` and runs Rust migrations (`src-tauri/src/db/mod.rs:17-22`). Native opens `skim.sqlite` (`native/SkimNative/SkimIOS/App/AppModel.swift:123-127`) and creates/migrates tables through its own SQLite wrapper (`native/SkimCore/Sources/SkimCore/SkimStore.swift:490-686`). Similar table names and SQLite usage do not prove interchangeable database files.

Desktop has persistent themes, triage, summaries and article interactions (`src-tauri/src/db/migrations.rs:49-103`). Native also retains state outside SQLite, including taste in UserDefaults. A database-only move would miss such state. Settings have some legacy decoding support (`native/SkimCore/Sources/SkimCore/Models.swift:255-271`), but field-level compatibility is not a complete migration contract.

## What is shared today

`SkimCore` is a real reusable Swift library. It owns native feed parsing/refresh, OPML, aggregator retrieval, domain records, SQLite operations, stories and editions. iOS constructs and calls these services (`native/SkimNative/SkimIOS/App/AppModel.swift:116-127`). The native macOS target links the same package but does not yet exercise those services in a functioning reader.

The new smart-folder fixture corpus is physically shared across Swift and Rust tests. Its passing cases establish contract evidence, not shared execution. The desktop and native implementations also align selected contract details, including snake-case story payloads, stable story IDs and thresholds. Rust's `shared_golden_normalization_and_stable_id` test embeds its expectations (`src-tauri/src/db/story_clustering.rs:910-924`); Swift has embedded wire-contract fixtures (`native/SkimCore/Tests/SkimCoreTests/SkimCoreTests.swift:470-549`). Those tests are useful but do not execute one implementation or exhaustively prove cross-platform behavior.

Three acceptance claims must remain distinct:

- **Code sharing:** both shipped products execute the same authoritative implementation for a domain capability.
- **Contract compatibility:** independent implementations agree on a defined, tested interchange boundary.
- **Feature parity:** users can complete the same supported task in both products, with platform-appropriate presentation.

One does not establish either of the others.

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

## Validation and remaining completion boundary

Current verified test results for these changes: **45 Swift package tests** and **77 TypeScript/React tests** passed. The frontend result includes one pre-existing Catchup test expectation updated to match current behavior. Swift coverage includes smart-folder public APIs, canonical/legacy JSON, OPML category persistence, the shared matching corpus, update classification, personalization and frozen edition behavior.

Earlier unsigned Debug builds of the native iOS Simulator and macOS targets passed for the initial extraction-only revision. Those earlier builds do not validate the later Today and compatibility changes. Final Rust tests, native builds, rendered inspection and release/shipping results must be recorded against the final revision separately; no such results are inferred from the package and frontend tests above.

The remaining full migration is tracked in Beads epic `skim-62qe`. The shipped desktop/mobile code-sharing objective remains incomplete until both functional products consume one core. Feedly support and data migration also remain differences; the changes documented here do not silently declare those complete.
