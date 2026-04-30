import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { chatWithArticles, type ArticleChatResponse, type ChatSource } from "../../services/commands";
import type { ChatMessageInput } from "../../services/types";
import { openUrl } from "@tauri-apps/plugin-opener";
import { useUiStore } from "../../stores/uiStore";
import { AIDisclaimer } from "../common/AIDisclaimer";

type Scope = "inbox" | "unread" | "all";

interface Message {
  role: "user" | "assistant";
  content: string;
  sources?: ChatSource[];
}

interface Props {
  onClose: () => void;
  onOpenArticle?: (articleId: string) => void;
}

export function AskSkimDialog({ onClose, onOpenArticle }: Props) {
  const isPhone = useUiStore((s) => s.isPhone);
  const [scope, setScope] = useState<Scope>("unread");
  const [input, setInput] = useState("");
  const [messages, setMessages] = useState<Message[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    if (isPhone) return;
    inputRef.current?.focus();
  }, [isPhone]);

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
        { role: "assistant", content: resp.content, sources: resp.sources },
      ]);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
      setMessages((m) => m.slice(0, -1));
      setInput(query);
    } finally {
      setLoading(false);
    }
  };

  return createPortal(
    <div
      className={`fixed inset-0 bg-black/60 backdrop-blur-sm z-50 ${isPhone ? "" : "flex items-center justify-center"}`}
      onClick={onClose}
    >
      <div
        className={`${isPhone ? "fixed inset-0 overflow-hidden" : "border border-white/10 rounded-2xl shadow-2xl"} flex flex-col`}
        style={{
          background: "rgba(22, 27, 34, 0.98)",
          width: isPhone ? undefined : "min(720px, 92vw)",
          height: isPhone ? undefined : "min(720px, 85vh)",
          margin: isPhone ? 0 : "0 20px",
          paddingTop: isPhone ? 60 : 0,
          paddingBottom: isPhone ? 24 : 0,
        }}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div
          className="flex items-center gap-2 border-b border-white/5 flex-nowrap"
          style={{ padding: "12px 16px" }}
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-accent flex-shrink-0">
            <circle cx="11" cy="11" r="8" />
            <path d="M21 21l-4.35-4.35" />
          </svg>
          <h3 className="text-text-primary flex-shrink-0" style={{ fontSize: 15, fontWeight: 600, whiteSpace: "nowrap" }}>
            Ask Skim
          </h3>
          <select
            value={scope}
            onChange={(e) => setScope(e.target.value as Scope)}
            className="border border-white/10 rounded-lg text-text-primary flex-1 min-w-0"
            style={{ background: "rgba(255, 255, 255, 0.05)", padding: "5px 10px", fontSize: 12, width: 0, maxWidth: 200 }}
          >
            <option value="inbox">Inbox</option>
            <option value="unread">Unread</option>
            <option value="all">All</option>
          </select>
          <button
            onClick={onClose}
            className="text-text-muted hover:text-text-primary transition-colors flex-shrink-0"
            title="Close (Esc)"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Messages */}
        <div ref={scrollRef} className="flex-1 overflow-y-auto overflow-x-hidden min-w-0" style={{ padding: "18px" }}>
          {messages.length === 0 && !loading && (
            <div className="text-center text-text-muted" style={{ padding: "40px 20px" }}>
              <p style={{ fontSize: 13, marginBottom: 10 }}>
                Ask anything about articles in your feed.
              </p>
              <div className="flex flex-col gap-1" style={{ fontSize: 12, opacity: 0.7 }}>
                <span>“what are this week's biggest AI stories”</span>
                <span>“which article covered work ethic”</span>
                <span>“find pieces about distributed systems”</span>
              </div>
            </div>
          )}

          {messages.map((m, i) => (
            <div key={i} style={{ marginBottom: 14 }}>
              <div
                className={m.role === "user" ? "flex justify-end" : "flex justify-start"}
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
              {m.role === "assistant" && m.sources && m.sources.length > 0 && (
                <div style={{ marginTop: 8, paddingLeft: 4 }}>
                  <div
                    className="text-text-muted uppercase tracking-wider"
                    style={{ fontSize: 10, fontWeight: 600, marginBottom: 4 }}
                  >
                    Sources
                  </div>
                  <div className="flex flex-col gap-1">
                    {m.sources.map((s, idx) => {
                      const isWeb = s.source_type === "web";
                      return (
                        <button
                          key={s.id}
                          onClick={() => {
                            if (isWeb && s.url) {
                              openUrl(s.url);
                            } else if (onOpenArticle) {
                              onOpenArticle(s.id);
                              onClose();
                            } else if (s.url) {
                              openUrl(s.url);
                            }
                          }}
                          className="text-left rounded-lg border border-white/5 hover:border-accent/30 hover:bg-white/5 transition-colors"
                          style={{ padding: "6px 10px" }}
                        >
                          <div className="flex items-start gap-2">
                            <span
                              className="text-text-muted tabular-nums flex-shrink-0 flex items-center gap-1"
                              style={{ fontSize: 11, fontWeight: 600, marginTop: 1 }}
                            >
                              {isWeb ? (
                                <svg
                                  width="11"
                                  height="11"
                                  viewBox="0 0 24 24"
                                  fill="none"
                                  stroke="currentColor"
                                  strokeWidth="2"
                                  aria-label="Web source"
                                >
                                  <circle cx="12" cy="12" r="10" />
                                  <path d="M2 12h20" />
                                  <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
                                </svg>
                              ) : null}
                              [{idx + 1}]
                            </span>
                            <div className="min-w-0 flex-1">
                              <div
                                className="text-text-primary truncate"
                                style={{ fontSize: 12, fontWeight: 500 }}
                              >
                                {s.title}
                              </div>
                              <div
                                className="text-text-muted truncate"
                                style={{ fontSize: 11 }}
                              >
                                {s.feed_title}
                                {s.published_at && (
                                  <>
                                    {" · "}
                                    {new Date(s.published_at * 1000).toLocaleDateString()}
                                  </>
                                )}
                              </div>
                            </div>
                          </div>
                        </button>
                      );
                    })}
                  </div>
                </div>
              )}
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
        <div className="border-t border-white/5 min-w-0" style={{ padding: "12px 16px 8px" }}>
          <div className="flex items-center gap-2 min-w-0">
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
              placeholder="Ask about your articles…"
              rows={2}
              className="flex-1 min-w-0 border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors resize-none"
              style={{ background: "rgba(255, 255, 255, 0.05)", padding: "10px 12px", fontSize: 13, width: 0 }}
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
          <div style={{ marginTop: 8 }}>
            <AIDisclaimer />
          </div>
        </div>
      </div>
    </div>,
    document.body
  );
}
