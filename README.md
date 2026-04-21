# Skim

RSS reader for the age of AI. Ingest feeds, let a model triage the noise, skim the rest.

Built with [Tauri 2](https://tauri.app) (Rust + React + TypeScript), runs natively on macOS / Windows / Linux. iOS / iPadOS is in progress (via Tauri mobile + a companion Swift plugin for MLX and Apple Foundation Models).

![Main view](docs/screenshots/01-main-view.png)

## Features

### Three-pane reader
Sidebar with folders + feeds, middle column with the article list, detail on the right. Unread counts per feed and folder. Keyboard-friendly. Favicons on every card.

### AI Inbox — priority-triaged reading queue
Every unread article gets scored 1–5 with a one-line reason. `MUST READ` rises to the top; routine and noise sinks. Topic chips across the top slice the inbox by theme.

Triage learns from engagement:
- reading time per article
- stars
- articles you summarize or chat about
- explicit `more like this` / `less like this` feedback
- priority overrides

You can also provide a free-form "what I care about" prompt in Settings that runs alongside the learned profile.

![AI Inbox](docs/screenshots/02-ai-inbox-themes.png)

### Auto-organize with AI
Proposes folders based on your feeds — rename, uncheck, or drop before applying. Two modes: keep existing folders (only touch unassigned feeds) or reorganize everything. Folder-name casing configurable (kebab / snake / Title Case).

![Auto-organize](docs/screenshots/03-auto-organize.png)

### Ask Skim — chat over your feed
Natural-language question → answer grounded in your articles, with numbered citations. Scope to `All articles`, `Unread`, or a specific folder/feed. Chat has a `web_search` tool available when your feed doesn't cover the topic.

![Ask Skim](docs/screenshots/04-ask-skim.png)

### Super-quick catch-up
Ten Top Takeaways + Notable Mentions across everything unread, with source links. One button, one re-run when needed.

![Catch-up](docs/screenshots/05-catchup.png)

### Summarize any article
Length (short / medium / long), tone (concise / detailed / casual / technical), format (bullets / paragraph), plus an optional custom prompt ("focus on financial implications", etc.). Reader view for cleaner formatting; Web view for the original.

![Summarize](docs/screenshots/06-summarize.png)

### Per-article chat
Ask questions about a specific article; model grounds on full body text + your prior conversation. Same `web_search` tool available.

### Folders: manual + smart
Drag feeds into manual folders, or define smart folders with regex rules (title match, URL match, OPML category). Evaluated both backend and frontend so smart-folder views update instantly.

### Feed sources
- RSS / Atom / JSON Feed
- OPML import/export
- Feedly OAuth sync (read state + stars sync both ways)

### AI providers
Pick per-task or default across the app:

| Provider | How auth works |
|---|---|
| **Claude Pro/Max subscription** | OAuth sign-in with your claude.ai account. No API key. Uses your subscription. |
| Claude (API key) | `sk-ant-...` |
| Claude CLI (legacy) | Delegates to local `claude -p` |
| OpenAI | API key |
| OpenRouter | API key |
| Ollama | Local LAN |
| Custom | Any OpenAI-compatible endpoint |
| Local (embedded) | llama.cpp with Metal acceleration, desktop only |
| **On-device MLX** | Qwen 2.5 3B (default) on iOS via `mlx-swift` |
| **Apple Foundation Models** | iOS 26+, Apple-managed on-device model |

### Engagement & learning
Skim tracks what you read, skip, star, chat about, and override — and feeds that profile into triage so the AI Inbox sharpens over time.

## Dev setup

```bash
# frontend deps
pnpm install

# run desktop dev
pnpm tauri dev

# production build
pnpm tauri build
```

Rust 1.94+ and Node 20+ required. iOS build additionally needs Xcode.app + `cargo install tauri-cli --version "^2.0.0"` + `brew install cocoapods`.

## Architecture overview

- **Frontend**: React 19, Vite, Tailwind, Zustand, TanStack Query.
- **Backend**: Rust (Tauri 2), SQLite (WAL), `reqwest`, `feed-rs`.
- **AI**: provider abstraction in `src-tauri/src/ai/provider.rs`; OAuth flow in `src-tauri/src/ai/claude_oauth.rs`; local models via `llama-cpp-2` on desktop; MLX + Apple Foundation Models via `plugins/tauri-plugin-skim-ai/` on iOS.
- **Sync**: All data local in SQLite (`~/Library/Application Support/skim/skim.db` on macOS). Feedly acts as an upstream feed source only.

See [`docs/SPEC.md`](docs/SPEC.md) for the full feature spec.

## License

See [`LICENSE`](LICENSE).
