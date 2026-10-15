# @byos/commands

A command palette (⌘K / Ctrl+K) shared by BYOS applications. The core is framework-free; `@byos/react` adds `<CommandPaletteProvider>`, and `mountPalette` renders the same palette without a framework.

It never calls a provider and never sees a credential. The application's `ask` binding talks to its own assistant; `byosAiCommands` only reads public connection metadata.

## What you get

| Piece | What it does |
| --- | --- |
| `Command`, sources | A command is data plus one `run`. Features register sync sources (cheap lists, ranked locally) or async sources (server search, debounced and aborted). |
| `rankCommands` | Tiered ranking: exact, prefix, word prefix, all terms, substring, initials (`qc` → Quick Catch-up), typo-tolerant letters (`refrsh`), then every term anywhere across title, keywords and detail (`collapse side` → Hide sidebar). Titles outrank keywords; ties keep registration order. |
| `isPaletteShortcut`, `paletteKeyAction` | ⌘K / Ctrl+K toggles, also inside text fields, never on repeat, with Shift or Option, or while an input method is composing. In the list: ↑ ↓ and Ctrl+N / Ctrl+P wrap, Home / End on an empty input, ↵ runs, ⇧↵ asks, ⌘↵ continues in full chat, ⌫ on an empty input goes back, Esc closes. |
| `createPaletteController` | State machine: browse (group headers) → search (flat ranked list, group tag per row) → pending → answered or filtered. Runs a closing command on the next macrotask so focus returns first. Closing aborts the ask and lookups. `limit` caps ranked rows for a query; `cancel()` stops an ask in flight and puts the question back. |
| `AskBinding` | Typed text that is not a command becomes “Ask <App>”, first when it reads like a question. The assistant returns an `answer` (with optional follow-up rows), `run` a command id, `filter` to command ids, or an `action` to hand off. |
| `byosAiCommands` | AI settings, Connect / Reconnect, Change AI model, Change AI service, Disconnect (search-only), with the provider and model as detail. |
| `mountPalette` | Plain DOM renderer for static and string-template applications: dialog, keys, focus return, Ask flow. |
| `PALETTE_CSS`, `styles.css` | Styles on the shared `--byos-*` tokens with neutral fallbacks. Both renderers insert them once unless `injectStyles` is false. |

## React

```tsx
import { byosAiCommands } from '@byos/commands';
import { CommandPaletteProvider, CommandPaletteButton, useCommands } from '@byos/react';

const aiCommands = byosAiCommands({ status: readAiStatus, openSettings: section => openSettings('ai', section) });

<CommandPaletteProvider
  sources={[navigation, aiCommands]}
  ask={{ label: 'Ask Skim', ask: (query, { history, signal }) => askAgent(query, history, signal), openFull }}
  renderIcon={name => <Icon name={name} />}
  renderAnswer={turn => <AgentAnswer {...(turn.data as AnswerData)} />}
>
  <App />
</CommandPaletteProvider>

// Inside a feature: commands exist only while it is mounted.
useCommands({ id: 'article', commands: () => article ? [
  { id: 'article.summarize', group: 'Article', title: 'Summarize article', keywords: ['ai', 'tldr'], icon: 'sparkle', run: summarize },
] : [] }, [article]);
```

Keep `sources` stable (module scope or `useMemo`); a new array re-registers them.

## Without a framework

```js
import { mountPalette, byosAiCommands } from './vendor/byos/byos.js';

const palette = mountPalette({
  sources: [{ id: 'workspace', commands: () => workspaceRows() }, byosAiCommands({ status, openSettings })],
  ask: { label: 'Ask AI', ask: query => runAgentCommand(query) },
});
// palette.registry.register(...) later; palette.controller.refresh() after app state changes.
```

A page that inlines its client code in one classic `<script>` (no modules) can inline `@byos/commands/classic.js` ahead of it instead. It defines a global `ByosCommands` with the same exports.

## Ask results

```ts
type AskResult =
  | { kind: 'answer'; text: string; data?: unknown; commands?: Command[] } // stays open, multi-turn
  | { kind: 'run'; commandId: string }                                      // run one of the palette's commands
  | { kind: 'filter'; commandIds: string[]; message?: string }              // narrow the list
  | { kind: 'action'; perform: () => void };                                // close and hand off
```

`ask` receives the earlier turns and an `AbortSignal`. Throw an `Error` with a message the person can act on; the palette puts their question back with that message.

## Credential boundary

`AiCommandStatus` holds display names and booleans only. Do not pass tokens, keys, account ids, or raw provider errors to it, to `AskResult`, or to command text.
