import type { Command } from './command.js';
import { askFirst, rankCommands } from './rank.js';
import { paletteKeyAction, type PaletteKeyAction } from './keys.js';
import type { CommandRegistry } from './registry.js';

export type AskTurn = {
  role: 'user' | 'assistant';
  content: string;
  /** Application data kept with an answer (sources, citations, ids) for its own renderer. */
  data?: unknown;
};

/** What the application's assistant decided. The palette acts on it; it never sees credentials. */
export type AskResult =
  /** Show an answer in the palette. `commands` are follow-up rows (cited items to open). */
  | { kind: 'answer'; text: string; data?: unknown; commands?: readonly Command[] }
  /** Run one of the palette's own commands by id. */
  | { kind: 'run'; commandId: string }
  /** Narrow the list to these command ids, in this order, with an optional note. */
  | { kind: 'filter'; commandIds: readonly string[]; message?: string }
  /** Close the palette and hand off to the application (open a draft, start a job). */
  | { kind: 'action'; perform: () => void };

export type AskBinding = {
  /** Row and heading label, e.g. "Ask Skim". */
  label: string;
  /** Shortest trimmed query that offers the Ask row. Default 2. */
  minQuery?: number;
  ask: (query: string, options: { history: readonly AskTurn[]; signal: AbortSignal }) => Promise<AskResult>;
  /** Continue in the application's full chat (⌘↵). */
  openFull?: (query: string, history: readonly AskTurn[]) => void;
};

export type PaletteMode = 'browse' | 'search' | 'pending' | 'answered' | 'filtered';

export type PaletteState = {
  open: boolean;
  query: string;
  mode: PaletteMode;
  items: readonly Command[];
  active: number;
  /** Show group headers (browsing) instead of a group tag per row (searching). */
  showGroups: boolean;
  history: readonly AskTurn[];
  /** Ask question in flight, for the pending row. */
  pendingQuery?: string;
  /** Note from a filter result. */
  message?: string;
  /** Last ask or command failure, as text. */
  error?: string;
  /** True while an async source lookup is running. */
  searching: boolean;
};

export type PaletteController = {
  getState: () => PaletteState;
  subscribe: (listener: () => void) => () => void;
  open: () => void;
  close: () => void;
  toggle: () => void;
  setQuery: (query: string) => void;
  setActive: (index: number) => void;
  move: (delta: number) => void;
  run: (command?: Command) => void;
  ask: (query?: string) => Promise<void>;
  openFull: () => void;
  /** Leave an answer or filter and return to the command list. */
  back: () => boolean;
  /** Stop an ask in flight and put its question back, e.g. when the person edits it. */
  cancel: () => void;
  /** Apply a key from the palette input. Returns true when handled (call preventDefault). */
  handleKey: (event: Parameters<typeof paletteKeyAction>[0]) => boolean;
  /** Rebuild items now (call when application state the commands read has changed). */
  refresh: () => void;
  destroy: () => void;
};

export type PaletteControllerOptions = {
  registry: CommandRegistry;
  ask?: AskBinding;
  /** How a closing command is run after the palette closes. Default: next macrotask, so focus returns first. */
  schedule?: (run: () => void) => void;
  onOpenChange?: (open: boolean) => void;
  onError?: (error: unknown) => void;
  /** Most ranked commands shown for a query. Default: all matches. */
  limit?: number;
};

/** Id of the synthetic Ask row; renderers use it to style the row. */
export const ASK_COMMAND_ID = 'byos.ask';
export const isAskCommand = (command: Command) => command.id === ASK_COMMAND_ID;

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

