import { useEffect, useRef, useState } from "react";
import type { ChatReply } from "./ChatMessageContent";

/** A question written while Skim was still answering, waiting its turn. */
export interface QueuedMessage {
  id: number;
  text: string;
  reply: ChatReply | null;
}

/**
 * Questions asked while an answer is in flight. They send one at a time, in
 * order, as each answer finishes. `paused` (an error, or a missing provider)
 * holds them until it clears; the head also waits while the reader edits it.
 */
export function useMessageQueue({ busy, paused, onSend }: {
  busy: boolean;
  paused: boolean;
  onSend: (message: QueuedMessage) => void;
}) {
  const [queue, setQueue] = useState<QueuedMessage[]>([]);
  const [editingId, setEditingId] = useState<number | null>(null);
  const nextId = useRef(1);
  const onSendRef = useRef(onSend);
  onSendRef.current = onSend;

  useEffect(() => {
    const head = queue[0];
    if (busy || paused || !head || head.id === editingId) return;
    setQueue((items) => items.slice(1));
    onSendRef.current(head);
  }, [busy, paused, queue, editingId]);

  return {
    queue,
    editingId,
    /** `first` puts it ahead of the rest, as for a question that failed to send. */
    enqueue: (text: string, reply: ChatReply | null, { first = false } = {}) => {
      const item = { id: nextId.current++, text, reply };
      setQueue((items) => first ? [item, ...items] : [...items, item]);
    },
    startEditing: (id: number) => setEditingId(id),
    /** Saving an empty question removes it. */
    save: (id: number, text: string) => {
      const trimmed = text.trim();
      setQueue((items) => trimmed
        ? items.map((item) => item.id === id ? { ...item, text: trimmed } : item)
        : items.filter((item) => item.id !== id));
      setEditingId(null);
    },
    cancelEditing: () => setEditingId(null),
    remove: (id: number) => {
      setQueue((items) => items.filter((item) => item.id !== id));
      setEditingId((current) => current === id ? null : current);
    },
    clear: () => { setQueue([]); setEditingId(null); },
  };
}

type Queue = ReturnType<typeof useMessageQueue>;

/** Queued questions as pending bubbles under the conversation, each editable and removable. */
export function QueuedMessages({ queue, paused, onResume, fontSize = 12 }: {
  queue: Queue;
  /** Shows that the queue is waiting on an error, with a way to carry on. */
  paused?: boolean;
  onResume?: () => void;
  fontSize?: number;
}) {
  if (queue.queue.length === 0) return null;
  return (
    <div role="list" aria-label="Queued messages" className="flex flex-col items-end" style={{ gap: 6, marginBottom: 8 }}>
      <div className="flex items-center gap-2 text-text-muted" style={{ fontSize: 10 }}>
        <span className="uppercase tracking-wider font-semibold">Queued</span>
        <span>{paused ? "paused after an error" : "sends when Skim finishes"}</span>
        {paused && onResume && (
          <button type="button" onClick={onResume} className="text-accent hover:underline" style={{ fontSize: 10 }}>
            Resume
          </button>
        )}
      </div>
      {queue.queue.map((item, index) => (
        <QueuedRow key={item.id} item={item} position={index + 1} queue={queue} fontSize={fontSize} />
      ))}
    </div>
  );
}

function QueuedRow({ item, position, queue, fontSize }: { item: QueuedMessage; position: number; queue: Queue; fontSize: number }) {
  const editing = queue.editingId === item.id;
  const [draft, setDraft] = useState(item.text);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    if (!editing) return;
    setDraft(item.text);
    const textarea = textareaRef.current;
    textarea?.focus({ preventScroll: true });
    textarea?.setSelectionRange(textarea.value.length, textarea.value.length);
  }, [editing]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div
      role="listitem"
      aria-label={`Queued message ${position}`}
      className="queued-message rounded-xl rounded-br-sm text-text-secondary"
      style={{ fontSize, maxWidth: "85%", minWidth: editing ? "60%" : undefined, lineHeight: 1.4 }}
    >
      {item.reply && (
        <div className="text-text-muted truncate" style={{ fontSize: 10, marginBottom: 2 }}>
          {item.reply.role === "article" ? "From the article" : item.reply.role === "story" ? "From the story" : `Replying to ${item.reply.role === "assistant" ? "Skim" : "you"}`}: “{item.reply.text}”
        </div>
      )}
      {editing ? (
        <textarea
          ref={textareaRef}
          aria-label="Edit queued message"
          value={draft}
          rows={Math.min(4, Math.max(1, draft.split("\n").length))}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); queue.save(item.id, draft); }
            if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); queue.cancelEditing(); }
          }}
          onBlur={() => queue.save(item.id, draft)}
          className="w-full bg-transparent text-text-primary resize-none focus:outline-none"
          style={{ fontSize, lineHeight: 1.4, padding: 0 }}
        />
      ) : (
        <div className="flex items-start gap-2">
          <span className="flex-1 min-w-0 whitespace-pre-wrap break-words">{item.text}</span>
          <span className="queued-message-actions flex items-center flex-shrink-0" style={{ gap: 2, marginTop: -2 }}>
            <button
              type="button"
              onClick={() => queue.startEditing(item.id)}
              className="rounded-md text-text-muted hover:text-text-primary hover:bg-white/10"
              style={{ padding: 3, lineHeight: 0 }}
              aria-label="Edit queued message"
              title="Edit"
            >
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M12 20h9" />
                <path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z" />
              </svg>
            </button>
            <button
              type="button"
              onClick={() => queue.remove(item.id)}
              className="rounded-md text-text-muted hover:text-text-primary hover:bg-white/10"
              style={{ padding: 3, lineHeight: 0 }}
              aria-label="Remove queued message"
              title="Remove"
            >
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M18 6L6 18M6 6l12 12" />
              </svg>
            </button>
          </span>
        </div>
      )}
    </div>
  );
}
