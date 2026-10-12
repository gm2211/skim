import type { Command, CommandSource } from './command.js';
import { createPaletteController, isAskCommand, type AskBinding, type AskTurn, type PaletteController, type PaletteState } from './controller.js';
import { formatShortcutKey, isPaletteShortcut } from './keys.js';
import { createCommandRegistry, type CommandRegistry } from './registry.js';
import { defaultPaletteStrings, type PaletteStrings } from './strings.js';
import { PALETTE_CSS } from './styles.js';

export type MountPaletteOptions = {
  registry?: CommandRegistry;
  sources?: readonly CommandSource[];
  ask?: AskBinding;
  strings?: Partial<PaletteStrings>;
  /** Where the dialog is appended. Default document.body. */
  container?: Element;
  /** Listen for ⌘K / Ctrl+K on the window. Default true. */
  shortcut?: boolean;
  /** Insert the default styles once per document. Default true; pass false when you load styles.css yourself. */
  injectStyles?: boolean;
  /** Icon markup for a command's icon name. Return '' for none. The string is inserted as HTML: return trusted markup only. */
  renderIcon?: (name: string) => string;
  /** Fill an assistant turn's element yourself (markdown, citations). Default: plain text. */
  renderAnswer?: (turn: AskTurn, element: HTMLElement) => void;
  onError?: (error: unknown) => void;
  /** Most ranked commands shown for a query. Default: all matches. */
  limit?: number;
};

export type MountedPalette = {
  registry: CommandRegistry;
  controller: PaletteController;
  element: HTMLDialogElement;
  open: () => void;
  close: () => void;
  toggle: () => void;
  destroy: () => void;
};

