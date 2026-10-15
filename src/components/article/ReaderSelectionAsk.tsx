import { useEffect, useState, type RefObject } from "react";
import "../chat/chat-markdown.css";

/**
 * Floating "Ask in chat" button over text the reader highlights in the
 * article. `containerRef` must be positioned (relative) and hold the article
 * text; the button is placed just above the selection inside it.
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
        top: Math.max(0, bounds.top - container.top - 48),
        left: Math.max(0, Math.min(bounds.left - container.left, container.width - 140)),
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
      style={{ top: selection.top, left: selection.left, whiteSpace: "nowrap" }}
      onPointerDown={(event) => event.preventDefault()}
      onMouseDown={(event) => event.preventDefault()}
      onClick={() => {
        onAsk(selection.text);
        window.getSelection()?.removeAllRanges();
        setSelection(null);
      }}
    >
      <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true" style={{ display: "inline", marginRight: 6, verticalAlign: "-2px" }}>
        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
      </svg>
      Ask in chat
    </button>
  );
}
