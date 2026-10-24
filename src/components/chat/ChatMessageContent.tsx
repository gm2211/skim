import { useEffect, useRef, useState } from "react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { ChatSource } from "../../services/commands";
import { citationChip, linkCitations } from "./AgentAnswer";
import "./chat-markdown.css";

/** The articles an answer cites, so its [n] become chips that open them. */
export interface ChatCitations {
  sources: ChatSource[];
  onOpenArticle: (id: string) => void;
  onHoverSource?: (id: string | null) => void;
  highlightId?: string | null;
}

export interface ChatReply {
  /** "article" is a passage the reader highlighted in the article itself. */
  role: "user" | "assistant" | "article";
  text: string;
}

/** Keep quoted text in every subsequent history turn, not just the first send. */
export function chatPrompt(content: string, reply?: ChatReply | null): string {
  if (!reply) return content;
  const lead = reply.role === "article" ? "About this passage from the article" : `Replying to ${reply.role === "assistant" ? "Skim" : "my message"}`;
  return `${lead}:\n${reply.text.split("\n").map((line) => `> ${line}`).join("\n")}\n\n${content}`;
}

export function ReplyPreview({ reply, onRemove }: { reply: ChatReply; onRemove?: () => void }) {
  return (
    <div className="chat-reply-preview" role={onRemove ? "note" : undefined} aria-label="Quoted text">
      <div className="flex items-center justify-between gap-2">
        <span className="text-text-secondary">{reply.role === "article" ? "From the article" : `Replying to ${reply.role === "assistant" ? "Skim" : "you"}`}</span>
        {onRemove && <button type="button" onClick={onRemove} className="tap-target rounded-lg hover:bg-white/10" aria-label="Remove quoted text">×</button>}
      </div>
      <blockquote>{reply.text}</blockquote>
    </div>
  );
}

export function ChatMessageContent({ content, role, onReply, replyDisabled = false, citations }: {
  content: string;
  role: "user" | "assistant";
  onReply: (reply: ChatReply) => void;
  replyDisabled?: boolean;
  citations?: ChatCitations;
}) {
  const titles = new Map((citations?.sources ?? []).map((source) => [source.id, source.title]));
  const contentRef = useRef<HTMLDivElement>(null);
  const [selection, setSelection] = useState<{ text: string; top: number; left: number } | null>(null);

  useEffect(() => {
    const update = () => {
      const selected = window.getSelection();
      const element = contentRef.current;
      if (replyDisabled || !element || !selected || selected.isCollapsed || !selected.rangeCount) {
        setSelection(null);
        return;
      }
      const text = selected.toString().trim();
      const range = selected.getRangeAt(0);
      if (!text || !range.intersectsNode(element)) { setSelection(null); return; }
      // WebKit can place a selection endpoint on the bubble's parent element.
      // Accept it only when all selected text still belongs to this message.
      const clipped = range.cloneRange();
      const messageRange = document.createRange();
      messageRange.selectNodeContents(element);
      if (clipped.compareBoundaryPoints(Range.START_TO_START, messageRange) < 0) clipped.setStart(messageRange.startContainer, messageRange.startOffset);
      if (clipped.compareBoundaryPoints(Range.END_TO_END, messageRange) > 0) clipped.setEnd(messageRange.endContainer, messageRange.endOffset);
      if (clipped.toString().trim() !== range.toString().trim()) { setSelection(null); return; }
      const bounds = range.getBoundingClientRect();
      const container = element.getBoundingClientRect();
      setSelection({ text, top: Math.max(0, bounds.top - container.top - 44), left: Math.max(0, Math.min(bounds.left - container.left, container.width - 150)) });
    };
    document.addEventListener("selectionchange", update);
    return () => document.removeEventListener("selectionchange", update);
  }, [content, replyDisabled]);

  return (
    <div className="chat-message-content" style={{ position: "relative", minWidth: 0 }}>
      <div ref={contentRef} className="chat-markdown">
        <Markdown remarkPlugins={[remarkGfm]} skipHtml components={{
          a: ({ href, children }) => (citations && citationChip(href, children, { titles, ...citations })) || (href && /^https?:\/\//i.test(href)
            ? <a href={href} target="_blank" rel="noopener noreferrer" onClick={(event) => { event.preventDefault(); void openUrl(href).catch(() => {}); }}>{children}</a>
            : <span>{children}</span>),
          table: ({ children }) => <div className="chat-table-scroll"><table>{children}</table></div>,
          img: ({ alt }) => <span>{alt}</span>,
        }}>{citations ? linkCitations(content, citations.sources) : content}</Markdown>
      </div>
      {selection && !replyDisabled && (
        <button type="button" className="chat-selection-reply" style={{ top: selection.top, left: selection.left }}
          onPointerDown={(event) => event.preventDefault()}
          onClick={() => { onReply({ role, text: selection.text }); window.getSelection()?.removeAllRanges(); setSelection(null); }}>
          Reply to selection
        </button>
      )}
    </div>
  );
}
