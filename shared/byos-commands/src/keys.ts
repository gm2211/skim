type KeyEventLike = Pick<KeyboardEvent, 'key' | 'metaKey' | 'ctrlKey' | 'altKey' | 'shiftKey'> &
  Partial<Pick<KeyboardEvent, 'repeat' | 'isComposing' | 'defaultPrevented' | 'keyCode'>>;

/** True while an input method editor (Japanese, Chinese, Korean…) is still building a character. */
export function isComposing(event: KeyEventLike): boolean {
  return !!event.isComposing || event.keyCode === 229;
}

/** ⌘K on macOS, Ctrl+K elsewhere: no Shift or Option, no key repeat, never mid-composition. Works inside text fields. */
export function isPaletteShortcut(event: KeyEventLike): boolean {
  return !event.defaultPrevented
    && !event.repeat
    && !isComposing(event)
    && !event.altKey
    && !event.shiftKey
    && (event.metaKey || event.ctrlKey)
    && event.key.toLowerCase() === 'k';
}

export type PaletteKeyAction = 'next' | 'previous' | 'first' | 'last' | 'run' | 'ask' | 'askFull' | 'back' | 'close';

/**
 * What a key in the palette's input does. `back` is Backspace on an empty input
 * (leave an answer, drop a context chip); the controller decides whether it applies.
 */
export function paletteKeyAction(event: KeyEventLike, inputEmpty: boolean): PaletteKeyAction | null {
  if (isComposing(event)) return null;
  const { key } = event;
  if (key === 'Escape') return 'close';
  if (key === 'ArrowDown' || (event.ctrlKey && !event.metaKey && key === 'n')) return 'next';
  if (key === 'ArrowUp' || (event.ctrlKey && !event.metaKey && key === 'p')) return 'previous';
  if (key === 'Home' && !inputEmpty) return null;
  if (key === 'Home') return 'first';
  if (key === 'End' && !inputEmpty) return null;
  if (key === 'End') return 'last';
  if (key === 'Enter' && (event.metaKey || event.ctrlKey)) return 'askFull';
  if (key === 'Enter' && event.shiftKey) return 'ask';
  if (key === 'Enter') return 'run';
  if (key === 'Backspace' && inputEmpty) return 'back';
  return null;
}

export function isMacPlatform(): boolean {
  if (typeof navigator === 'undefined') return true;
  return /mac|iphone|ipad/i.test(navigator.platform || navigator.userAgent);
}

/** "mod" → ⌘ or Ctrl, "shift" → ⇧ or Shift, "alt" → ⌥ or Alt, single letters upper-cased. */
export function formatShortcutKey(key: string, mac = isMacPlatform()): string {
  if (key === 'mod') return mac ? '⌘' : 'Ctrl';
  if (key === 'shift') return mac ? '⇧' : 'Shift';
  if (key === 'alt') return mac ? '⌥' : 'Alt';
  if (key === 'escape') return 'Esc';
  return key.length === 1 ? key.toUpperCase() : key;
}

/** The `aria-keyshortcuts` value for the open shortcut. */
export const PALETTE_ARIA_SHORTCUTS = 'Meta+K Control+K';
