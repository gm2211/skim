# @byos/providers

Provider adapters for the bring-your-own-subscription kit. Design:
https://claude.ai/artifact/1sXmN1AvVjp7jVRefdCShW

- `openrouter()`, `grok()`, `groq()`, `huggingface({ clientId? })`: `ByosProvider` objects (sign-in
  methods, live model list, streaming chat). Pass `{ appTitle }` so OpenRouter attributes usage to
  your site. `huggingface()` offers PKCE "Sign in with Hugging Face" only when `clientId` is given
  (see `createHuggingFaceSignIn` in huggingface-sign-in.ts), otherwise just the pasted-token path.
- `endpointFor(provider, credential, { appTitle })`: the browser-direct base URL, headers and web
  search mechanism for each provider.
- `listOpenRouterModels`, `listModelsForEndpoint`, `readOpenRouterKeyInfo`: model discovery. Lists
  always come from the provider, never a hard-coded table.
- `buildXaiResponsesBody` / `parseXaiResponsesPayload`: Grok's `/responses` endpoint, the only place
  its web_search tool exists.

Browser adapters run in the browser and talk straight to the provider. The
token never goes to the site's own server. `claude()` talks to api.anthropic.com with an API key. Claude subscriptions are paused
(`CLAUDE_SUBSCRIPTIONS_PAUSED_NOTE`): Anthropic's terms do not let third-party apps use Claude.ai
sign-in, so a subscription token is refused before any request. Codex uses `@byos/browser-tls`.

`createOpenRouterSignIn({ credentialPersistence: 'session', ... })` keeps the connected
key in the current tab and migrates/removes legacy localStorage keys. The default
`'browser'` preserves cross-tab persistence and disconnect tombstones. Session mode
does not share keys across tabs; credential-free notifications cannot transfer them.
PKCE transactions retain their bounded temporary local fallback for callback recovery.

## On-device providers

`ON_DEVICE_PROVIDERS` describes `local` (embedded llama.cpp), `mlx`, and `foundation-models` (Apple Intelligence). `onDeviceProvidersFor({ kind, supportedProviders })` returns options only when `kind` is `native` and the host explicitly lists a supported binding. `browser` and `server` never expose these options, even if given supported IDs.

`createOnDeviceProvider(id, { runtime, bridge })` returns a credential-free adapter with `signIn: []`, `availability()`, `listModels(signal?)`, and `stream(request)`. It shares `CatalogModel`, `ChatRequest`, and `ChatEvent` types with browser adapters, but takes no token argument. The host bridge implements those three methods. Requests are gated by runtime, supported binding, and current bridge readiness before dispatch. Cancellation passes through to the bridge; hosts must honor the signal and release their engine resources when the iterator closes. Bridge failures use fixed public errors rather than leaking raw native diagnostics.

Native applications own model downloads, storage, engine/IPC lifecycle, and availability probes. `availability()` reports the latest readiness state synchronously; the host refreshes that state using its asynchronous platform checks. Unavailable reasons are user-facing text: never include credentials, prompts, outputs, or raw diagnostics. A listed binding may still need a model download or Apple Intelligence enabled before inference. No native SDK is bundled and no request falls back to a web service. See [binding example](../../docs/customization.md#on-device-models).
