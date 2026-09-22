# Running Skim in a browser

Skim is a Tauri app: the UI talks to Rust over an IPC channel that only exists
inside a webview. That makes the app hard to drive anywhere there is no macOS
or iOS build — a Linux box, a container, a CI job, or a screenshot script.

The dev bridge closes that gap. It stands the real backend up on Tauri's mock
runtime and re-exposes every command over HTTP; a small shim installs the two
globals `@tauri-apps/api` looks for and forwards `invoke` to it. The database,
the feed fetcher, the reader extractor and the AI providers are the real ones.
Nothing under `src/` or `src-tauri/src/commands/` knows the difference, and the
bridge is behind a non-default cargo feature so it is never in a release
bundle.

## Start it

```sh
# 1. the backend, over HTTP on :1421
cargo run --manifest-path src-tauri/Cargo.toml --features devbridge -- --dev-bridge

# 2. the frontend, pointed at it
SKIM_DEV_BRIDGE=1 pnpm dev        # http://localhost:1420
```

`SKIM_BRIDGE_DATA_DIR` puts the database somewhere other than the app data
directory, which is how you get a throwaway library:

```sh
SKIM_BRIDGE_DATA_DIR=/tmp/skim-scratch cargo run ... -- --dev-bridge
```

`SKIM_DEV_BRIDGE` can also be a full URL if the bridge is not on :1421.

## Feeds and a model, without a network

Two scripts stand in for the parts of the internet a sandbox cannot reach.

```sh
node scripts/dev-newsstand.mjs    # :4545 — four tech feeds + full article pages
node scripts/dev-llm.mjs          # :4546 — an OpenAI-compatible model server
```

Add `http://127.0.0.1:4545/feed/ars-technica.xml` (and the other three, listed
at `/feeds.json`) as feeds. For AI, pick **Ollama** or **Custom** in Settings
and set the endpoint to `http://127.0.0.1:4546`. That path backs `openai`,
`xai`, `openrouter`, `ollama` and `custom`, so exercising it exercises the
request shaping, JSON-mode parsing and error handling all five share.

Responses from `dev-llm` are derived from the prompt rather than generated:
deterministic, obviously synthetic, and useless as journalism.

## What it does not cover

The mock runtime has no window, so anything that depends on a real webview is
out of scope: native menus, window effects, drag and drop, the macOS and iOS
native AI plugins (`mlx`, `foundation-models`), and the `local`/`ds4` providers
that load a model into the host process. Those still need a real build.
