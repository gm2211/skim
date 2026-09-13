import { useEffect, useRef, type RefObject } from "react";

// Keep keyboard navigation inside an active modal and restore its opener.
// Disable while another dialog (such as provider settings) takes its place.
export function useDialogFocus(ref: RefObject<HTMLElement | null>, onClose: () => void, enabled = true) {
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    if (!enabled || !ref.current) return;
    const dialog = ref.current;
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const controls = () => Array.from(dialog.querySelectorAll<HTMLElement>(
      'button:not(:disabled), a[href], input:not(:disabled), textarea:not(:disabled), select:not(:disabled), [tabindex="0"]',
    )).filter((el) => !el.closest('[hidden], [aria-hidden="true"]'));
    if (!dialog.contains(document.activeElement)) (controls()[0] ?? dialog).focus();
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        close.current();
      } else if (event.key === "Tab") {
        const items = controls();
        const first = items[0] ?? dialog;
        const last = items[items.length - 1] ?? dialog;
        if (event.shiftKey && (document.activeElement === first || !dialog.contains(document.activeElement))) {
          event.preventDefault(); last.focus();
        } else if (!event.shiftKey && (document.activeElement === last || !dialog.contains(document.activeElement))) {
          event.preventDefault(); first.focus();
        }
      }
    };
    dialog.addEventListener("keydown", onKey);
    return () => {
      dialog.removeEventListener("keydown", onKey);
      if (previous?.isConnected) previous.focus();
    };
  }, [enabled, ref]);
}
