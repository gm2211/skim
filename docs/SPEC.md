# Skim — Feature Specification

Snapshot of everything Skim ships today. Groups by subsystem. Each feature links to its primary UI surface and, where one exists, the relevant screenshot in `docs/screenshots/`.

---

## 1. Feed ingestion

### 1.1 Feed formats
- RSS 2.0, Atom, JSON Feed.
- OPML import (drag-drop file, preview before import) and export.
- Parsed server-side with `feed-rs`.

### 1.2 Feedly OAuth sync
- OAuth flow at `http://127.0.0.1:54321/feedly/callback`. Client id/secret baked at build via `FEEDLY_CLIENT_ID` / `FEEDLY_CLIENT_SECRET` env vars; falls back to user-entered creds.
- Pulls subscription list, entries, read state, stars.
- Bidirectional read/star sync (local changes push back to Feedly).

### 1.3 Manual add
- Add by URL; Skim resolves the feed doc and site URL.

### 1.4 Duplicate detection
- List + merge near-duplicate feeds (normalized URL match).

### 1.5 Auto-refresh
- Configurable interval (default 30 min) and on-focus refresh.
- Hard cap per feed (`max_articles_per_feed`, default 200) so pathological feeds don't explode the DB.

---

## 2. Folders

### 2.1 Manual folders
- Flat structure (no nesting). Drag-drop feeds in/out.
- Created/renamed/deleted from the sidebar.

### 2.2 Smart folders
- Rule types: `RegexTitle`, `RegexUrl`, `OpmlCategory`.
- Match mode: `any` (OR) or `all` (AND).
- Rules stored as JSON in `folders.rules_json`.
- Evaluated both backend (for `list_folders` counts) and frontend (`src/lib/smartFolder.ts`) for instant UI refresh.

### 2.3 Auto-organize with AI
![Auto-organize](screenshots/03-auto-organize.png)

- Proposes folder names grouped by feed. Two modes:
  - **Only unassigned feeds** — keeps existing folders, touches just loose feeds.
  - **Reorganize everything** — deletes existing folders on apply and rebuilds.
