import { useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';

/**
 * The "AI" pill: shows which model and effort are in use and opens a small quick-settings popover.
 * With nothing connected it calls `onSetup` instead. On narrow screens the popover is a bottom sheet
 * portalled to <body>, so a site's floating headers cannot trap it under other layers.
 */
export type AiPillProps = {
  connected: boolean;
  /** Mark a connected account that needs reauthentication. */
  needsSignIn?: boolean;
  /** e.g. "gpt-5.6-sol · low". */
  label: string;
  setupLabel?: string;
  /** Accessible name for the unconnected setup button. */
  setupAriaLabel?: string;
  /** Accessible name for the connected button. Defaults to the current model/effort label. */
  ariaLabel?: string;
  prefix?: string;
  onSetup: () => void;
  /** Popover content; rendered only while open, so model-list calls happen when someone looks. */
  children: (close: () => void) => ReactNode;
  popoverLabel?: string;
  /** Media query that turns the popover into a bottom sheet. */
  sheetQuery?: string;
  /** Optional themed portal root outside clipped containers. Defaults to document.body. */
  portalContainer?: Element | DocumentFragment;
  className?: string;
  classNames?: { button?: string; prefix?: string; label?: string; popover?: string; backdrop?: string };
};

export function AiPill(props: AiPillProps) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const popoverRef = useRef<HTMLDivElement>(null);
  const popoverId = useId();
  const c = props.classNames ?? {};
  const sheetQuery = props.sheetQuery ?? '(max-width: 720px)';

  useEffect(() => {
    if (!props.connected) setOpen(false);
  }, [props.connected]);

  useEffect(() => {
    if (!open) return;
    const onPointer = (event: PointerEvent) => {
      const target = event.target as Node | null;
      // Portalled menus (a searchable select) mark themselves with data-floating-menu.
      if (target && (rootRef.current?.contains(target) || popoverRef.current?.contains(target) || (target as Element).closest?.('[data-floating-menu]'))) return;
      setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => { if (event.key === 'Escape') setOpen(false); };
    document.addEventListener('pointerdown', onPointer);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('pointerdown', onPointer);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  const [sheet, setSheet] = useState(false);
  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
      setSheet(false);
      return;
    }
    const media = window.matchMedia(sheetQuery);
    const update = () => setSheet(media.matches);
    update();
    media.addEventListener('change', update);
    return () => media.removeEventListener('change', update);
  }, [sheetQuery]);

  const label = props.connected ? props.label : (props.setupLabel ?? 'Set up');
  const close = () => setOpen(false);
  const popover = <Popover sheetRef={popoverRef} id={popoverId} label={props.popoverLabel ?? 'Quick AI settings'} className={`${c.popover ?? 'byos-pill-popover'}${sheet ? ' byos-pill-popover-sheet' : ''}`}>{props.children(close)}</Popover>;
  return <div className={`${props.className ?? 'byos byos-pill-root'}`} ref={rootRef}>
    <button
      type="button"
      className={`${c.button ?? 'byos-pill'}${props.connected ? ' connected' : ''}${props.needsSignIn ? ' byos-pill-needs-sign-in' : ''}`}
      aria-haspopup={props.connected ? 'dialog' : undefined}
      aria-expanded={props.connected ? open : undefined}
      aria-controls={props.connected && open ? popoverId : undefined}
      aria-label={props.connected ? (props.ariaLabel ?? `AI: ${label}. Change model or effort`) : (props.setupAriaLabel ?? 'Set up AI')}
      onClick={() => props.connected ? setOpen(current => !current) : props.onSetup()}
    >
      <i/> <span className={c.prefix ?? 'byos-pill-prefix'}>{props.prefix ?? 'AI'}</span><span className={c.label ?? 'byos-pill-label'}>{label}</span>
    </button>
    {open && props.connected && (sheet
      ? createPortal(<><div className={c.backdrop ?? 'byos-pill-backdrop'} aria-hidden="true"/>{popover}</>, props.portalContainer ?? document.body)
      : popover)}
  </div>;
}

function Popover({ id, label, className, sheetRef, children }: { id: string; label: string; className: string; sheetRef: { readonly current: HTMLDivElement | null }; children: ReactNode }) {
  return <div className={className} ref={sheetRef} id={id} role="dialog" aria-label={label}>{children}</div>;
}
