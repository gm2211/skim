import { useEffect, useState, type RefObject } from "react";
import "../chat/chat-markdown.css";

/** Matches `.reader-selection-ask` in chat-markdown.css. */
const PILL_HEIGHT = 28;
const PILL_GAP = 6;

/**
 * Where the pill goes for a selection: above it when the pill still fits
 * inside the selected block, otherwise below. Anchoring to the block, not to
 * the container, keeps the pill off whatever sits above — a selection in the
 * first line of the lead paragraph used to park it on the headline.
 */
function pillTop(range: Range, bounds: DOMRect, containerTop: number): number {
  const node = range.startContainer;
  const block = (node.nodeType === Node.ELEMENT_NODE ? (node as Element) : node.parentElement)?.closest(
    "p, li, blockquote, h1, h2, h3, h4, h5, h6, pre, td, div",
  );
  const limit = block?.getBoundingClientRect().top ?? bounds.top;
  const above = bounds.top - PILL_HEIGHT - PILL_GAP;
  return (above >= limit ? above : bounds.bottom + PILL_GAP) - containerTop;
}

/**
 * Floating "Ask in chat" button over text the reader highlights in the
 * article. `containerRef` must be positioned (relative) and hold the article
 * text; the button is placed just outside the selection inside it.
 */

export function ReaderSelectionAsk({ containerRef, onAsk }: {
  containerRef: RefObject<HTMLElement | null>;
  onAsk: (text: string) => void;
}) {
  const [selection, setSelection] = useState<{ text: string; top: number; left: number } | null>(null);

  useEffect(() => {
    const update = () => {
      const selected = window.getSelection();
      const element = containerRef.current;
      if (!element || !selected || selected.isCollapsed || !selected.rangeCount) {
        setSelection(null);
        return;
      }
      const range = selected.getRangeAt(0);
      const text = selected.toString().trim();
      // Only a selection that sits wholly inside the article text counts.
      if (!text || !element.contains(range.startContainer) || !element.contains(range.endContainer)) {
        setSelection(null);
        return;
      }
      const bounds = range.getBoundingClientRect();
      const container = element.getBoundingClientRect();
      setSelection({
        text,
        top: Math.max(0, pillTop(range, bounds, container.top)),
        left: Math.max(0, Math.min(bounds.left - container.left, container.width - 80)),
      });
    };
    document.addEventListener("selectionchange", update);
    return () => document.removeEventListener("selectionchange", update);
  }, [containerRef]);

  if (!selection) return null;
  return (
    <button
      type="button"
      className="chat-selection-reply reader-selection-ask"
      aria-label="Ask in chat"
      title="Ask in chat"
      style={{ top: selection.top, left: selection.left }}
      onPointerDown={(event) => event.preventDefault()}
      onMouseDown={(event) => event.preventDefault()}
      onClick={() => {
        onAsk(selection.text);
        window.getSelection()?.removeAllRanges();
        setSelection(null);
      }}
    >
      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
      </svg>
      Ask
    </button>
  );
}
