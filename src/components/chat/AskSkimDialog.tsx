import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { askAgent, chatWithArticles, type AgentContext, type AgentStep, type ChatSource } from "../../services/commands";
import { useAgentChatStore } from "../../stores/agentChatStore";
import { agentAskHeading, agentContextLabel, agentExamples } from "../../lib/agentContext";
import { CHAT_STARTER_PROMPTS, isPromptTemplate } from "../../lib/chatStarterPrompts";
import { AgentSteps } from "./AgentAnswer";
import { partitionSources, type NumberedSource } from "../../lib/chatCitations";
import type { ChatMessageInput } from "../../services/types";
import { openUrl } from "@tauri-apps/plugin-opener";
import { useUiStore } from "../../stores/uiStore";
import { AIDisclaimer } from "../common/AIDisclaimer";
import { useLockBodyScroll } from "../../hooks/useLockBodyScroll";
import { useVisualViewportSync } from "../../hooks/useVisualViewport";
import { useSwipeToDismiss } from "../../hooks/useSwipeToDismiss";
import { useSettings } from "../../hooks/useSettings";
import { useDialogFocus } from "../../hooks/useDialogFocus";
import { AiSetupNotice, isAiSetupError } from "../common/AiSetupNotice";
import { ModelPicker } from "../common/ModelPicker";
import { SettingsCog } from "../common/SettingsCog";
import { Select } from "../ui/Select";
import { ChatMessageContent, ReplyPreview, chatPrompt, type ChatReply } from "./ChatMessageContent";

type Scope = "inbox" | "unread" | "all";

interface Message {
  role: "user" | "assistant";
  content: string;
  reply?: ChatReply;
  sources?: ChatSource[];
  articleIds?: string[];
  steps?: AgentStep[];
}

interface Props {
  open?: boolean;
  restoreFocusTarget?: () => HTMLElement | null;
  onClose: () => void;
  onOpenArticle?: (articleId: string) => void;
}

