import { createContext, useContext, useEffect, useId, useMemo, useRef, useSyncExternalStore, type ReactNode, type RefObject } from 'react';
import {
  PALETTE_ARIA_SHORTCUTS, PALETTE_CSS, createCommandRegistry, createPaletteController, defaultPaletteStrings, formatShortcutKey, isAskCommand, isPaletteShortcut,
  type AskBinding, type AskTurn, type Command, type CommandRegistry, type CommandSource, type PaletteController, type PaletteState, type PaletteStrings,
} from '@byos/commands';

type PaletteContextValue = { registry: CommandRegistry; controller: PaletteController; strings: PaletteStrings };
const PaletteContext = createContext<PaletteContextValue | null>(null);

function usePaletteContext(): PaletteContextValue {
  const value = useContext(PaletteContext);
  if (!value) throw new Error('Wrap the application in <CommandPaletteProvider>.');
  return value;
}

export type CommandPaletteProviderProps = {
  children?: ReactNode;
  /** Sources registered for the provider's lifetime (global navigation, byosAiCommands). */
  sources?: readonly CommandSource[];
  ask?: AskBinding;
  strings?: Partial<PaletteStrings>;
  /** Glyph for a command's icon name. Ask rows request "sparkle". */
  renderIcon?: (name: string) => ReactNode;
  /** Render an assistant turn (markdown, citations). Default: plain text. */
  renderAnswer?: (turn: AskTurn) => ReactNode;
  /** Extra content under the list, e.g. connection or sync status. */
  status?: ReactNode;
  /** Listen for ⌘K / Ctrl+K on the window. Default true. */
  shortcut?: boolean;
  /** Runs a closing command after the palette closes. Default: next macrotask. */
  schedule?: (run: () => void) => void;
  onError?: (error: unknown) => void;
  onOpenChange?: (open: boolean) => void;
  /** Insert the palette styles once per document. Default true; pass false when you import @byos/commands/styles.css. */
  injectStyles?: boolean;
  className?: string;
};

