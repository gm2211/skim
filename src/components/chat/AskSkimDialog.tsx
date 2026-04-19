import { useEffect, useRef, useState } from "react";
import { chatWithArticles, type ArticleChatResponse } from "../../services/commands";
import type { ChatMessageInput } from "../../services/types";

type Scope = "inbox" | "unread" | "all";

interface Message {
  role: "user" | "assistant";
  content: string;
  citedIds?: string[];
}

interface Props {
  onClose: () => void;
  onOpenArticle?: (articleId: string) => void;
}

export function AskSkimDialog({ onClose }: Props) {
  const [scope, setScope] = useState<Scope>("inbox");
  const [input, setInput] = useState("");
  const [messages, setMessages] = useState<Message[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages, loading]);

  const send = async () => {
    const query = input.trim();
    if (!query || loading) return;
    setError(null);

    const userMsg: Message = { role: "user", content: query };
    const next = [...messages, userMsg];
    setMessages(next);
    setInput("");
    setLoading(true);

    const history: ChatMessageInput[] = messages.map((m) => ({ role: m.role, content: m.content }));

    try {
      const resp: ArticleChatResponse = await chatWithArticles(scope, query, history);
      setMessages((m) => [
        ...m,
        { role: "assistant", content: resp.content, citedIds: resp.article_ids },
      ]);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
      setMessages((m) => m.slice(0, -1));
      setInput(query);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div
      className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50"
      onClick={onClose}
    >
      <div
        className="border border-white/10 rounded-2xl shadow-2xl flex flex-col"
        style={{
          background: "rgba(22, 27, 34, 0.98)",
          width: "min(720px, 92vw)",
          height: "min(720px, 85vh)",
          margin: "0 20px",
        }}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div
          className="flex items-center justify-between border-b border-white/5"
          style={{ padding: "14px 18px" }}
        >
          <div className="flex items-center gap-2">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-accent">
              <circle cx="11" cy="11" r="8" />
              <path d="M21 21l-4.35-4.35" />
            </svg>
            <h3 className="text-text-primary" style={{ fontSize: 15, fontWeight: 600 }}>
              Ask Skim
            </h3>
            <span className="text-text-muted" style={{ fontSize: 12 }}>
              — search your feed
            </span>
          </div>
          <div className="flex items-center gap-2">
            <select
              value={scope}
              onChange={(e) => setScope(e.target.value as Scope)}
              className="border border-white/10 rounded-lg text-text-primary"
              style={{ background: "rgba(255, 255, 255, 0.05)", padding: "5px 10px", fontSize: 12 }}
            >
              <option value="inbox">Inbox (priority ≥ 3)</option>
              <option value="unread">Unread</option>
              <option value="all">All articles</option>
            </select>
            <button
              onClick={onClose}
              className="text-text-muted hover:text-text-primary transition-colors"
              title="Close (Esc)"
            >
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M18 6L6 18M6 6l12 12" />
              </svg>
            </button>
          </div>
        </div>

        {/* Messages */}
        <div ref={scrollRef} className="flex-1 overflow-y-auto" style={{ padding: "18px" }}>
          {messages.length === 0 && !loading && (
            <div className="text-center text-text-muted" style={{ padding: "40px 20px" }}>
              <p style={{ fontSize: 13, marginBottom: 10 }}>
                Ask anything about articles in your feed.
              </p>
              <div className="flex flex-col gap-1" style={{ fontSize: 12, opacity: 0.7 }}>
                <span>“what's new with shyam sankar”</span>
                <span>“which article covered work ethic”</span>
                <span>“summarize this week's AI news”</span>
              </div>
            </div>
          )}

          {messages.map((m, i) => (
            <div
              key={i}
              className={m.role === "user" ? "flex justify-end" : "flex justify-start"}
              style={{ marginBottom: 12 }}
            >
              <div
                className={
                  m.role === "user"
                    ? "bg-accent/20 text-text-primary rounded-2xl"
                    : "bg-white/5 text-text-primary rounded-2xl"
                }
                style={{
                  padding: "10px 14px",
                  fontSize: 13,
                  maxWidth: "88%",
                  whiteSpace: "pre-wrap",
                  wordBreak: "break-word",
                }}
              >
                {m.content}
              </div>
            </div>
          ))}

          {loading && (
            <div className="flex items-center gap-2 text-text-muted" style={{ padding: "6px 2px" }}>
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                className="animate-spin"
              >
                <path d="M21 12a9 9 0 11-6.219-8.56" />
              </svg>
              <span style={{ fontSize: 12 }}>Searching articles…</span>
            </div>
          )}

          {error && (
            <p className="text-danger" style={{ fontSize: 12 }}>
              {error}
            </p>
          )}
        </div>

        {/* Input */}
        <div className="border-t border-white/5" style={{ padding: "12px 16px" }}>
          <div className="flex items-end gap-2">
            <textarea
              ref={inputRef}
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  send();
                }
                if (e.key === "Escape") onClose();
              }}
              placeholder="Ask about your articles… (Enter to send, Shift+Enter for newline)"
              rows={2}
              className="flex-1 border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors resize-none"
              style={{ background: "rgba(255, 255, 255, 0.05)", padding: "10px 12px", fontSize: 13 }}
            />
            <button
              onClick={send}
              disabled={loading || !input.trim()}
              className="bg-accent text-white rounded-xl hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors flex-shrink-0"
              style={{ padding: "10px 16px", fontSize: 13 }}
            >
              Send
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