export function AskSkimDialog({ open = true, restoreFocusTarget, onClose, onOpenArticle }: Props) {
  const isPhone = useUiStore((s) => s.isPhone);
  const showSettings = useUiStore((s) => s.showSettings);
  const { data: settings } = useSettings();
  const chatProvider = settings?.ai.chat_provider;
  const provider = chatProvider && chatProvider !== "same" ? chatProvider : settings?.ai.provider;
  const needsSetup = provider === "none";
  useLockBodyScroll(open && isPhone && !showSettings);
  const dialogRef = useRef<HTMLDivElement>(null);
  const restoreOpener = useRef(true);
  const focusAfterSend = useRef(false);
  useVisualViewportSync(dialogRef, open && isPhone && !showSettings);
  useDialogFocus(dialogRef, onClose, open && !showSettings, () => restoreOpener.current, restoreFocusTarget);
  const { swipeToDismissHandlers, swipeToDismissStyle } = useSwipeToDismiss(open && isPhone, onClose);
  const [scope, setScope] = useState<Scope>("unread");
  const [input, setInput] = useState("");
  const [reply, setReply] = useState<ChatReply | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [loading, setLoading] = useState(false);
  const [completedSends, setCompletedSends] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  // Set when the chat continues an agent conversation (from the command
  // palette, or "Ask about this page / story"): answers then come from the
  // app agent with this context instead of the scoped article search.
  const [agentContext, setAgentContext] = useState<AgentContext | null>(null);
  const [contextArticleTitle, setContextArticleTitle] = useState<string | null>(null);
  const seed = useAgentChatStore((s) => s.seed);
  const pendingSend = useRef<string | null>(null);
  const onSeedSend = useRef<(() => void) | null>(null);

  useEffect(() => {
    if (!open || !seed) return;
    useAgentChatStore.getState().setSeed(null);
    setAgentContext(seed.context);
    onSeedSend.current = seed.onSend ?? null;
    setContextArticleTitle(seed.articleTitle ?? null);
    setMessages(seed.messages ?? []);
    setReply(null);
    setError(null);
    if (seed.autoSend && seed.prompt?.trim()) {
      setInput("");
      pendingSend.current = seed.prompt.trim();
    } else {
      setInput(seed.prompt ?? "");
    }
  }, [open, seed]);

  useEffect(() => { if (open) restoreOpener.current = true; }, [open]);

  useEffect(() => {
    if (!loading && open && !showSettings && focusAfterSend.current) {
      focusAfterSend.current = false;
      inputRef.current?.focus({ preventScroll: true });
    }
  }, [loading, completedSends, open, showSettings]);

  useEffect(() => {
    if (!open || isPhone || needsSetup || showSettings) return;
    inputRef.current?.focus();
  }, [open, isPhone, needsSetup, showSettings]);

  useEffect(() => {
    setError((previous) => isAiSetupError(previous) ? null : previous);
  }, [settings]);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages, loading]);

  const send = async (text?: string) => {
    const query = (text ?? input).trim();
    if (!query || loading || needsSetup) return;
    setError(null);

    const userMsg: Message = { role: "user", content: query, reply: reply ?? undefined };
    const next = [...messages, userMsg];
    setMessages(next);
    setInput("");
    setReply(null);
    focusAfterSend.current = true;
    setLoading(true);

    const history: ChatMessageInput[] = messages.map((m) => ({ role: m.role, content: chatPrompt(m.content, m.reply) }));
    const priorIds = [...messages].reverse().find((message) => message.role === "assistant")?.articleIds;

    try {
      if (agentContext) {
        onSeedSend.current?.();
        const resp = await askAgent([...history, { role: "user", content: chatPrompt(query, reply) }], agentContext, priorIds);
        setMessages((m) => [
          ...m,
          { role: "assistant", content: resp.content, sources: resp.sources, articleIds: resp.article_ids, steps: resp.steps },
        ]);
        const open = resp.actions.find((action) => action.type === "open_article");
        if (open && onOpenArticle) {
          restoreOpener.current = false;
          focusAfterSend.current = false;
          onOpenArticle(open.article_id);
          onClose();
        }
        return;
      }
      const resp = await chatWithArticles(scope, chatPrompt(query, reply), history, priorIds);
      setMessages((m) => [
        ...m,
        { role: "assistant", content: resp.content, sources: resp.sources, articleIds: resp.article_ids },
      ]);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
      setMessages((m) => m.slice(0, -1));
      setInput(query);
      setReply(reply);
    } finally {
      setLoading(false);
      setCompletedSends((count) => count + 1);
    }
  };

  useEffect(() => {
    const text = pendingSend.current;
    if (!text || !open || !agentContext) return;
    pendingSend.current = null;
    void send(text);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, agentContext, messages]);

  return !open || showSettings ? null : createPortal(
    <div
      className={`fixed inset-0 bg-black/60 backdrop-blur-sm z-50 dialog-fade-in ${isPhone ? "" : "flex items-center justify-center"}`}
      onClick={onClose}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="ask-skim-title"
        tabIndex={-1}
        className={`${isPhone ? "fixed left-0 right-0 overflow-hidden" : "border border-white/10 rounded-2xl shadow-2xl"} flex flex-col`}
        style={{
          background: "var(--color-bg-secondary)",
          width: isPhone ? undefined : "min(640px, 92vw)",
          height: isPhone ? "100dvh" : "min(600px, 85vh)",
          top: isPhone ? 0 : undefined,
          willChange: isPhone ? "transform, height" : undefined,
          ...swipeToDismissStyle,
          margin: isPhone ? 0 : "0 20px",
          paddingTop: isPhone ? "max(var(--sat, 0px), 8px)" : 0,
          paddingBottom: isPhone ? "max(var(--sab, 0px), 12px)" : 0,
        }}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div
          className="flex items-center gap-3 border-b border-border flex-wrap"
          style={{ padding: "12px 16px", touchAction: isPhone ? "pan-y" : undefined }}
          {...swipeToDismissHandlers}
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-accent flex-shrink-0">
            <circle cx="11" cy="11" r="8" />
            <path d="M21 21l-4.35-4.35" />
          </svg>
          <h3 id="ask-skim-title" className="text-text-primary flex-1" style={{ fontSize: isPhone ? 20 : 16, fontWeight: 600 }}>
            Ask Skim
          </h3>
          {agentContext ? (
            <span className="text-text-muted truncate" style={{ fontSize: 12, maxWidth: 220 }} title="What Skim can see">
              {agentContextLabel(agentContext, contextArticleTitle)}
            </span>
          ) : <Select
            aria-label="Articles to search"
            value={scope}
            onChange={(e) => setScope(e.target.value as Scope)}
            style={{ fontSize: isPhone ? 14 : 12 }}
          >
            <option value="inbox">Inbox</option>
            <option value="unread">Unread</option>
            <option value="all">All</option>
          </Select>}
          <SettingsCog label="Chat settings" heading="Ask Skim">
            {(close) => (
              <>
                <div className="today-settings-row">
                  <span>Model</span>
                  <ModelPicker surface="chat" compact disabled={loading} />
                </div>
                <hr />
                <button className="today-settings-row" onClick={() => { close(); useUiStore.getState().setShowSettings(true, "ai"); }}>AI settings…</button>
              </>
            )}
          </SettingsCog>
          <button
            onClick={onClose}
            className="tap-target text-text-muted hover:text-text-primary transition-colors flex-shrink-0 rounded-lg hover:bg-white/10"
            style={!isPhone ? { minWidth: "var(--skim-control-height, 44px)", minHeight: "var(--skim-control-height, 44px)", width: "var(--skim-control-height, 44px)", height: "var(--skim-control-height, 44px)" } : undefined}
            title="Close (Esc)"
            aria-label="Close"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Messages */}
        <div ref={scrollRef} className="flex-1 overflow-y-auto overflow-x-hidden min-w-0" style={{ padding: "18px" }}>
          {(needsSetup || isAiSetupError(error)) && <AiSetupNotice error={error} />}
          {messages.length === 0 && !loading && !needsSetup && !isAiSetupError(error) && (
            <div className="flex flex-col items-center text-center" style={{ padding: "48px 20px 32px" }}>
              <p className="text-text-primary" style={{ fontSize: 15, fontWeight: 600 }}>
                {agentContext
                  ? agentAskHeading(agentContext, contextArticleTitle)
                  : "Ask anything about articles in your feed."}
              </p>
              <p className="text-text-muted" style={{ fontSize: 12.5, marginTop: 4 }}>
                Answers cite the articles they come from. Try one of these:
              </p>
              <div className="flex flex-wrap justify-center" style={{ gap: 8, marginTop: 16, maxWidth: 520 }}>
                {(agentContext ? agentExamples(agentContext) : CHAT_STARTER_PROMPTS).map((prompt) => (
                  <button
                    key={prompt}
                    type="button"
                    onClick={() => {
                      if (!isPromptTemplate(prompt)) {
                        void send(prompt);
                        return;
                      }
                      setInput(prompt);
                      inputRef.current?.focus();
                    }}
                    className="ask-example text-text-secondary hover:text-text-primary"
                  >
                    {prompt}
                  </button>
                ))}
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
                    wordBreak: "break-word",
                  }}
                >
                  {m.reply && <ReplyPreview reply={m.reply} />}
                  {m.steps && <AgentSteps steps={m.steps} />}
                  <ChatMessageContent content={m.content} role={m.role} onReply={(quote) => { setReply(quote); inputRef.current?.focus({ preventScroll: true }); }} replyDisabled={loading} />
                </div>
              </div>
              {m.role === "assistant" && m.sources && m.sources.length > 0 && (
                <SourceGroups
                  sources={m.sources}
                  content={m.content}
                  onOpenArticle={onOpenArticle ? (id) => {
                    restoreOpener.current = false;
                    focusAfterSend.current = false;
                    onOpenArticle(id);
                  } : undefined}
                  onClose={onClose}
                />
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
                className="smooth-spin"
              >
                <path d="M21 12a9 9 0 11-6.219-8.56" />
              </svg>
              <span style={{ fontSize: 12 }}>Searching articles…</span>
            </div>
          )}

          {error && !isAiSetupError(error) && (
            <p role="alert" className="text-danger" style={{ fontSize: 14 }}>
              {error}
            </p>
          )}
        </div>

        {/* Input */}
        <div className="border-t border-white/5 min-w-0" style={{ padding: "12px 16px 8px" }}>
          {reply && <ReplyPreview reply={reply} onRemove={() => setReply(null)} />}
          <div className="flex items-center gap-2 min-w-0">
            <textarea
              ref={inputRef}
              aria-label="Question about your articles"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  send();
                }
              }}
              placeholder="Ask about your articles…"
              rows={2}
              className="flex-1 min-w-0 border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors resize-none"
              style={{ background: "rgba(255, 255, 255, 0.05)", padding: "10px 12px", fontSize: 13, width: 0 }}
            />
            <button
              onClick={() => void send()}
              disabled={loading || needsSetup || !input.trim()}
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

