/** One row the palette can show and run. */
export type Command = {
  /** Stable id; also how an Ask result names a command to run. */
  id: string;
  title: string;
  /** Section heading while browsing; a tag on the row while searching. */
  group: string;
  /** Extra words the command answers to, e.g. "preferences" for Settings. */
  keywords?: readonly string[];
  /** Secondary text after the title (a feed's folder, a hunt's status). Searched at keyword weight. */
  detail?: string;
  /** Application icon name; the renderer maps it to a glyph. */
  icon?: string;
  /** Keys as written in the shortcut, e.g. ["mod", ","]. See formatShortcutKey. */
  shortcut?: readonly string[];
  /** Run without closing the palette first (an inline ask, a toggle the user watches). */
  stay?: boolean;
  /** Hidden while browsing; only appears for a matching query. */
  searchOnly?: boolean;
  run: () => void | Promise<void>;
};

/** Commands that are cheap to list: evaluated on every keystroke and ranked locally. */
export type SyncCommandSource = {
  id: string;
  /** Lower sorts first while browsing. Defaults to registration order. */
  order?: number;
  /** Return no commands (or omit) when they do not apply in the current view. */
  commands: () => readonly Command[];
  /** Commands shown while browsing, before any query. Defaults to all non-searchOnly commands. */
  browseLimit?: number;
};

/** Commands that need a lookup (server search). Already ordered by the source, never re-ranked. */
export type AsyncCommandSource = {
  id: string;
  order?: number;
  search: (query: string, signal: AbortSignal) => Promise<readonly Command[]>;
  /** Shortest trimmed query that triggers a lookup. Default 2. */
  minQuery?: number;
  /** Wait this long after the last keystroke. Default 150 ms. */
  debounceMs?: number;
  /** Most rows shown. Default 8. */
  limit?: number;
};

export type CommandSource = SyncCommandSource | AsyncCommandSource;

export function isAsyncSource(source: CommandSource): source is AsyncCommandSource {
  return typeof (source as AsyncCommandSource).search === 'function';
}
