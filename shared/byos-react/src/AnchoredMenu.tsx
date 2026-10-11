import { useLayoutEffect, useRef, useState, type CSSProperties, type HTMLAttributes, type ReactNode } from 'react';
import { createPortal } from 'react-dom';

type MenuLayout = {
  top: number | 'auto';
  bottom: number | 'auto';
  left: number;
  minWidth: number;
  maxHeight: number;
  placement: 'above' | 'below';
};

type AnchoredMenuProps = {
  anchorRef: { readonly current: HTMLElement | null };
  menuRef: { readonly current: HTMLDivElement | null };
  contentKey: string | number;
  children: ReactNode;
  portalContainer?: Element;
  className?: string;
} & HTMLAttributes<HTMLDivElement>;

const VIEWPORT_MARGIN = 8;
const MENU_GAP = 5;
const MAX_MENU_HEIGHT = 260;
const FLIP_THRESHOLD = 180;

function calculateLayout(anchor: DOMRect, menuWidth: number, menuHeight: number, viewportWidth: number, viewportHeight: number): MenuLayout {
  const below = viewportHeight - anchor.bottom - VIEWPORT_MARGIN;
  const above = anchor.top - VIEWPORT_MARGIN;
  const placeAbove = below < Math.max(FLIP_THRESHOLD, menuHeight) && above > below;
  const maxLeft = viewportWidth - menuWidth - VIEWPORT_MARGIN;
  const left = Math.max(VIEWPORT_MARGIN, Math.min(anchor.left, maxLeft));
  const usable = (placeAbove ? above : below) - MENU_GAP;
  return {
    top: placeAbove ? 'auto' : Math.round(anchor.bottom + MENU_GAP),
    bottom: placeAbove ? Math.round(viewportHeight - anchor.top + MENU_GAP) : 'auto',
    left: Math.round(left),
    minWidth: Math.round(anchor.width),
    maxHeight: Math.min(MAX_MENU_HEIGHT, Math.max(0, usable)),
    placement: placeAbove ? 'above' : 'below',
  };
}

function sameLayout(left: MenuLayout | null, right: MenuLayout): boolean {
  return !!left && left.top === right.top && left.bottom === right.bottom && left.left === right.left
    && left.minWidth === right.minWidth && left.maxHeight === right.maxHeight && left.placement === right.placement;
}

/** Portalled listbox that stays aligned to its trigger while scrollable ancestors move. */
export function AnchoredMenu({ anchorRef, menuRef, contentKey, children, portalContainer, className, ...listboxProps }: AnchoredMenuProps) {
  const [layout, setLayout] = useState<MenuLayout | null>(null);
  const layoutRef = useRef<MenuLayout | null>(null);

  useLayoutEffect(() => {
    let frame = 0;
    const reposition = () => {
      const anchor = anchorRef.current;
      if (!anchor) return;
      const rect = anchor.getBoundingClientRect();
      const menu = menuRef.current;
      const next = calculateLayout(rect, menu?.offsetWidth ?? rect.width, menu?.scrollHeight ?? FLIP_THRESHOLD, window.innerWidth, window.innerHeight);
      if (sameLayout(layoutRef.current, next)) return;
      layoutRef.current = next;
      setLayout(next);
    };
    const tick = () => { reposition(); frame = window.requestAnimationFrame(tick); };
    reposition();
    frame = window.requestAnimationFrame(tick);
    window.addEventListener('resize', reposition);
    window.addEventListener('scroll', reposition, { capture: true, passive: true });
    return () => {
      window.cancelAnimationFrame(frame);
      window.removeEventListener('resize', reposition);
      window.removeEventListener('scroll', reposition, { capture: true });
    };
  }, [anchorRef, menuRef, contentKey]);

  const style: CSSProperties = layout
    ? { position: 'fixed', top: layout.top, bottom: layout.bottom, left: layout.left, minWidth: layout.minWidth, maxHeight: layout.maxHeight, zIndex: 1200, visibility: 'visible' }
    : { position: 'fixed', zIndex: 1200, visibility: 'hidden' };

  return createPortal(
    <div
      ref={menuRef}
      className={`byos-searchable-options ${className ?? ''}`.trim()}
      data-floating-menu=""
      data-placement={layout?.placement ?? 'below'}
      style={style}
      {...listboxProps}
    >{children}</div>,
    portalContainer ?? document.body,
  );
}
