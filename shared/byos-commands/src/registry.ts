import { isAsyncSource, type AsyncCommandSource, type Command, type CommandSource, type SyncCommandSource } from './command.js';

export type CommandRegistry = {
  /** Add or replace (by id) a source. Returns a function that removes it. */
  register: (source: CommandSource) => () => void;
  /** Sync sources with their current commands, in browse order. */
  syncSources: () => Array<{ source: SyncCommandSource; commands: readonly Command[] }>;
  asyncSources: () => AsyncCommandSource[];
  /** Every sync command, flattened in browse order. */
  commands: () => Command[];
  /** Called whenever a source is added, replaced, or removed. */
  subscribe: (listener: () => void) => () => void;
};

export function createCommandRegistry(initial: readonly CommandSource[] = []): CommandRegistry {
  const sources = new Map<string, { source: CommandSource; seq: number }>();
  const listeners = new Set<() => void>();
  let seq = 0;
  const notify = () => listeners.forEach(listener => listener());
  const ordered = () => [...sources.values()]
    .sort((a, b) => (a.source.order ?? a.seq) - (b.source.order ?? b.seq) || a.seq - b.seq)
    .map(entry => entry.source);

  const register = (source: CommandSource) => {
    const existing = sources.get(source.id);
    const entry = { source, seq: existing?.seq ?? seq++ };
    sources.set(source.id, entry);
    notify();
    return () => {
      if (sources.get(source.id) !== entry) return;
      sources.delete(source.id);
      notify();
    };
  };
  initial.forEach(register);

  const syncSources = () => ordered()
    .filter((source): source is SyncCommandSource => !isAsyncSource(source))
    .map(source => ({ source, commands: source.commands() }));

  return {
    register,
    syncSources,
    asyncSources: () => ordered().filter(isAsyncSource),
    commands: () => syncSources().flatMap(entry => entry.commands),
    subscribe: listener => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}