/** Hosts one command palette for the tree: registry, ⌘K, dialog, focus return, and the Ask flow. */
export function CommandPaletteProvider({ children, sources, ask, strings, renderIcon, renderAnswer, status, shortcut = true, schedule, onError, onOpenChange, injectStyles = true, className = '' }: CommandPaletteProviderProps) {
  const text = { ...defaultPaletteStrings, ...strings };
  const latest = useRef({ ask, onError, onOpenChange });
  latest.current = { ask, onError, onOpenChange };
  const dialogRef = useRef<HTMLDialogElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const openerRef = useRef<HTMLElement | null>(null);

  const value = useMemo(() => {
    const registry = createCommandRegistry();
    // Read the latest binding on each call, so the application can pass a new object every render.
    const binding: AskBinding | undefined = ask && {
      get label() { return latest.current.ask?.label ?? ask.label; },
      get minQuery() { return latest.current.ask?.minQuery; },
      ask: (query, options) => (latest.current.ask ?? ask).ask(query, options),
      openFull: ask.openFull && ((query, history) => (latest.current.ask ?? ask).openFull?.(query, history)),
    };
    const controller = createPaletteController({
      registry,
      ask: binding,
      schedule,
      onError: error => latest.current.onError?.(error),
      onOpenChange: open => {
        if (open && typeof document !== 'undefined') {
          const active = document.activeElement;
          openerRef.current = active instanceof HTMLElement && active !== document.body ? active : null;
        }
        latest.current.onOpenChange?.(open);
      },
    });
    return { registry, controller };
    // The binding shape (present or not, with or without openFull) is fixed for the provider's lifetime.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  const { registry, controller } = value;
  const state = useSyncExternalStore(controller.subscribe, controller.getState, controller.getState);

  useEffect(() => {
    const removers = (sources ?? []).map(source => registry.register(source));
    return () => removers.forEach(remove => remove());
  }, [registry, sources]);

  useEffect(() => () => controller.destroy(), [controller]);

  useEffect(() => {
    if (!injectStyles || document.getElementById('byos-palette-styles')) return;
    const style = document.createElement('style');
    style.id = 'byos-palette-styles';
    style.textContent = PALETTE_CSS;
    document.head.append(style);
  }, [injectStyles]);

  useEffect(() => {
    if (!shortcut) return;
    const onKey = (event: KeyboardEvent) => {
      if (!isPaletteShortcut(event)) return;
      event.preventDefault();
      event.stopPropagation();
      controller.toggle();
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, [controller, shortcut]);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (state.open) {
      if (!dialog.open) dialog.showModal?.();
      inputRef.current?.focus();
      return;
    }
    if (dialog.open) dialog.close();
    const opener = openerRef.current;
    openerRef.current = null;
    if (opener?.isConnected && !opener.closest('dialog[open]')) opener.focus();
  }, [state.open]);

  const context = useMemo(() => ({ registry, controller, strings: text }), [registry, controller, JSON.stringify(strings ?? {})]);

  return <PaletteContext.Provider value={context}>
    {children}
    <dialog ref={dialogRef} className={`byos-palette ${className}`.trim()} aria-label={text.dialogLabel}
      onCancel={event => { event.preventDefault(); controller.close(); }}
      onMouseDown={event => { if (event.target === event.currentTarget) controller.close(); }}>
      {state.open && <PalettePanel state={state} controller={controller} strings={text} inputRef={inputRef}
        hasAsk={!!ask} canOpenFull={!!ask?.openFull} renderIcon={renderIcon} renderAnswer={renderAnswer} status={status}/>}
    </dialog>
  </PaletteContext.Provider>;
}

type PanelProps = {
  state: PaletteState;
  controller: PaletteController;
  strings: PaletteStrings;
  inputRef: RefObject<HTMLInputElement | null>;
  hasAsk: boolean;
  canOpenFull: boolean;
  renderIcon?: (name: string) => ReactNode;
  renderAnswer?: (turn: AskTurn) => ReactNode;
  status?: ReactNode;
};

function PalettePanel({ state, controller, strings, inputRef, hasAsk, canOpenFull, renderIcon, renderAnswer, status }: PanelProps) {
  const id = useId();
  const listRef = useRef<HTMLDivElement>(null);
  const chatting = state.mode === 'answered' || state.mode === 'pending';
  const mod = formatShortcutKey('mod');

  useEffect(() => {
    listRef.current?.querySelector(`[data-index="${state.active}"]`)?.scrollIntoView?.({ block: 'nearest' });
  }, [state.active, state.items]);

  return <div className="byos-palette-panel">
    <div className="byos-palette-search">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/></svg>
      <input ref={inputRef as RefObject<HTMLInputElement>} className="byos-palette-input" role="combobox" aria-expanded="true" aria-autocomplete="list"
        aria-controls={`${id}-list`} aria-label={strings.inputLabel} autoComplete="off" spellCheck={false}
        aria-activedescendant={state.items.length ? `${id}-option-${state.active}` : undefined}
        placeholder={chatting ? strings.followUpPlaceholder : hasAsk ? strings.placeholder : strings.placeholderNoAsk}
        readOnly={state.mode === 'pending'} value={state.query}
        onChange={event => controller.setQuery(event.target.value)}
        onKeyDown={event => { if (controller.handleKey(event.nativeEvent)) event.preventDefault(); }}/>
      <kbd>Esc</kbd>
    </div>
    <div ref={listRef} className="byos-palette-list" id={`${id}-list`} role="listbox" aria-label={strings.listLabel}>
      {chatting && <div className="byos-palette-conversation" aria-live="polite">
        {state.history.map((turn, index) => turn.role === 'user'
          ? <p key={index} className="byos-palette-question">{turn.content}</p>
          : <div key={index} className="byos-palette-answer">{renderAnswer ? renderAnswer(turn) : turn.content}</div>)}
        {state.mode === 'pending' && <p className="byos-palette-status" role="status">{strings.pending}</p>}
      </div>}
      {state.message && <p className="byos-palette-status" role="status">{state.message}</p>}
      {state.error && <p className="byos-palette-error" role="alert">{state.error}</p>}
      {!chatting && !state.items.length && <p className="byos-palette-empty">{strings.noMatches}</p>}
      {state.items.map((command, index) => <PaletteRow key={command.id} id={`${id}-option-${index}`} index={index} command={command}
        selected={index === state.active} header={state.showGroups && (index === 0 || state.items[index - 1].group !== command.group)}
        showTag={!state.showGroups} renderIcon={renderIcon} onHover={() => { if (index !== state.active) controller.setActive(index); }}
        onRun={() => controller.run(command)}/>)}
    </div>
    {status}
    <div className="byos-palette-footer">
      {chatting ? <>
        {state.query.trim() && <span><kbd>↵</kbd> {strings.hintAsk}</span>}
        <span><kbd>⌫</kbd> {strings.hintBack}</span>
        {canOpenFull && <button type="button" disabled={state.mode === 'pending'} onClick={() => controller.openFull()}>{strings.openFull} <kbd>{mod}</kbd><kbd>↵</kbd></button>}
      </> : <>
        <span><kbd>↑</kbd><kbd>↓</kbd> {strings.hintNavigate}</span>
        <span><kbd>↵</kbd> {strings.hintRun}</span>
        {canOpenFull && state.query.trim() && <span><kbd>{mod}</kbd><kbd>↵</kbd> {strings.hintAskFull}</span>}
        <span style={{ marginLeft: 'auto' }}><kbd>{mod}</kbd><kbd>K</kbd> {strings.hintToggle}</span>
      </>}
    </div>
  </div>;
}

type RowProps = {
  id: string;
  index: number;
  command: Command;
  selected: boolean;
  header: boolean;
  showTag: boolean;
  renderIcon?: (name: string) => ReactNode;
  onHover: () => void;
  onRun: () => void;
};

function PaletteRow({ id, index, command, selected, header, showTag, renderIcon, onHover, onRun }: RowProps) {
  const ask = isAskCommand(command);
  const icon = ask ? renderIcon?.('sparkle') : command.icon ? renderIcon?.(command.icon) : null;
  return <>
    {header && <div className="byos-palette-group" role="presentation">{command.group}</div>}
    <div id={id} data-index={index} role="option" aria-selected={selected}
      className={`byos-palette-option${ask ? ' byos-palette-option-ask' : ''}`} onMouseMove={onHover} onClick={onRun}>
      <span className="byos-palette-icon" aria-hidden="true">{icon}</span>
      <span className="byos-palette-title">{ask && <span className="byos-palette-ask-label">{command.group}: </span>}{command.title}</span>
      {command.detail && <span className="byos-palette-detail">{command.detail}</span>}
      <span className="byos-palette-spacer"/>
      {showTag && !ask && <span className="byos-palette-tag">{command.group}</span>}
      {command.shortcut?.length ? <span className="byos-palette-keys">{command.shortcut.map(key => <kbd key={key}>{formatShortcutKey(key)}</kbd>)}</span> : null}
    </div>
  </>;
}

/**
 * Register commands while the calling component is mounted. Pass the values the
 * commands read as `deps`; the list rebuilds when they change.
 */
export function useCommands(source: CommandSource, deps: readonly unknown[]): void {
  const { registry } = usePaletteContext();
  useEffect(() => registry.register(source), [registry, source.id, ...deps]);
}

/** Open, close, or read the palette from anywhere under the provider. */
export function usePalette() {
  const { controller, registry } = usePaletteContext();
  const state = useSyncExternalStore(controller.subscribe, controller.getState, controller.getState);
  return { state, registry, controller, open: controller.open, close: controller.close, toggle: controller.toggle };
}

export type CommandPaletteButtonProps = { className?: string; label?: string; children?: ReactNode };

/** A visible way to open the palette, with its shortcut. */
export function CommandPaletteButton({ className = '', label, children }: CommandPaletteButtonProps) {
  const { controller, strings } = usePaletteContext();
  const mac = typeof navigator === 'undefined' || /mac|iphone|ipad/i.test(navigator.platform || navigator.userAgent);
  return <button type="button" className={`byos-palette-trigger ${className}`.trim()} aria-keyshortcuts={PALETTE_ARIA_SHORTCUTS}
    onClick={() => controller.open()}>
    {children ?? <span>{label ?? strings.trigger}</span>}<kbd aria-hidden="true">{mac ? '⌘ K' : 'Ctrl K'}</kbd>
  </button>;
}