/**
 * The answer cites articles by bracket number, but every candidate the search
 * ranked was listed under "Sources" regardless — up to fifteen of them, most of
 * which the answer never used. The ones it cited come first under Sources; the
 * rest stay reachable in a collapsed disclosure so they cannot bury the answer.
 */
function SourceGroups({
  sources,
  content,
  onOpenArticle,
  onClose,
}: {
  sources: ChatSource[];
  content: string;
  onOpenArticle?: (id: string) => void;
  onClose: () => void;
}) {
  const { cited, searched } = partitionSources(sources, content);
  const renderSources = (items: NumberedSource[]) => (
    <div className="flex flex-col gap-1">
      {items.map(({ source: s, number }) => {
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
                {number === null ? "Web" : `[${number}]`}
              </span>
              <div className="min-w-0 flex-1">
                <div
                  className="text-text-primary truncate"
                  style={{ fontSize: 12, fontWeight: 500 }}
                >
                  {s.title}
                </div>
                <div className="text-text-muted truncate" style={{ fontSize: 11 }}>
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
  );

  return (
    <div style={{ marginTop: 8, paddingLeft: 4 }}>
      {cited.length > 0 && (
        <div style={{ marginBottom: 6 }}>
          <div
            className="text-text-muted uppercase tracking-wider"
            style={{ fontSize: 10, fontWeight: 600, marginBottom: 4 }}
          >
            Sources
          </div>
          {renderSources(cited)}
        </div>
      )}
      {searched.length > 0 && (
        <details>
          <summary
            className="text-text-muted cursor-pointer rounded-lg hover:bg-white/5 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/50"
            style={{ padding: "12px 10px", minHeight: 44, fontSize: 12 }}
          >
            {cited.length > 0 ? "Also searched" : "Searched"} ({searched.length})
          </summary>
          {renderSources(searched)}
        </details>
      )}
    </div>
  );
}
