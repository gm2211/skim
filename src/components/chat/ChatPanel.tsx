import { useState, useRef, useEffect, useCallback } from "react";
import { chatWithArticle, webSearch } from "../../services/commands";
import type { SearchResult, WebCitation } from "../../services/types";

interface ChatMessage {
  role: "user" | "assistant" | "search";
  content: string;
  searchResults?: SearchResult[];
  /** Web citations produced by the tool-use loop on assistant turns. */
  webCitations?: WebCitation[];
}

interface Props {
  articleId: string;
  articleTitle: string;
}

const COLLAPSED_HEIGHT = 36;
const DEFAULT_HEIGHT = 280;
const MIN_HEIGHT = 140;

export function ChatDrawer({ articleId }: Props) {
  const [open, setOpen] = useState(false);
  const [height, setHeight] = useState(DEFAULT_HEIGHT);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [loading, setLoading] = useState(false);
  const [searchLoading, setSearchLoading] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const dragging = useRef(false);
  const dragStartY = useRef(0);
  const dragStartH = useRef(0);

  // Reset on article change
  useEffect(() => {
    setMessages([]);
    setInput("");
    setLoading(false);
    setSearchLoading(false);
  }, [articleId]);

  // Auto-scroll
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, loading]);

  // Focus input when opened
  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open]);

  // Drag to resize
  useEffect(() => {
    const onMove = (e: MouseEvent) => {
      if (!dragging.current) return;
      const delta = dragStartY.current - e.clientY;
      setHeight(Math.max(MIN_HEIGHT, dragStartH.current + delta));
    };
    const onUp = () => { dragging.current = false; };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    return () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    };
  }, []);

  const sendMessage = useCallback(async () => {
    const text = input.trim();
    if (!text || loading) return;

    const userMsg: ChatMessage = { role: "user", content: text };
    const newMessages = [...messages, userMsg];
    setMessages(newMessages);
    setInput("");
    setLoading(true);

    try {
      const history = newMessages
        .filter((m) => m.role === "user" || m.role === "assistant")
        .map((m) => ({ role: m.role as "user" | "assistant", content: m.content }));

      const response = await chatWithArticle(articleId, history);
      setMessages((prev) => [
        ...prev,
        {
          role: "assistant",
          content: response.content,
          webCitations: response.web_citations,
        },
      ]);
    } catch (e) {
      setMessages((prev) => [
        ...prev,
        { role: "assistant", content: `Error: ${e instanceof Error ? e.message : String(e)}` },
      ]);
    } finally {
      setLoading(false);
    }
  }, [input, messages, loading, articleId]);

  const doSearch = useCallback(async (query: string) => {
    setSearchLoading(true);
    try {
      const results = await webSearch(query);
      const searchMsg: ChatMessage = {
        role: "search",
        content: query,
        searchResults: results,
      };
      setMessages((prev) => [...prev, searchMsg]);

      const contextContent = results.length > 0
        ? `I searched for "${query}" and found these results:\n\n${results
            .map((r, i) => `${i + 1}. **${r.title}**\n   ${r.url}\n   ${r.snippet}`)
            .join("\n\n")}\n\nPlease summarize the relevant findings.`
        : `I searched for "${query}" but found no results.`;

      const allMessages = [...messages, { role: "user" as const, content: contextContent }];
      const history = allMessages
        .filter((m) => m.role === "user" || m.role === "assistant")
        .map((m) => ({ role: m.role as "user" | "assistant", content: m.content }));

      setLoading(true);
      const response = await chatWithArticle(articleId, history);
      setMessages((prev) => [
        ...prev,
        {
          role: "assistant",
          content: response.content,
          webCitations: response.web_citations,
        },
      ]);
    } catch (e) {
      setMessages((prev) => [
        ...prev,
        { role: "assistant", content: `Search failed: ${e instanceof Error ? e.message : String(e)}` },
      ]);
    } finally {
      setSearchLoading(false);
      setLoading(false);
    }
  }, [messages, articleId]);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      const text = input.trim();
      if (text.startsWith("/search ")) {
        const query = text.slice(8).trim();
        if (query) { setInput(""); doSearch(query); }
      } else {
        sendMessage();
      }
    }
  };

  const handleSubmit = () => {
    const text = input.trim();
    if (text.startsWith("/search ")) {
      const query = text.slice(8).trim();
      if (query) { setInput(""); doSearch(query); }
    } else {
      sendMessage();
    }
  };

  // Collapsed: just a thin bar with a chat button
  if (!open) {
    return (
      <div
        className="flex-shrink-0 border-t border-white/10 flex items-center justify-center cursor-pointer hover:bg-white/5 transition-colors select-none"
        style={{ height: COLLAPSED_HEIGHT }}
        onClick={() => setOpen(true)}
      >
        <div className="flex items-center gap-2 text-text-muted" style={{ fontSize: 11 }}>
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
          </svg>
          Chat
          {messages.length > 0 && (
            <span className="text-accent" style={{ fontSize: 10 }}>({messages.filter(m => m.role !== "search").length})</span>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="flex-shrink-0 flex flex-col border-t border-white/10" style={{ height }}>
      {/* Resize handle */}
      <div
        className="flex-shrink-0 cursor-ns-resize flex items-center justify-center hover:bg-white/5 transition-colors"
        style={{ height: 8 }}
        onMouseDown={(e) => {
          dragging.current = true;
          dragStartY.current = e.clientY;
          dragStartH.current = height;
          e.preventDefault();
        }}
      >
        <div className="rounded-full" style={{ width: 32, height: 3, background: "rgba(255,255,255,0.15)" }} />
      </div>

      {/* Header */}
      <div
        className="flex-shrink-0 flex items-center justify-between"
        style={{ padding: "4px 16px 6px" }}
      >
        <div className="flex items-center gap-2">
          <span className="text-text-muted uppercase tracking-wider font-semibold" style={{ fontSize: 10 }}>Chat</span>
          <span className="text-text-muted" style={{ fontSize: 10 }}>ephemeral</span>
        </div>
        <div className="flex items-center gap-2">
          {messages.length > 0 && (
            <button
              onClick={() => setMessages([])}
              className="text-text-muted hover:text-text-primary transition-colors"
              style={{ fontSize: 10 }}
            >
              Clear
            </button>
          )}
          <button
            onClick={() => setOpen(false)}
            className="text-text-muted hover:text-text-primary transition-colors"
            style={{ padding: 2, lineHeight: 0 }}
          >
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M6 9l6 6 6-6" />
            </svg>
          </button>
        </div>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto min-h-0" style={{ padding: "4px 16px" }}>
        {messages.length === 0 && (
          <div className="flex items-center gap-3 justify-center" style={{ paddingTop: 8 }}>
            {[
              "What are the key arguments?",
              "Who is mentioned?",
              "Broader context?",
            ].map((q) => (
              <button
                key={q}
                onClick={() => { setInput(q); inputRef.current?.focus(); }}
                className="text-text-muted border border-white/10 hover:border-white/20 hover:text-text-secondary rounded-md transition-colors"
                style={{ padding: "3px 8px", fontSize: 10 }}
              >
                {q}
              </button>
            ))}
          </div>
        )}

        {messages.map((msg, i) => (
          <div key={i} style={{ marginBottom: 8 }}>
            {msg.role === "user" && (
              <div className="flex justify-end">
                <div
                  className="rounded-xl rounded-br-sm text-text-primary"
                  style={{
                    padding: "6px 10px",
                    fontSize: 12,
                    maxWidth: "85%",
                    background: "rgba(88, 166, 255, 0.15)",
                    lineHeight: 1.4,
                  }}
                >
                  {msg.content}
                </div>
              </div>
            )}
            {msg.role === "assistant" && (
              <div className="flex flex-col items-start gap-1">
                <div
                  className="rounded-xl rounded-bl-sm text-text-primary"
                  style={{
                    padding: "6px 10px",
                    fontSize: 12,
                    maxWidth: "85%",
                    background: "rgba(255, 255, 255, 0.05)",
                    lineHeight: 1.4,
                  }}
                >
                  <div
                    dangerouslySetInnerHTML={{
                      __html: msg.content
                        .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
                        .replace(/\*(.+?)\*/g, "<em>$1</em>")
                        .replace(/\n\n/g, "</p><p style='margin-top:6px'>")
                        .replace(/\n/g, "<br>")
                        .replace(/^/, "<p>")
                        .replace(/$/, "</p>"),
                    }}
                  />
                </div>
                {msg.webCitations && msg.webCitations.length > 0 && (
                  <div
                    className="rounded-md border border-white/10"
                    style={{
                      padding: "4px 8px",
                      background: "rgba(255,255,255,0.02)",
                      maxWidth: "85%",
                    }}
                  >
                    <div
                      className="text-text-muted uppercase tracking-wider flex items-center gap-1"
                      style={{ fontSize: 9, fontWeight: 600, marginBottom: 3 }}
                    >
                      <svg
                        width="9"
                        height="9"
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
                      Web sources
                    </div>
                    {msg.webCitations.map((c, j) => (
                      <div
                        key={c.url}
                        style={{
                          marginBottom:
                            j < msg.webCitations!.length - 1 ? 4 : 0,
                        }}
                      >
                        <a
                          href={c.url}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="text-accent hover:underline"
                          style={{ fontSize: 11 }}
                        >
                          {c.title}
                        </a>
                        <p className="text-text-muted" style={{ fontSize: 10 }}>
                          {c.snippet}
                        </p>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}
            {msg.role === "search" && (
              <div style={{ margin: "4px 0" }}>
                <div className="text-text-muted flex items-center gap-1" style={{ fontSize: 10, marginBottom: 3 }}>
                  <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <circle cx="11" cy="11" r="8" />
                    <path d="M21 21l-4.35-4.35" />
                  </svg>
                  Searched: "{msg.content}"
                </div>
                {msg.searchResults && msg.searchResults.length > 0 && (
                  <div className="rounded-md border border-white/10" style={{ padding: "4px 8px", background: "rgba(255,255,255,0.02)" }}>
                    {msg.searchResults.map((r, j) => (
                      <div key={j} style={{ marginBottom: j < msg.searchResults!.length - 1 ? 4 : 0 }}>
                        <a href={r.url} target="_blank" rel="noopener noreferrer" className="text-accent hover:underline" style={{ fontSize: 11 }}>
                          {r.title}
                        </a>
                        <p className="text-text-muted" style={{ fontSize: 10 }}>{r.snippet}</p>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}
          </div>
        ))}

        {(loading || searchLoading) && (
          <div className="flex justify-start" style={{ marginBottom: 8 }}>
            <div
              className="rounded-xl rounded-bl-sm text-text-muted flex items-center gap-2"
              style={{ padding: "6px 10px", fontSize: 12, background: "rgba(255, 255, 255, 0.05)" }}
            >
              <svg className="animate-spin" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M21 12a9 9 0 1 1-6.219-8.56" />
              </svg>
              {searchLoading ? "Searching..." : "Thinking..."}
            </div>
          </div>
        )}

        <div ref={messagesEndRef} />
      </div>

      {/* Input */}
      <div className="flex-shrink-0" style={{ padding: "6px 16px 10px" }}>
        <div className="flex items-end gap-2">
          <textarea
            ref={inputRef}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Ask about this article... (/search to web search)"
            className="flex-1 border border-white/10 rounded-lg text-text-primary bg-white/5 placeholder-text-muted resize-none focus:outline-none focus:border-accent/40"
            style={{ padding: "6px 10px", fontSize: 12, maxHeight: 80, lineHeight: 1.4 }}
            rows={1}
            disabled={loading}
          />
          <button
            onClick={handleSubmit}
            disabled={loading || !input.trim()}
            className="text-accent hover:bg-accent/10 disabled:opacity-30 rounded-lg transition-colors flex-shrink-0"
            style={{ padding: "6px 10px" }}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M22 2L11 13M22 2l-7 20-4-9-9-4 20-7z" />
            </svg>
          </button>
        </div>
      </div>
    </div>
  );
}