export function createPaletteController(options: PaletteControllerOptions): PaletteController {
  const { registry, ask: binding } = options;
  const schedule = options.schedule ?? ((run: () => void) => { setTimeout(run, 0); });
  const listeners = new Set<() => void>();
  let state: PaletteState = { open: false, query: '', mode: 'browse', items: [], active: 0, showGroups: true, history: [], searching: false };
  let askAbort: AbortController | null = null;
  const lookups = new Map<string, { query: string; rows: readonly Command[] }>();
  const timers = new Map<string, ReturnType<typeof setTimeout>>();
  const aborts = new Map<string, AbortController>();

  const set = (next: Partial<PaletteState>) => {
    state = { ...state, ...next };
    if (state.active >= state.items.length) state = { ...state, active: Math.max(0, state.items.length - 1) };
    listeners.forEach(listener => listener());
  };

  const askRow = (query: string): Command => ({
    id: ASK_COMMAND_ID,
    title: query,
    group: binding!.label,
    stay: true,
    run: () => { void controller.ask(query); },
  });

  const listItems = (query: string) => {
    const trimmed = query.trim();
    if (!trimmed) {
      const items = registry.syncSources().flatMap(({ source, commands }) =>
        commands.filter(command => !command.searchOnly).slice(0, source.browseLimit ?? Infinity));
      return { items, showGroups: true };
    }
    const all = registry.commands();
    const ranked = rankCommands(all, trimmed, options.limit);
    const seen = new Set(ranked.map(command => command.id));
    const found: Command[] = [];
    for (const source of registry.asyncSources()) {
      const lookup = lookups.get(source.id);
      if (lookup?.query !== trimmed) continue;
      for (const row of lookup.rows.slice(0, source.limit ?? 8)) {
        if (seen.has(row.id)) continue;
        seen.add(row.id);
        found.push(row);
      }
    }
    if (!binding || trimmed.length < (binding.minQuery ?? 2)) return { items: [...ranked, ...found], showGroups: false };
    const row = askRow(trimmed);
    return { items: askFirst(all, trimmed) ? [row, ...ranked, ...found] : [...ranked, row, ...found], showGroups: false };
  };

  const rebuild = () => {
    if (!state.open || state.mode === 'pending' || state.mode === 'answered' || state.mode === 'filtered') return;
    const { items, showGroups } = listItems(state.query);
    set({ items, showGroups, mode: state.query.trim() ? 'search' : 'browse' });
  };

  const stopLookups = () => {
    timers.forEach(timer => clearTimeout(timer));
    timers.clear();
    aborts.forEach(abort => abort.abort());
    aborts.clear();
  };

  const lookup = (query: string) => {
    stopLookups();
    const trimmed = query.trim();
    let running = false;
    for (const source of registry.asyncSources()) {
      if (trimmed.length < (source.minQuery ?? 2)) continue;
      running = true;
      timers.set(source.id, setTimeout(() => {
        timers.delete(source.id);
        const abort = new AbortController();
        aborts.set(source.id, abort);
        source.search(trimmed, abort.signal).then(rows => {
          if (abort.signal.aborted) return;
          lookups.set(source.id, { query: trimmed, rows });
        }, error => {
          if (!abort.signal.aborted) options.onError?.(error);
        }).finally(() => {
          if (aborts.get(source.id) !== abort) return;
          aborts.delete(source.id);
          if (state.query.trim() === trimmed) set({ searching: aborts.size + timers.size > 0 });
          rebuild();
        });
      }, source.debounceMs ?? 150));
    }
    return running;
  };

  const stopAsk = () => {
    askAbort?.abort();
    askAbort = null;
  };

  // Put the question back so it can be retried or edited.
  const restore = (prior: readonly AskTurn[], query: string, error?: string) => {
    state = { ...state, mode: prior.length ? 'answered' : 'search', pendingQuery: undefined, history: prior, query, error };
    if (prior.length) set({ items: state.items });
    else rebuild();
  };

  const unsubscribeRegistry = registry.subscribe(() => rebuild());

  const controller: PaletteController = {
    getState: () => state,
    subscribe: listener => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    open: () => {
      if (state.open) return;
      state = { ...state, open: true, query: '', mode: 'browse', history: [], error: undefined, message: undefined, pendingQuery: undefined, active: 0 };
      rebuild();
      options.onOpenChange?.(true);
    },
    close: () => {
      if (!state.open) return;
      stopAsk();
      stopLookups();
      lookups.clear();
      set({ open: false, query: '', mode: 'browse', items: [], history: [], error: undefined, message: undefined, pendingQuery: undefined, searching: false, active: 0 });
      options.onOpenChange?.(false);
    },
    toggle: () => (state.open ? controller.close() : controller.open()),
    setQuery: query => {
      if (state.mode === 'pending') return;
      if (state.mode === 'answered') {
        // Typing in an answer writes a follow-up; the cited rows stay until it is sent.
        set({ query, error: undefined });
        return;
      }
      state = { ...state, query, active: 0, error: undefined, message: undefined, mode: 'search' };
      state = { ...state, searching: lookup(query) };
      rebuild();
    },
    setActive: index => set({ active: Math.max(0, Math.min(index, state.items.length - 1)) }),
    move: delta => {
      const count = state.items.length;
      if (count) set({ active: (Math.min(state.active, count - 1) + delta + count) % count });
    },
    run: (command = state.items[state.active]) => {
      if (!command) return;
      const call = () => {
        try {
          const result = command.run();
          if (result instanceof Promise) result.catch(error => options.onError?.(error));
        } catch (error) {
          options.onError?.(error);
        }
      };
      if (command.stay) { call(); return; }
      controller.close();
      schedule(call);
    },
    ask: async (raw = state.query) => {
      const query = raw.trim();
      if (!binding || !query || state.mode === 'pending') return;
      stopAsk();
      stopLookups();
      const abort = new AbortController();
      askAbort = abort;
      const prior = state.history;
      const history: AskTurn[] = [...prior, { role: 'user', content: query }];
      set({ mode: 'pending', pendingQuery: query, query: '', items: [], history, error: undefined, message: undefined });
      try {
        const result = await binding.ask(query, { history: prior, signal: abort.signal });
        if (abort.signal.aborted) return;
        askAbort = null;
        if (result.kind === 'answer') {
          set({ mode: 'answered', pendingQuery: undefined, history: [...history, { role: 'assistant', content: result.text, data: result.data }], items: result.commands ?? [], active: 0, showGroups: false });
        } else if (result.kind === 'run') {
          const command = registry.commands().find(entry => entry.id === result.commandId);
          if (!command) throw new Error('That command is no longer available. Search again.');
          set({ mode: 'browse', pendingQuery: undefined });
          controller.run(command);
        } else if (result.kind === 'filter') {
          const all = registry.commands();
          const items = result.commandIds.map(id => all.find(entry => entry.id === id)).filter((entry): entry is Command => !!entry);
          set({ mode: 'filtered', pendingQuery: undefined, query, items, active: 0, showGroups: false, message: result.message, history: prior });
        } else {
          controller.close();
          schedule(() => {
            try { result.perform(); } catch (error) { options.onError?.(error); }
          });
        }
      } catch (error) {
        if (abort.signal.aborted) return;
        askAbort = null;
        restore(prior, query, message(error));
      }
    },
    openFull: () => {
      if (!binding?.openFull || state.mode === 'pending') return;
      const query = state.query.trim();
      if (!query && !state.history.length) return;
      const history = state.history;
      controller.close();
      schedule(() => binding.openFull!(query, history));
    },
    back: () => {
      if (state.mode !== 'answered' && state.mode !== 'filtered') return false;
      state = { ...state, mode: 'browse', history: [], query: '', error: undefined, message: undefined };
      rebuild();
      return true;
    },
    cancel: () => {
      if (state.mode !== 'pending') return;
      stopAsk();
      restore(state.history.slice(0, -1), state.pendingQuery ?? '');
    },
    handleKey: event => {
      const action: PaletteKeyAction | null = paletteKeyAction(event, !state.query);
      if (!action) return false;
      if (state.mode === 'pending') {
        if (action === 'close') { controller.close(); return true; }
        return action !== 'back';
      }
      switch (action) {
        case 'close': controller.close(); return true;
        case 'next': controller.move(1); return true;
        case 'previous': controller.move(-1); return true;
        case 'first': controller.setActive(0); return true;
        case 'last': controller.setActive(state.items.length - 1); return true;
        case 'askFull':
          if (!binding?.openFull) return false;
          controller.openFull();
          return true;
        case 'ask':
          if (!binding || !state.query.trim()) return false;
          void controller.ask();
          return true;
        case 'run':
          if (state.mode === 'answered' && state.query.trim()) void controller.ask();
          else controller.run();
          return true;
        case 'back': return controller.back();
      }
    },
    refresh: rebuild,
    destroy: () => {
      stopAsk();
      stopLookups();
      unsubscribeRegistry();
      listeners.clear();
    },
  };
  return controller;
}
