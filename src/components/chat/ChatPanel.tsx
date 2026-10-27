import { useState, useRef, useEffect, useCallback } from "react";
import { chatWithArticle, webSearch } from "../../services/commands";
import type { SearchResult, WebCitation } from "../../services/types";
import { useUiStore } from "../../stores/uiStore";
import { AIDisclaimer } from "../common/AIDisclaimer";
import { AiSetupNotice, isAiSetupError } from "../common/AiSetupNotice";
import { useSettings } from "../../hooks/useSettings";
import { ModelPicker } from "../common/ModelPicker";
import { SettingsCog } from "../common/SettingsCog";
import { AiErrorText } from "../common/AiSettingsButton";
import { ChatMessageContent, ReplyPreview, chatPrompt, type ChatReply } from "./ChatMessageContent";
import { SourceTile, siteName } from "./AgentAnswer";
import { QueuedMessages, useMessageQueue } from "./QueuedMessages";
import { citationOrder } from "../../lib/chatCitations";
import { applyChatCorrections } from "../../lib/chatCorrections";
import type { ChatSource } from "../../services/commands";
import { openUrl } from "@tauri-apps/plugin-opener";

interface ChatMessage {
  role: "user" | "assistant" | "search";
  content: string;
  reply?: ChatReply;
  searchResults?: SearchResult[];
  /** Web citations produced by the tool-use loop on assistant turns. */
  webCitations?: WebCitation[];
}

interface Props {
  articleId: string;
  articleTitle: string;
  summaryContext?: string;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  /** A passage highlighted in the article; each new `id` quotes it in the composer. */
  /** A passage highlighted in the article `articleId` names; ignored for any other article. */
  askAbout?: { id: number; text: string; articleId: string } | null;
}

/** Append an answer, applying any in-place corrections it makes to earlier replies. */
function withAnswer(prev: ChatMessage[], content: string, webCitations?: WebCitation[]): ChatMessage[] {
  const { messages, answer } = applyChatCorrections(prev, content);
  return [...messages, { role: "assistant", content: answer, webCitations }];
}

const COLLAPSED_HEIGHT = 44;
const PHONE_COLLAPSED_HEIGHT = 52;
const DEFAULT_HEIGHT = 280;
const MIN_HEIGHT = 140;