- Folder-name casing: `kebab-case`, `snake_case`, `Title Case`.
- Apply = diff and commit. Cancel = discard.
- Case style applied to LLM proposal names on load (post-processing so the model doesn't have to get it right).

### 2.4 AI topic suggestion
- Given a freeform description, Skim picks feeds matching the topic.

---

## 3. AI Inbox (triage)

![AI Inbox](screenshots/02-ai-inbox-themes.png)

### 3.1 Priority triage
- Every unread article gets priority 1–5 + one-line reason.
- Labels: `MUST READ` (5), `IMPORTANT` (4), `WORTH READING` (3), `ROUTINE` (2), `SKIP` (1).
- Stored in `article_triage` with provider/model/timestamp.
- Runs in batches; batch size tuned per provider (local: 25, ollama: 40, cloud: 60).
- Emits progress events: `fetching → processing → done`.
- Auto-trigger on AI Inbox view open.

### 3.2 Topic chips
- Inbox filterable by theme chip across the top.
- Themes generated separately (§4).

### 3.3 Learning from engagement
Signals fed into the preference profile:
- reading time per article (tracked on dwell)
- stars
- chat activity on the article
- whether the user summarized it
- explicit `more like this` / `less like this` feedback
- priority overrides (user bumps or demotes a triage decision)

Profile compiled by `get_preference_profile` and injected into triage system prompt as `--- Reader's learned preferences ---`.

### 3.4 User-supplied "what I care about" prompt
- Free-form multi-line prompt in Settings → AI.
- Injected into triage system prompt as `--- Reader's interests (explicit) ---`, above the learned profile.
- Additive: explicit prompt + learned profile together guide the model.
- Stored in `AiSettings.triage_user_prompt` (inside the AppSettings JSON blob — no new DB column).

### 3.5 Inbox deduplication
- One-time interaction dedup migration keeps the Recent view clean.
- Canonical interaction dedupe suppresses engagement artefacts from Recent.
- Frontend-side dedup safety net for the Recent list.

---

## 4. Themes

- Cross-article topic clustering over recent unread.
- Each theme has a label, short summary, article count, expiry.
- Shown as a top-level sidebar section and as topic chips in the AI Inbox.
- Re-runs via the same generate-themes pipeline; expired themes auto-prune.

---

## 5. Super-quick catch-up

![Catch-up](screenshots/05-catchup.png)

- Single-shot digest of "what happened" across unread.
- `Top Takeaways` (10) + `Notable Mentions`.
- Each bullet carries its source feed tag(s).
- Scopes: `All unread`, `Starred`, theme, feed, folder.
- `Re-run` regenerates with the current scope.
- Triggered from the top bar (no longer nested under Inbox).

---

## 6. Ask Skim (feed-wide chat)

![Ask Skim](screenshots/04-ask-skim.png)

- Natural-language question → answer grounded in your articles.
- Numbered citations `[1]`, `[2]`, … linking back to source articles.
- Scope picker: `All articles`, `Unread`, folder, feed.
- **Web search tool available** — model can invoke `web_search` when the feed doesn't cover the topic. Web sources appear in the citations list with a distinct marker.
- Shift+Enter for newline; Enter sends.

---

## 7. Per-article chat

- Open any article, chat with it.
- Model grounds on full body text + conversation history.
- Same `web_search` tool as Ask Skim.
- Chat activity feeds the engagement profile (§3.3).

---

## 8. Summarize

![Summarize](screenshots/06-summarize.png)

- Length: short (~30 words), medium, long.
- Tone: concise, detailed, casual, technical.
- Format: bullets, paragraph, both.
- Custom prompt field ("focus on financial implications", etc.) — overlays the system prompt.
- Configurable custom word count when using custom prompt.
- Reader vs Web toggle for the article body (reader view strips ads/chrome; web view shows original).
- Cancel in-flight summarize via `cancel_summarize`.
- Cached per article (100-entry LRU).

---

## 9. Engagement signals

Tracked in `article_interactions`:

| Signal | Source |
|---|---|
| Reading time (sec) | Dwell time on article detail |
| Chat messages count | Increments per chat send |
| Feedback | Explicit `more` / `less` buttons |
| Priority override | User-set priority differing from AI's |
| Summary requested | When user hits Summarize |
| Star | Star button |

Bounded by `sync.recent_cap` (default 3000) — oldest rows evict to keep Recent view fast.

---

## 10. AI providers

Configurable in Settings → AI Provider. Each provider can be used for summary / triage / chat — with an optional separate chat provider (`chat_provider`).

| Provider | Auth | Notes |
|---|---|---|
| **Claude Pro/Max subscription** | OAuth (`sk-ant-oat…`) via claude.ai | No API key, uses subscription. Bearer + `anthropic-beta: oauth-2025-04-20,claude-code-20250219`. `client_id` matches Claude Code CLI. Desktop: loopback flow (browser → `127.0.0.1:54134/callback`). Mobile/constrained: paste-code flow. |
| Claude (API key) | `sk-ant-…` | Direct Anthropic API, per-request billing. |
| Claude CLI (legacy) | Delegates to local `claude -p` | Preferred path is now the OAuth subscription provider above. Kept for installs already relying on the CLI. |
| OpenAI | API key | GPT-4o, GPT-4o-mini, … |
| OpenRouter | API key | Multi-model gateway. |
| Ollama | LAN (default `http://localhost:11434`) | No key. |
| Custom | URL + optional key | Any OpenAI-compatible endpoint. |
| Local (embedded, desktop only) | — | `llama-cpp-2` with Metal. Power mode (cool/balanced/performance) drives GPU layers + thread count. Optional preload on app start. Idle-evict timer (default 10 min) drops the model from VRAM. |
| **On-device MLX (iOS)** | — | Qwen 2.5 3B Instruct 4-bit default (`mlx-community/Qwen2.5-3B-Instruct-4bit`), Llama 3.2 3B, Phi-3.5 Mini selectable. Via `plugins/tauri-plugin-skim-ai/` Swift plugin. Downloaded to HuggingFace cache in `Documents/huggingface/models/<repo>`. Evicted on app background + thermal `.serious`/`.critical`. |
| **Apple Foundation Models (iOS 26+)** | — | `SystemLanguageModel.default`. Apple-managed, no download. Typed guided generation via `@Generable` structs (used for triage JSON). |

Tool-use (web search, future tools): supported on `anthropic`, `claude-subscription`, `claude-cli`. Other providers receive a log-and-drop fallback so calls still succeed without tools.

---

## 11. OAuth

### 11.1 Claude subscription
- Endpoints: `https://claude.ai/oauth/authorize` + `https://console.anthropic.com/v1/oauth/token`.
- PKCE (S256).
- Desktop: loopback listener + system browser.
- Mobile/paste: show authorize URL, user pastes the `code#state` back.
- Tokens persisted in settings KV (`claude_oauth_access_token`, `claude_oauth_refresh_token`, `claude_oauth_expires_at`). Access tokens expire in 8h; refresh token rotates.
- Rust commands: `claude_oauth_sign_in_loopback`, `claude_oauth_begin_paste`, `claude_oauth_exchange_paste`, `claude_oauth_refresh`, `claude_oauth_sign_out`, `claude_oauth_status`.

### 11.2 Feedly
- OAuth at `cloud.feedly.com/v3/auth/{auth,token}`.
- Redirect URI: `http://127.0.0.1:54321/feedly/callback`.
- Tokens in `feedly_token` / `feedly_refresh_token` / `feedly_token_expires_at`. Auto-refresh if <60s from expiry.

---

## 12. Settings

Tabs: AI Provider, Sync, Appearance.

- AI Provider: choice, API key / OAuth sign-in UI, model override, chat-specific provider override, summary length/tone/format/custom prompt, triage user prompt (§3.4), local model picker + preload/idle-evict/power mode.
- Sync: refresh interval, max articles per feed, recent cap.
- Appearance: theme (dark default), font size, show excerpt in list.

---

## 13. Data model (SQLite)

Tables: `feeds`, `articles`, `article_summaries`, `article_triage`, `article_interactions`, `themes`, `folders`, `settings` (KV).

- `~/Library/Application Support/skim/skim.db` on macOS.
- WAL mode, foreign keys on.
- Migrations on app start (`src-tauri/src/db/migrations.rs`).

---

## 14. Platform targets

| Target | State |
|---|---|
| macOS | Shipping. Tauri desktop, native title bar + blur. |
| Windows | Builds clean; unsupported in release pipeline today. |
| Linux | Builds clean; unsupported in release pipeline today. |
| iOS / iPadOS | In progress via `cargo tauri ios`. Tauri iOS project scaffolded at `src-tauri/gen/apple/`. Companion Swift plugin at `plugins/tauri-plugin-skim-ai/` wraps MLX + Foundation Models + iOS Keychain. Simulator/device build requires Xcode.app. |

---

## 15. Keyboard & input

- `j` / `k` next / previous article.
- `r` toggle read.
- `s` toggle starred.
- `/` focus search.
- `Cmd+N` add feed.
- Swipe actions on lists (iPad / touch): read/unread, star, skip (priority→1).
- Pull-to-refresh on article list.
- Drag-drop OPML file onto sidebar to import.

---

## 16. Non-goals (explicit)

- No cloud sync service owned by Skim. Feedly is the only upstream.
- No iOS↔macOS bidirectional sync yet (CloudKit port deferred — `skim-g2y`).
- No nested folders.
- No Android target at present.

---

## 17. Open follow-ups

Tracked in beads (`bd list --status=open`):

- Wire `ModelRouter` into triage/summary/chat call sites (`skim-hfg`).
- Parse dropped OPML content (iOS stub just logs).
- MLX triage JSON-quality validation on iPhone 15 Pro.
- Resumable/background URLSession download for MLX weights.
- `triageStructured` guided-generation path through `AIService` (iOS 26+).
- iOS on-device tier picker polish once Swift plugin compile lands.

---

*Snapshots in `docs/screenshots/`: 01 main view, 02 AI Inbox with themes, 03 auto-organize, 04 Ask Skim, 05 catch-up, 06 summarize.*
