import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { listen } from "@tauri-apps/api/event";
import { askAgent, chatWithArticles, researchTopic, RESEARCH_PROGRESS_EVENT, type AgentContext, type AgentStep, type ChatSource, type ResearchProgress } from "../../services/commands";
import { useAgentChatStore } from "../../stores/agentChatStore";
import { agentAskHeading, agentContextLabel, agentExamples } from "../../lib/agentContext";
import { CHAT_STARTER_PROMPTS, isPromptTemplate } from "../../lib/chatStarterPrompts";
import { AgentSteps, SourceTile } from "./AgentAnswer";
import { ResearchIcon } from "../ui/icons";
import { citationOrder, partitionSources, type NumberedSource } from "../../lib/chatCitations";
import { applyChatCorrections } from "../../lib/chatCorrections";
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
import { AiErrorText } from "../common/AiSettingsButton";
import { Select } from "../ui/Select";
import { QueuedMessages, useMessageQueue } from "./QueuedMessages";
import { ChatMessageContent, ReplyPreview, chatPrompt, type ChatReply } from "./ChatMessageContent";

type Scope = "inbox" | "unread" | "all";

interface Message {
  role: "user" | "assistant";
  content: string;
  reply?: ChatReply;
  sources?: ChatSource[];
  articleIds?: string[];
  steps?: AgentStep[];
  /** A deep research briefing rather than a quick answer. */
  research?: boolean;
}