export function ChatDrawer({ articleId, summaryContext, open: controlledOpen, onOpenChange, askAbout }: Props) {
  const isPhone = useUiStore((s) => s.isPhone);
  const { data: settings } = useSettings();
  const chatProvider = settings?.ai.chat_provider;
  const provider = chatProvider && chatProvider !== "same" ? chatProvider : settings?.ai.provider;
  const needsSetup = provider === "none";
  const [localOpen, setLocalOpen] = useState(false);
  // The web source under the pointer in one answer, so its chips and card light up together.
  const [hovered, setHovered] = useState<{ index: number; id: string } | null>(null);
  const open = controlledOpen ?? localOpen;
  const setOpen = (value: boolean) => {
    setLocalOpen(value);
    onOpenChange?.(value);
  };
  // Phone: cap to half of viewport so article remains visible above. Desktop: keep 280px.
  const [height, setHeight] = useState(() =>
    isPhone ? Math.min(DEFAULT_HEIGHT, Math.round(window.innerHeight * 0.5)) : DEFAULT_HEIGHT
  );
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [reply, setReply] = useState<ChatReply | null>(null);
  const [loading, setLoading] = useState(false);
  const [searchLoading, setSearchLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // The conversation the reader just cleared, kept until they send again so Undo can bring it back.
  const [cleared, setCleared] = useState<ChatMessage[] | null>(null);
  const requestSeqRef = useRef(0);
  const messagesRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const dragging = useRef(false);
  const dragStartY = useRef(0);
  const dragStartH = useRef(0);

  const busy = loading || searchLoading;
  // Questions asked mid-answer wait here and go out in order; an error holds them.
  const submitRef = useRef<(text: string, reply: ChatReply | null) => void>(() => {});
  const queue = useMessageQueue({ busy, paused: needsSetup || !!error, onSend: (item) => submitRef.current(item.text, item.reply) });

  // Reset on article change
  useEffect(() => {
    requestSeqRef.current += 1;
    queue.clear();
    setMessages([]);
    setInput("");
    setReply(null);
    setLoading(false);
    setSearchLoading(false);
    setError(null);
    setCleared(null);
  }, [articleId]);

  const clearConversation = () => {
    setCleared(messages);
    setMessages([]);
    setReply(null);
    queue.clear();
  };

  // Quote a passage the reader highlighted, ready for a question about it.
  useEffect(() => {
    // The drawer can remount on the next article with the last request
    // still set; a passage from another article must not follow the reader.
    if (!askAbout || askAbout.articleId !== articleId) return;
    setReply({ role: "article", text: askAbout.text });
    inputRef.current?.focus({ preventScroll: true });
  }, [askAbout?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  // A setup error is stale once AI settings change: drop the card so the
  // input is reachable again and the next send uses the new settings.
  useEffect(() => {
    setError((previous) => isAiSetupError(previous) ? null : previous);
  }, [settings]);

  // Auto-scroll
  useEffect(() => {
    const pane = messagesRef.current;
    if (pane) pane.scrollTop = pane.scrollHeight;
  }, [messages, loading, searchLoading, open, queue.queue.length]);

  // Focus input when opened
  useEffect(() => {
    if (open) inputRef.current?.focus({ preventScroll: true });
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

  // A failed question returns to the composer, or to the front of the queue
  // when the reader has started typing the next one.
  const restoreFailed = (text: string, failedReply: ChatReply | null) => {
    if (inputRef.current?.value.trim()) {
      queue.enqueue(text, failedReply, { first: true });
    } else {
      setInput(text);
      setReply(failedReply);
    }
  };

  const sendMessage = useCallback(async (text: string, reply: ChatReply | null) => {
    if (!text || loading || searchLoading || needsSetup) return;

    const requestSeq = ++requestSeqRef.current;
    setError(null);
    setCleared(null);
    const userMsg: ChatMessage = { role: "user", content: text, reply: reply ?? undefined };
    const newMessages = [...messages, userMsg];
    setMessages(newMessages);
    setInput("");
    setReply(null);
    setLoading(true);

    try {
      const history = newMessages
        .filter((m) => m.role === "user" || m.role === "assistant")
        .map((m) => ({ role: m.role as "user" | "assistant", content: chatPrompt(m.content, "reply" in m ? m.reply : undefined) }));

      const response = await chatWithArticle(articleId, history, summaryContext);
      if (requestSeqRef.current !== requestSeq) return;
      setMessages((prev) => withAnswer(prev, response.content, response.web_citations));
    } catch (e) {
      if (requestSeqRef.current !== requestSeq) return;
      setMessages((prev) => prev.slice(0, -1));
      restoreFailed(text, reply);
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      if (requestSeqRef.current === requestSeq) setLoading(false);
    }
  }, [messages, loading, searchLoading, needsSetup, articleId, summaryContext]);

  const doSearch = useCallback(async (query: string) => {
    if (needsSetup || loading || searchLoading) return;
    const requestSeq = ++requestSeqRef.current;
    setError(null);
    setCleared(null);
    setSearchLoading(true);
    try {
      const results = await webSearch(query);
      if (requestSeqRef.current !== requestSeq) return;
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
        .map((m) => ({ role: m.role as "user" | "assistant", content: chatPrompt(m.content, "reply" in m ? m.reply : undefined) }));

      setLoading(true);
      const response = await chatWithArticle(articleId, history, summaryContext);
      if (requestSeqRef.current !== requestSeq) return;
      setMessages((prev) => withAnswer(prev, response.content, response.web_citations));
    } catch (e) {
      if (requestSeqRef.current !== requestSeq) return;
      restoreFailed(`/search ${query}`, null);
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      if (requestSeqRef.current === requestSeq) {
        setSearchLoading(false);
        setLoading(false);
      }
    }
  }, [messages, articleId, loading, needsSetup, searchLoading, summaryContext]);

  const submit = (text: string, reply: ChatReply | null) => {
    if (!reply && text.startsWith("/search ")) {
      const query = text.slice(8).trim();
      if (query) doSearch(query);
    } else {
      sendMessage(text, reply);
    }
  };
  submitRef.current = submit;


  const handleSubmit = () => {
    const text = input.trim();
    if (!text || needsSetup) return;
    if (busy) {
      queue.enqueue(text, reply);
      setInput("");
      setReply(null);
      return;
    }
    if (!reply && text.startsWith("/search ")) setInput("");
    submit(text, reply);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSubmit();
    }
  };

  // Collapsed: just a thin bar with a chat button
  if (!open) {
    return (
      <button
        type="button"
        aria-label="Chat with article"
        aria-expanded={false}
        className="w-full flex-shrink-0 border-t border-white/10 flex items-center justify-center cursor-pointer hover:bg-white/5 transition-colors select-none"
        style={{ height: isPhone ? PHONE_COLLAPSED_HEIGHT : COLLAPSED_HEIGHT }}
        onClick={() => setOpen(true)}
      >
        <div className="flex items-center gap-2 text-text-muted" style={{ fontSize: isPhone ? 13 : 11, minHeight: isPhone ? 52 : undefined }}>
          <svg width={isPhone ? 16 : 12} height={isPhone ? 16 : 12} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
          </svg>
          Chat
          {messages.length > 0 && (
            <span className="text-accent" style={{ fontSize: 10 }}>({messages.filter(m => m.role !== "search").length})</span>
          )}
        </div>
      </button>
    );
  }

  return (
    <div
      role="region"
      aria-label="Article chat"
      className="flex-shrink-0 flex flex-col border-t border-white/10 min-w-0 overflow-hidden"
      style={{
        height,
        // Bound to the actual reader pane, including after window resizing.
        maxHeight: isPhone ? "50%" : "60%",
      }}
    >
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

      {/* Header: the whole row collapses the chat. The cog sits over the row, and Clear
          lives inside it, so a quick click near the chevron never wipes the conversation. */}
      <div className="flex-shrink-0 relative" style={{ padding: isPhone ? "0 4px 4px" : "0 8px 2px" }}>
        <button
          type="button"
          onClick={() => setOpen(false)}
          className="group w-full flex items-center gap-2 text-left rounded-lg hover:bg-white/5 transition-colors"
          style={{ paddingLeft: 8, minHeight: isPhone ? 48 : 32 }}
          aria-label="Collapse chat"
          aria-expanded={true}
          title="Collapse chat"
        >
          <span className="text-text-muted uppercase tracking-wider font-semibold" style={{ fontSize: 10 }}>Chat</span>
          <span className="text-text-muted flex-1" style={{ fontSize: 10 }}>ephemeral</span>
          <span
            className="flex items-center justify-center text-text-muted group-hover:text-text-primary transition-colors"
            style={{ width: isPhone ? 44 : 32, height: isPhone ? 44 : 32 }}
          >
            <svg width={isPhone ? 18 : 16} height={isPhone ? 18 : 16} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M6 9l6 6 6-6" />
            </svg>
          </span>
        </button>
        <div className="absolute top-0 flex items-center" style={{ right: isPhone ? 52 : 44, height: isPhone ? 48 : 32 }}>
          <SettingsCog label="Chat settings" heading="Chat" size={isPhone ? 16 : 14}>
            {(close) => (
              <>
                <div className="today-settings-row">
                  <span>Model</span>
                  <ModelPicker surface="chat" compact disabled={loading || searchLoading} />
                </div>
                <hr />
                <button className="today-settings-row" onClick={() => { close(); useUiStore.getState().setShowSettings(true, "ai"); }}>AI settings…</button>
                {messages.length > 0 && (
                  <>
                    <hr />
                    <button
                      className="today-settings-row text-danger disabled:opacity-50"
                      disabled={loading || searchLoading}
                      onClick={() => { close(); clearConversation(); }}
                    >
                      Clear conversation
                    </button>
                  </>
                )}
              </>
            )}
          </SettingsCog>
        </div>
      </div>

      {messages.length === 0 && cleared && cleared.length > 0 && (
        <div role="status" className="flex-shrink-0 flex items-center justify-center gap-2 text-text-muted" style={{ paddingTop: 4, fontSize: isPhone ? 12 : 11 }}>
          Conversation cleared.
          <button
            type="button"
            onClick={() => { setMessages(cleared); setCleared(null); }}
            className="text-accent hover:underline"
            style={{ padding: isPhone ? "8px 4px" : "2px 4px" }}
          >
            Undo
          </button>
        </div>
      )}

      {/* Messages */}
      <div ref={messagesRef} className="flex-1 overflow-y-auto overflow-x-hidden min-h-0 min-w-0" style={{ padding: "4px 16px" }}>
        {messages.length === 0 && (
          <div className="flex flex-wrap items-center gap-2 justify-center" style={{ paddingTop: 8 }}>
            {[
              "What are the key arguments?",
              "Who is mentioned?",
              "Broader context?",
            ].map((q) => (
              <button
                key={q}
                onClick={() => { setInput(q); inputRef.current?.focus(); }}
                className="text-text-muted border border-white/10 hover:border-white/20 hover:text-text-secondary rounded-md transition-colors"
                style={{ padding: isPhone ? "8px 10px" : "3px 8px", fontSize: isPhone ? 12 : 10, minHeight: isPhone ? 40 : undefined }}
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
                  {msg.reply && <ReplyPreview reply={msg.reply} />}
                  <ChatMessageContent content={msg.content} role="user" onReply={(quote) => { setReply(quote); inputRef.current?.focus({ preventScroll: true }); }} replyDisabled={false} />
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
                  <ChatMessageContent
                    content={msg.content}
                    role="assistant"
                    onReply={(quote) => { setReply(quote); inputRef.current?.focus({ preventScroll: true }); }}
                    replyDisabled={false}
                    citations={msg.webCitations?.length ? {
                      sources: webSources(msg.webCitations),
                      onOpenArticle: (id) => openWebSource(msg.webCitations!, id),
                      onHoverSource: (id) => setHovered(id ? { index: i, id } : null),
                      highlightId: hovered?.index === i ? hovered.id : null,
                    } : undefined}
                  />
                </div>
                {msg.webCitations && msg.webCitations.length > 0 && (
                  <WebSources
                    citations={msg.webCitations}
                    content={msg.content}
                    highlightId={hovered?.index === i ? hovered.id : null}
                    onHover={(id) => setHovered(id ? { index: i, id } : null)}
                  />
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
              <svg className="smooth-spin" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M21 12a9 9 0 1 1-6.219-8.56" />
              </svg>
              {searchLoading ? "Searching..." : "Thinking..."}
            </div>
          </div>
        )}

        <QueuedMessages queue={queue} paused={!!error && !busy && !needsSetup} onResume={() => setError(null)} />
      </div>

      {/* Input */}
      <div className="flex-shrink-0 min-w-0" style={{ padding: "6px 16px 8px" }}>
        {(needsSetup || isAiSetupError(error)) && <AiSetupNotice error={error} />}
        {error && !isAiSetupError(error) && <AiErrorText error={error} style={{ marginBottom: 6 }} />}
        {reply && <ReplyPreview reply={reply} onRemove={() => setReply(null)} />}
        <div className="flex items-end gap-2 min-w-0">
          <textarea
            ref={inputRef}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder={busy ? "Queue a follow-up..." : "Ask about this article..."}
            className="flex-1 min-w-0 border border-white/10 rounded-lg text-text-primary bg-white/5 placeholder-text-muted resize-none focus:outline-none focus:border-accent/40"
            style={{ padding: isPhone ? "10px 12px" : "6px 10px", fontSize: isPhone ? 16 : 12, maxHeight: 80, lineHeight: 1.4, width: 0, minHeight: isPhone ? 44 : undefined }}
            rows={1}
            disabled={needsSetup}
          />
          <button
            onClick={handleSubmit}
            disabled={needsSetup || !input.trim()}
            className="tap-target text-accent hover:bg-accent/10 disabled:opacity-30 rounded-lg transition-colors flex-shrink-0"
            style={{ padding: isPhone ? 0 : "6px 10px" }}
            aria-label={busy ? "Queue message" : "Send message"}
            title={busy ? "Queue: sends when Skim finishes" : "Send"}
          >
            <svg width={isPhone ? 18 : 14} height={isPhone ? 18 : 14} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M22 2L11 13M22 2l-7 20-4-9-9-4 20-7z" />
            </svg>
          </button>
        </div>
        <div style={{ marginTop: 6 }}>
          <AIDisclaimer />
        </div>
      </div>
    </div>
  );
}

/** Web results as chat sources, so [wN] in the answer can become chips. */
function webSources(citations: WebCitation[]): ChatSource[] {
  return citations.map((c, index) => ({
    id: `web-${index}`,
    title: c.title,
    feed_title: siteName(c.url),
    url: c.url,
    published_at: null,
    source_type: "web",
  }));
}

function openWebSource(citations: WebCitation[], id: string) {
  const url = citations[Number(id.replace("web-", ""))]?.url;
  if (url) void openUrl(url).catch(() => {});
}

/**
 * The web results an answer drew on, as cards numbered like its [wN] chips.
 * Results the answer never cited stay behind a disclosure.
 */
function WebSources({ citations, content, highlightId, onHover }: {
  citations: WebCitation[];
  content: string;
  highlightId: string | null;
  onHover: (id: string | null) => void;
}) {
  const sources = webSources(citations);
  const cited = citationOrder(sources, content);
  const rest = sources.filter((source) => !cited.some((c) => c.source === source));
  const snippet = (id: string) => citations[Number(id.replace("web-", ""))]?.snippet || undefined;
  const tiles = (items: { source: ChatSource; label: number | null }[]) => (
    <div className="source-tiles" onMouseLeave={() => onHover(null)}>
      {items.map(({ source, label }) => (
        <SourceTile
          key={source.id}
          source={source}
          label={label ?? undefined}
          snippet={snippet(source.id)}
          active={highlightId === source.id}
          onHover={() => onHover(source.id)}
          onOpen={() => openWebSource(citations, source.id)}
        />
      ))}
    </div>
  );
  return (
    <div style={{ width: "100%", marginTop: 2 }}>
      {cited.length > 0 && (
        <>
          <div className="text-text-muted uppercase tracking-wider" style={{ fontSize: 10, fontWeight: 600, margin: "4px 0 6px" }}>
            Web sources
          </div>
          {tiles(cited)}
        </>
      )}
      {rest.length > 0 && (
        <details style={{ marginTop: 6 }}>
          <summary className="text-text-muted cursor-pointer rounded-lg hover:bg-white/5" style={{ padding: "6px 4px", fontSize: 11 }}>
            Also found on the web ({rest.length})
          </summary>
          {tiles(rest.map((source) => ({ source, label: null })))}
        </details>
      )}
    </div>
  );
}