const escape = (value: string) => value.replace(/[&<>"']/g, ch => `&#${ch.charCodeAt(0)};`);
const kbd = (key: string) => `<kbd>${escape(key)}</kbd>`;
const SEARCH_ICON = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/></svg>';
let uid = 0;

/** A complete palette without a framework: dialog, keys, focus return, Ask flow. Same markup and classes as the React component. */
export function mountPalette(options: MountPaletteOptions = {}): MountedPalette {
  const text = { ...defaultPaletteStrings, ...options.strings };
  const registry = options.registry ?? createCommandRegistry();
  options.sources?.forEach(source => registry.register(source));
  const doc = (options.container ?? document.body).ownerDocument;
  if (options.injectStyles !== false && !doc.getElementById('byos-palette-styles')) {
    const style = doc.createElement('style');
    style.id = 'byos-palette-styles';
    style.textContent = PALETTE_CSS;
    doc.head.append(style);
  }

  const id = `byos-palette-${++uid}`;
  const dialog = doc.createElement('dialog');
  dialog.className = 'byos-palette';
  dialog.setAttribute('aria-label', text.dialogLabel);
  dialog.innerHTML = `<div class="byos-palette-panel">
    <div class="byos-palette-search">${SEARCH_ICON}<input class="byos-palette-input" role="combobox" aria-expanded="true" aria-autocomplete="list" aria-controls="${id}-list" aria-label="${escape(text.inputLabel)}" autocomplete="off" spellcheck="false">${kbd('Esc')}</div>
    <div class="byos-palette-list" id="${id}-list" role="listbox" aria-label="${escape(text.listLabel)}"></div>
    <div class="byos-palette-footer"></div>
  </div>`;
  (options.container ?? doc.body).append(dialog);
  const input = dialog.querySelector('input')!;
  const list = dialog.querySelector<HTMLElement>('.byos-palette-list')!;
  const footer = dialog.querySelector<HTMLElement>('.byos-palette-footer')!;
  let opener: HTMLElement | null = null;

  const controller = createPaletteController({
    registry,
    ask: options.ask,
    onError: options.onError,
    limit: options.limit,
    onOpenChange: open => {
      if (open) {
        const active = doc.activeElement;
        opener = active instanceof HTMLElement && active !== doc.body ? active : null;
        if (!dialog.open) dialog.showModal();
        input.focus();
        return;
      }
      if (dialog.open) dialog.close();
      const target = opener;
      opener = null;
      if (target?.isConnected && !target.closest('dialog[open]')) target.focus();
    },
  });

  const rowHtml = (command: Command, index: number, state: PaletteState) => {
    const selected = index === state.active;
    const ask = isAskCommand(command);
    const icon = ask ? options.renderIcon?.('sparkle') ?? '' : command.icon ? options.renderIcon?.(command.icon) ?? '' : '';
    const header = state.showGroups && (index === 0 || state.items[index - 1].group !== command.group)
      ? `<div class="byos-palette-group" role="presentation">${escape(command.group)}</div>` : '';
    const title = ask
      ? `<span class="byos-palette-title"><span class="byos-palette-ask-label">${escape(command.group)}: </span>${escape(command.title)}</span>`
      : `<span class="byos-palette-title">${escape(command.title)}</span>`;
    return `${header}<div class="byos-palette-option${ask ? ' byos-palette-option-ask' : ''}" role="option" id="${id}-option-${index}" data-index="${index}" aria-selected="${selected}">`
      + `<span class="byos-palette-icon" aria-hidden="true">${icon}</span>${title}`
      + (command.detail ? `<span class="byos-palette-detail">${escape(command.detail)}</span>` : '')
      + '<span class="byos-palette-spacer"></span>'
      + (!state.showGroups && !ask ? `<span class="byos-palette-tag">${escape(command.group)}</span>` : '')
      + (command.shortcut?.length ? `<span class="byos-palette-keys">${command.shortcut.map(key => kbd(formatShortcutKey(key))).join('')}</span>` : '')
      + '</div>';
  };

  const render = () => {
    const state = controller.getState();
    if (!state.open) return;
    const chatting = state.mode === 'answered' || state.mode === 'pending';
    if (input.value !== state.query) input.value = state.query;
    input.placeholder = chatting ? text.followUpPlaceholder : options.ask ? text.placeholder : text.placeholderNoAsk;
    input.readOnly = state.mode === 'pending';
    if (state.items.length) input.setAttribute('aria-activedescendant', `${id}-option-${state.active}`);
    else input.removeAttribute('aria-activedescendant');

    list.replaceChildren();
    if (chatting) {
      const conversation = doc.createElement('div');
      conversation.className = 'byos-palette-conversation';
      conversation.setAttribute('aria-live', 'polite');
      for (const turn of state.history) {
        const element = doc.createElement(turn.role === 'user' ? 'p' : 'div');
        element.className = turn.role === 'user' ? 'byos-palette-question' : 'byos-palette-answer';
        if (turn.role === 'assistant' && options.renderAnswer) options.renderAnswer(turn, element);
        else element.textContent = turn.content;
        conversation.append(element);
      }
      if (state.mode === 'pending') {
        const pending = doc.createElement('p');
        pending.className = 'byos-palette-status';
        pending.setAttribute('role', 'status');
        pending.textContent = text.pending;
        conversation.append(pending);
      }
      list.append(conversation);
    }
    if (state.message) list.insertAdjacentHTML('beforeend', `<p class="byos-palette-status" role="status">${escape(state.message)}</p>`);
    if (state.error) list.insertAdjacentHTML('beforeend', `<p class="byos-palette-error" role="alert">${escape(state.error)}</p>`);
    if (!chatting && !state.items.length) list.insertAdjacentHTML('beforeend', `<p class="byos-palette-empty">${escape(text.noMatches)}</p>`);
    list.insertAdjacentHTML('beforeend', state.items.map((command, index) => rowHtml(command, index, state)).join(''));
    list.querySelector(`#${id}-option-${state.active}`)?.scrollIntoView?.({ block: 'nearest' });

    const mod = formatShortcutKey('mod');
    const hints = chatting
      ? [state.query.trim() ? `<span>${kbd('↵')} ${escape(text.hintAsk)}</span>` : '', `<span>${kbd('⌫')} ${escape(text.hintBack)}</span>`]
      : [`<span>${kbd('↑')}${kbd('↓')} ${escape(text.hintNavigate)}</span>`, `<span>${kbd('↵')} ${escape(text.hintRun)}</span>`,
        options.ask?.openFull && state.query.trim() ? `<span>${kbd(mod)}${kbd('↵')} ${escape(text.hintAskFull)}</span>` : ''];
    const full = chatting && options.ask?.openFull ? `<button type="button" data-open-full${state.mode === 'pending' ? ' disabled' : ''}>${escape(text.openFull)} ${kbd(mod)}${kbd('↵')}</button>` : '';
    footer.innerHTML = hints.join('') + (full || `<span style="margin-left:auto">${kbd(mod)}${kbd('K')} ${escape(text.hintToggle)}</span>`);
  };

  const unsubscribe = controller.subscribe(render);
  input.addEventListener('input', () => controller.setQuery(input.value));
  input.addEventListener('keydown', event => { if (controller.handleKey(event)) event.preventDefault(); });
  list.addEventListener('click', event => {
    const row = (event.target as Element).closest<HTMLElement>('[data-index]');
    if (row) controller.run(controller.getState().items[Number(row.dataset.index)]);
  });
  list.addEventListener('mousemove', event => {
    const row = (event.target as Element).closest<HTMLElement>('[data-index]');
    if (row && Number(row.dataset.index) !== controller.getState().active) controller.setActive(Number(row.dataset.index));
  });
  footer.addEventListener('click', event => { if ((event.target as Element).closest('[data-open-full]')) controller.openFull(); });
  dialog.addEventListener('cancel', event => { event.preventDefault(); controller.close(); });
  dialog.addEventListener('mousedown', event => { if (event.target === dialog) controller.close(); });

  const onShortcut = (event: KeyboardEvent) => {
    if (!isPaletteShortcut(event)) return;
    event.preventDefault();
    event.stopPropagation();
    controller.toggle();
  };
  const view = doc.defaultView;
  if (options.shortcut !== false) view?.addEventListener('keydown', onShortcut, true);

  return {
    registry,
    controller,
    element: dialog,
    open: controller.open,
    close: controller.close,
    toggle: controller.toggle,
    destroy: () => {
      view?.removeEventListener('keydown', onShortcut, true);
      unsubscribe();
      controller.destroy();
      dialog.remove();
    },
  };
}