/** Append an answer, applying any in-place corrections it makes to earlier replies. */
function withAnswer(prev: Message[], content: string, extra: Omit<Message, "role" | "content">): Message[] {
  const { messages, answer } = applyChatCorrections(prev, content);
  return [...messages, { role: "assistant", content: answer, ...extra }];
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
  const [composerReply, setReply] = useState<ChatReply | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [loading, setLoading] = useState(false);
  const [completedSends, setCompletedSends] = useState(0);
  const [error, setError] = useState<string | null>(null);
  // Deep research: slower, reads the feeds then the web, and writes a cited briefing.
  const [deep, setDeep] = useState(false);
  // What the research in flight has done so far, as it reports it.
  const [progress, setProgress] = useState<string[]>([]);
  const researching = loading && deep;
  const scrollRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  // Set when the chat continues an agent conversation (from the command
  // palette, or "Ask about this page / story"): answers then come from the
  // app agent with this context instead of the scoped article search.
  const [agentContext, setAgentContext] = useState<AgentContext | null>(null);
  const [contextArticleTitle, setContextArticleTitle] = useState<string | null>(null);
  // The cited article under the pointer, as "<message index>:<article id>", so its chips and card light up together.
  const [hoveredSource, setHoveredSource] = useState<string | null>(null);
  const seed = useAgentChatStore((s) => s.seed);
  const pendingSend = useRef<string | null>(null);
  const onSeedSend = useRef<(() => void) | null>(null);
  // Questions asked mid-answer wait here and go out in order; an error holds them.
  const sendRef = useRef<(text: string, reply: ChatReply | null) => void>(() => {});
  const queue = useMessageQueue({ busy: loading, paused: needsSetup || !!error, onSend: (item) => sendRef.current(item.text, item.reply) });

  useEffect(() => {
    if (!open || !seed) return;
    useAgentChatStore.getState().setSeed(null);
    setAgentContext(seed.context);
    onSeedSend.current = seed.onSend ?? null;
    setContextArticleTitle(seed.articleTitle ?? null);
    setDeep(!!seed.research);
    setMessages(seed.messages ?? []);
    setReply(seed.reply ?? null);
    setError(null);
    queue.clear();
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

  // A passage quoted from a selection ("Ask" or "Reply to selection") is
  // waiting for a question, so the box takes focus even on a phone, where
  // opening the chat otherwise leaves the keyboard down.
  useEffect(() => {
    if (!open || !composerReply || needsSetup || showSettings) return;
    inputRef.current?.focus({ preventScroll: true });
  }, [open, composerReply, needsSetup, showSettings]);

  useEffect(() => {
    setError((previous) => isAiSetupError(previous) ? null : previous);
  }, [settings]);

  useEffect(() => {
    const scroller = scrollRef.current;
    if (!scroller) return;
    // A briefing is long: open it at its first line, not its last.
    const last = messages[messages.length - 1];
    const briefing = !loading && last?.research ? scroller.querySelector<HTMLElement>(`[data-message="${messages.length - 1}"]`) : null;
    if (briefing) scroller.scrollTo?.({ top: briefing.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop - 12, behavior: "smooth" });
    else scroller.scrollTo?.({ top: scroller.scrollHeight, behavior: "smooth" });
  }, [messages, loading, progress, queue.queue.length]);

  /** `queuedReply` marks a send from the queue, which leaves the composer alone. */
  const send = async (text?: string, queuedReply?: ChatReply | null) => {
    const fromQueue = queuedReply !== undefined;
    const reply = fromQueue ? queuedReply : composerReply;
    const query = (text ?? input).trim();
    if (!query || needsSetup) return;
    if (loading) {
      if (fromQueue) return;
      queue.enqueue(query, reply);
      setInput("");
      setReply(null);
      return;
    }
    setError(null);

    const userMsg: Message = { role: "user", content: query, reply: reply ?? undefined };
    const next = [...messages, userMsg];
    setMessages(next);
    if (!fromQueue) {
      setInput("");
      setReply(null);
      focusAfterSend.current = true;
    }
    setLoading(true);

    const history: ChatMessageInput[] = messages.map((m) => ({ role: m.role, content: chatPrompt(m.content, m.reply) }));
    const priorIds = [...messages].reverse().find((message) => message.role === "assistant")?.articleIds;

    try {
      if (deep) {
        onSeedSend.current?.();
        const requestId = `research-${Date.now()}-${Math.random().toString(36).slice(2)}`;
        setProgress([]);
        const unlisten = await listen<ResearchProgress>(RESEARCH_PROGRESS_EVENT, (event) => {
          if (event.payload.request_id === requestId) setProgress((steps) => [...steps, event.payload.label]);
        }).catch(() => null);
        try {
          const resp = await researchTopic([...history, { role: "user", content: chatPrompt(query, reply) }], agentContext ?? {}, requestId);
          setMessages((m) => withAnswer(m, resp.content, { sources: resp.sources, articleIds: resp.article_ids, steps: resp.steps, research: true }));
        } finally {
          unlisten?.();
          setProgress([]);
        }
        return;
      }
      if (agentContext) {
        onSeedSend.current?.();
        const resp = await askAgent([...history, { role: "user", content: chatPrompt(query, reply) }], agentContext, priorIds);
        setMessages((m) => withAnswer(m, resp.content, { sources: resp.sources, articleIds: resp.article_ids, steps: resp.steps }));
        const open = resp.actions.find((action) => action.type === "open_article");
        if (open && onOpenArticle) {
          restoreOpener.current = false;
          focusAfterSend.current = false;
          queue.clear();
          onOpenArticle(open.article_id);
          onClose();
        }
        return;
      }
      const resp = await chatWithArticles(scope, chatPrompt(query, reply), history, priorIds);
      setMessages((m) => withAnswer(m, resp.content, { sources: resp.sources, articleIds: resp.article_ids }));
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
      setMessages((m) => m.slice(0, -1));
      // Back to the composer, or to the front of the queue when the
      // reader has started typing the next question.
      if (inputRef.current?.value.trim()) {
        queue.enqueue(query, reply, { first: true });
      } else {
        setInput(query);
        setReply(reply);
      }
    } finally {
      setLoading(false);
      setCompletedSends((count) => count + 1);
    }
  };
  sendRef.current = (text, reply) => void send(text, reply);

  useEffect(() => {
    const text = pendingSend.current;
    if (!text || !open || !agentContext) return;
    pendingSend.current = null;
    void send(text);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, agentContext, messages]);

  /** Opens a cited source: an article in the reader, a web result in the browser. */
  const openSource = (source: ChatSource | undefined) => {
    if (!source) return;
    if (source.source_type === "web" || !onOpenArticle) {
      if (source.url) void openUrl(source.url);
      return;
    }
    restoreOpener.current = false;
    focusAfterSend.current = false;
    onOpenArticle(source.id);
    onClose();
  };

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
          className={`flex items-center gap-3 border-b border-border ${isPhone ? "" : "flex-wrap"}`}
          style={{ padding: "12px 16px", touchAction: isPhone ? "pan-y" : undefined }}
          {...swipeToDismissHandlers}
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-accent flex-shrink-0">
            <circle cx="11" cy="11" r="8" />
            <path d="M21 21l-4.35-4.35" />
          </svg>
          <h3 id="ask-skim-title" className="text-text-primary flex-1 whitespace-nowrap" style={{ fontSize: isPhone ? 18 : 16, fontWeight: 600 }}>
            Ask Skim
          </h3>
          {deep ? (
            <span className="text-text-muted truncate" style={{ fontSize: 12 }} title="Deep research looks across all your feeds, then the web">Feeds + web</span>
          ) : agentContext ? (
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
                {deep
                  ? "Research a topic in depth."
                  : agentContext
                    ? agentAskHeading(agentContext, contextArticleTitle)
                    : "Ask anything about articles in your feed."}
              </p>
              <p className="text-text-muted" style={{ fontSize: 12.5, marginTop: 4, maxWidth: 440 }}>
                {deep
                  ? "Skim reads your feeds first, then searches the web for what they leave out, and writes a briefing that cites both."
                  : "Answers cite the articles they come from. Try one of these:"}
              </p>
              {!deep && <div className="flex flex-wrap justify-center" style={{ gap: 8, marginTop: 16, maxWidth: 520 }}>
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
              </div>}
            </div>
          )}

          {messages.map((m, i) => (
            <div key={i} data-message={i} style={{ marginBottom: 14 }}>
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
                  {m.research ? <ResearchSteps steps={m.steps ?? []} /> : m.steps && <AgentSteps steps={m.steps} />}
                  <ChatMessageContent
                    content={m.content}
                    role={m.role}
                    onReply={(quote) => { setReply(quote); inputRef.current?.focus({ preventScroll: true }); }}
                    replyDisabled={false}
                    citations={m.role === "assistant" && m.sources?.length ? {
                      sources: m.sources,
                      onOpenArticle: (id) => openSource(m.sources?.find((source) => source.id === id)),
                      onHoverSource: (id) => setHoveredSource(id && `${i}:${id}`),
                      highlightId: hoveredSource?.startsWith(`${i}:`) ? hoveredSource.slice(`${i}:`.length) : null,
                    } : undefined}
                  />
                </div>
              </div>
              {m.role === "assistant" && m.sources && m.sources.length > 0 && (
                <SourceGroups
                  sources={m.sources}
                  content={m.content}
                  onOpen={openSource}
                  highlightId={hoveredSource?.startsWith(`${i}:`) ? hoveredSource.slice(`${i}:`.length) : null}
                  onHoverSource={(id) => setHoveredSource(id && `${i}:${id}`)}
                />
              )}
            </div>
          ))}

          {researching && <ResearchProgressList steps={progress} />}

          {loading && !researching && (
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

          {error && !isAiSetupError(error) && <AiErrorText error={error} style={{ fontSize: 14 }} />}

          <QueuedMessages queue={queue} paused={!!error && !loading && !needsSetup} onResume={() => setError(null)} fontSize={13} />
        </div>

        {/* Input */}
        <div className="border-t border-white/5 min-w-0" style={{ padding: "12px 16px 8px" }}>
          {composerReply && <ReplyPreview reply={composerReply} onRemove={() => setReply(null)} />}
          <div className="flex items-center gap-2 min-w-0">
            <textarea
              ref={inputRef}
              aria-label={deep ? "Topic to research" : "Question about your articles"}
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  send();
                }
              }}
              placeholder={loading ? "Queue a follow-up…" : deep ? "Name a topic to research…" : "Ask about your articles…"}
              rows={2}
              className="flex-1 min-w-0 border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors resize-none"
              style={{ background: "rgba(255, 255, 255, 0.05)", padding: "10px 12px", fontSize: 13, width: 0 }}
            />
            <button
              onClick={() => void send()}
              disabled={needsSetup || !input.trim()}
              title={loading ? "Sends when Skim finishes" : undefined}
              className="bg-accent text-white rounded-xl hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors flex-shrink-0"
              style={{ padding: "10px 16px", fontSize: 13 }}
            >
              {loading ? "Queue" : deep ? "Research" : "Send"}
            </button>
          </div>
          <div className="flex items-center gap-3 min-w-0" style={{ marginTop: 8 }}>
            <button
              type="button"
              aria-pressed={deep}
              onClick={() => { setDeep((on) => !on); inputRef.current?.focus({ preventScroll: true }); }}
              disabled={loading}
              className={`research-toggle${deep ? " on" : ""}`}
              title="Reads your feeds first, then searches the web for what they leave out, and writes a cited briefing. Takes a minute or two."
            >
              <ResearchIcon size={14} />
              <span>Deep research</span>
            </button>
            <div className="min-w-0 flex-1">
              {deep ? (
                <p className="text-text-muted" style={{ fontSize: 11, lineHeight: 1.4 }}>Your feeds first, then the web. Takes a minute or two.</p>
              ) : <AIDisclaimer />}
            </div>
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
  onOpen,
  highlightId,
  onHoverSource,
}: {
  sources: ChatSource[];
  content: string;
  onOpen: (source: ChatSource) => void;
  highlightId: string | null;
  onHoverSource: (id: string | null) => void;
}) {
  const { searched } = partitionSources(sources, content);
  const cited = citationOrder(sources, content);
  const renderSources = (items: NumberedSource[]) => (
    <div className="flex flex-col gap-1">
      {items.map(({ source: s, number }) => {
        const isWeb = s.source_type === "web";
        return (
          <button
            key={s.id}
            onClick={() => onOpen(s)}
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
                {number === null && "Web"}
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
          <div className="source-tiles" onMouseLeave={() => onHoverSource(null)}>
            {cited.map(({ source, label }) => (
              <SourceTile
                key={source.id}
                source={source}
                label={label}
                active={highlightId === source.id}
                onHover={() => onHoverSource(source.id)}
                onOpen={() => onOpen(source)}
              />
            ))}
          </div>
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

/** How Skim researched a briefing, folded away under it so the briefing leads. */
function ResearchSteps({ steps }: { steps: AgentStep[] }) {
  return (
    <div className="research-kicker">
      <span className="research-kicker-label"><ResearchIcon size={12} /> Research briefing</span>
      {steps.length > 0 && (
        <details>
          <summary>How Skim researched this ({steps.length} steps)</summary>
          <AgentSteps steps={steps} />
        </details>
      )}
    </div>
  );
}

/** The research in flight, step by step, so a slow answer never looks stuck. */
function ResearchProgressList({ steps }: { steps: string[] }) {
  return (
    <div className="research-progress" role="status" aria-live="polite">
      <div className="research-progress-title">Researching… this takes a minute or two</div>
      <ol>
        {steps.map((label, index) => {
          const current = index === steps.length - 1;
          return (
            <li key={index} className={current ? "current" : "done"}>
              {current ? (
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" className="smooth-spin" aria-hidden>
                  <path d="M21 12a9 9 0 11-6.219-8.56" />
                </svg>
              ) : (
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" aria-hidden>
                  <path d="M5 12l5 5L20 7" />
                </svg>
              )}
              <span className="truncate">{label}</span>
            </li>
          );
        })}
        {steps.length === 0 && <li className="current"><span>Starting…</span></li>}
      </ol>
    </div>
  );
}
