import { useEffect, useState, useCallback, useRef } from "react";
import { useArticle, useMarkRead, useToggleStar, useToggleRead } from "../../hooks/useArticles";
import { useSummarizeArticle } from "../../hooks/useAi";
import { useSettings } from "../../hooks/useSettings";
import { useUiStore } from "../../stores/uiStore";
import { fetchFullArticle, cancelSummarize } from "../../services/commands";
import { ChatDrawer } from "../chat/ChatPanel";
import { useReadingTimeTracker, useSetArticleFeedback, useArticleInteraction } from "../../hooks/useLearning";

type ViewMode = "rss" | "reader" | "web";

function formatDate(timestamp: number | null): string {
  if (!timestamp) return "";
  const date = new Date(timestamp * 1000);
  return date.toLocaleDateString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function stripRssJunk(html: string): string {
  const div = document.createElement("div");
  div.innerHTML = html;
  div.querySelectorAll("a").forEach((a) => {
    const text = a.textContent?.toLowerCase().trim() ?? "";
    if (
      text.includes("read full") ||
      text.includes("read more") ||
      text.includes("continue reading") ||
      text.includes("skip to") ||
      text.includes("full article") ||
      text === "comments"
    ) {
      a.remove();
    }
  });
  return div.innerHTML;
}

function stripFullArticleJunk(html: string): string {
  const div = document.createElement("div");
  div.innerHTML = html;

  // Remove links with junk text
  div.querySelectorAll("a").forEach((a) => {
    const text = a.textContent?.toLowerCase().trim() ?? "";
    if (
      text.includes("skip to") ||
      text.includes("learn more") ||
      text.includes("subscribe") ||
      text.includes("sign in") ||
      text.includes("sign up") ||
      text.includes("log in")
    ) {
      a.remove();
    }
  });

  // Remove form/interactive elements
  div.querySelectorAll("select, label, fieldset, legend, input, textarea").forEach((el) => el.remove());

  // Remove elements whose text is pure site UI
  const walkAndRemove = (root: Element) => {
    const toRemove: Element[] = [];
    root.querySelectorAll("div, span, section, aside, figure").forEach((el) => {
      const text = el.textContent?.trim() ?? "";
      if (text.length < 60 && /^(STORY TEXT|SIZE|WIDTH|LINKS|SUBSCRIBERS ONLY|MINIMIZE TO NAV|TEXT SETTINGS|LEARN MORE)/i.test(text)) {
        toRemove.push(el);
      }
    });
    toRemove.forEach((el) => el.remove());
  };
  walkAndRemove(div);

  // Remove elements by common junk selectors
  const junkSelectors = [
    "[class*='skip']", "[class*='paywall']", "[class*='subscribe']",
    "[class*='newsletter']", "[class*='toolbar']", "[class*='topbar']",
    "[class*='ad-slot']", "[class*='advert']", "[class*='popup']",
    "[class*='modal']", "[class*='overlay']", "[class*='cookie']",
    "[class*='consent']", "[class*='social']", "[class*='share']",
    "[class*='related']", "[class*='comment']", "[class*='story-settings']",
    "[class*='minimize']", "[class*='site-header']", "[class*='site-nav']",
    "[class*='settings']", "[class*='font-size']", "[class*='reading']",
    "[class*='story-text']", "[class*='story_text']",
    "[role='banner']", "[role='navigation']", "[role='complementary']",
    "[aria-hidden='true']",
  ];
  junkSelectors.forEach((sel) => {
    try {
      div.querySelectorAll(sel).forEach((el) => el.remove());
    } catch {
      // invalid selector, skip
    }
  });

  return div.innerHTML;
}

export function ArticleDetail() {
  const { selectedArticleId, setSelectedArticleId, listCollapsed, sidebarCollapsed } = useUiStore();
  const { data: article } = useArticle(selectedArticleId);
  const markRead = useMarkRead();
  const toggleStar = useToggleStar();
  const toggleRead = useToggleRead();
  const summarize = useSummarizeArticle();
  const { data: settings } = useSettings();
  const setFeedback = useSetArticleFeedback();
  const { data: interaction } = useArticleInteraction(selectedArticleId);
  useReadingTimeTracker(selectedArticleId);
  const [showSummarizeMenu, setShowSummarizeMenu] = useState(false);
  const [perArticleLength, setPerArticleLength] = useState<string | undefined>();
  const [perArticleTone, setPerArticleTone] = useState<string | undefined>();
  const [perArticlePrompt, setPerArticlePrompt] = useState<string | undefined>();
  const [perArticleWordCount, setPerArticleWordCount] = useState<number | undefined>();
  const sumMenuRef = useRef<HTMLDivElement>(null);
  const [fullContent, setFullContent] = useState<string | null>(null);
  const [rawHtml, setRawHtml] = useState<string | null>(null);
  const [loadingFull, setLoadingFull] = useState(false);
  const [fullError, setFullError] = useState<string | null>(null);
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const [viewMode, setViewMode] = useState<ViewMode>("rss");

  const modes: ViewMode[] = ["rss", "reader", "web"];
  const slideIndex = modes.indexOf(viewMode);

  // Reset state when article changes — cancel any in-flight summary
  useEffect(() => {
    cancelSummarize().catch(() => {});
    setFullContent(null);
    setRawHtml(null);
    setFullError(null);
    setViewMode("rss");
    summarize.reset();
    setShowSummarizeMenu(false);
    setPerArticleLength(undefined);
    setPerArticleTone(undefined);
    setPerArticlePrompt(undefined);
    setPerArticleWordCount(undefined);
  }, [selectedArticleId]);

  // Close summarize menu on click outside
  useEffect(() => {
    if (!showSummarizeMenu) return;
    const handler = (e: MouseEvent) => {
      if (sumMenuRef.current && !sumMenuRef.current.contains(e.target as Node)) {
        setShowSummarizeMenu(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [showSummarizeMenu]);

  const doSummarize = useCallback(
    (force = false) => {
      if (!article) return;
      if (
        !settings ||
        settings.ai.provider === "none" ||
        (settings.ai.provider === "local" && !settings.ai.local_model_path)
      ) {
        useUiStore.getState().setShowSettings(true);
        return;
      }
      // Force re-summarize if any per-article override is set
      const hasOverrides = perArticleLength || perArticleTone || perArticlePrompt;
      summarize.mutate({
        articleId: article.id,
        force: force || !!hasOverrides,
        summaryLength: perArticleLength,
        summaryTone: perArticleTone,
        summaryCustomPrompt: perArticlePrompt,
      });
      setShowSummarizeMenu(false);
    },
    [article, settings, summarize, perArticleLength, perArticleTone]
  );

  // Mark as read when opened
  useEffect(() => {
    if (article && !article.is_read) {
      markRead.mutate([article.id]);
    }
  }, [article?.id]);

  const fetchFull = useCallback(async () => {
    if (!article?.url || fullContent) return;
    setLoadingFull(true);
    setFullError(null);
    try {
      const result = await fetchFullArticle(article.url);
      setFullContent(stripFullArticleJunk(result.html));
      setRawHtml(result.raw_html);
    } catch (e) {
      setFullError(String(e));
    } finally {
      setLoadingFull(false);
    }
  }, [article?.url, fullContent]);

  const handleReader = useCallback(async () => {
    if (viewMode === "reader") { setViewMode("rss"); return; }
    await fetchFull();
    setViewMode("reader");
  }, [viewMode, fetchFull]);

  const handleWebView = useCallback(async () => {
    if (viewMode === "web") { setViewMode("rss"); return; }
    await fetchFull();
    setViewMode("web");
  }, [viewMode, fetchFull]);

  // Arrow key navigation — right/left slide between panels
  useEffect(() => {
    if (!article?.url) return;
    const handler = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      if (e.key === "ArrowRight") {
        e.preventDefault();
        fetchFull();
        setViewMode((prev) => {
          const i = modes.indexOf(prev);
          return i < 2 ? modes[i + 1] : prev;
        });
      } else if (e.key === "ArrowLeft") {
        e.preventDefault();
        setViewMode((prev) => {
          const i = modes.indexOf(prev);
          return i > 0 ? modes[i - 1] : prev;
        });
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [article?.url, fetchFull]);

  if (!article) {
    return (
      <div
        className="flex-1 flex items-center justify-center bg-bg-primary/60 cursor-pointer"
        onClick={() => {
          const state = useUiStore.getState();
          if (state.listCollapsed) state.toggleList();
        }}
      >
        <span className="text-text-muted text-sm">Select an article to read</span>
      </div>
    );
  }

  let rssHtml: string | null = null;
  try {
    rssHtml = article.content_html ? stripRssJunk(article.content_html) : null;
  } catch (e) {
    console.error("Failed to strip RSS junk:", e);
    rssHtml = article.content_html;
  }

  const modeBtn = (mode: ViewMode, label: string, icon: React.ReactNode) => (
    <button
      onClick={mode === "reader" ? handleReader : mode === "web" ? handleWebView : () => setViewMode("rss")}
      disabled={loadingFull}
      className={`flex items-center gap-1.5 rounded-lg border transition-colors disabled:opacity-40 ${
        viewMode === mode
          ? "border-accent/30 text-accent bg-accent/10"
          : "border-white/10 text-text-secondary hover:text-text-primary hover:border-white/20"
      }`}
      style={{ padding: "6px 12px", fontSize: 12 }}
    >
      {icon}
      {label}
    </button>
  );

  return (
    <div className="flex-1 flex flex-col h-full bg-bg-primary/60 overflow-hidden">
      {/* Toolbar */}
      <div
        className="flex items-center justify-between relative z-20 flex-shrink-0"
        style={{ height: 52, padding: "0 24px" }}
      >
        {!(sidebarCollapsed && listCollapsed) && (
          <button
            onClick={() => {
              setSelectedArticleId(null);
              const state = useUiStore.getState();
              if (state.listCollapsed) state.toggleList();
            }}
            className="text-text-muted hover:text-text-primary p-2 rounded-lg hover:bg-white/10 transition-colors"
            title="Close"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M19 12H5M12 19l-7-7 7-7" />
            </svg>
          </button>
        )}

        <div className="flex items-center gap-2">
          {article.url && (
            <>
              {modeBtn("reader", "Reader",
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
                  <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
                </svg>
              )}
              {modeBtn("web", "Web",
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <circle cx="12" cy="12" r="10" />
                  <line x1="2" y1="12" x2="22" y2="12" />
                  <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
                </svg>
              )}
            </>
          )}

          <div className="w-px h-5 bg-white/10" />

          <div className="relative" ref={sumMenuRef}>
            <div className="flex">
              <button
                onClick={() => doSummarize(false)}
                disabled={summarize.isPending}
                className="rounded-l-lg border border-r-0 border-white/10 text-text-secondary hover:text-text-primary hover:border-white/20 transition-colors disabled:opacity-40"
                style={{ padding: "6px 12px", fontSize: 12 }}
              >
                {summarize.isPending ? "..." : "Summarize"}
              </button>
              <button
                onClick={() => setShowSummarizeMenu(!showSummarizeMenu)}
                disabled={summarize.isPending}
                className="rounded-r-lg border border-white/10 text-text-secondary hover:text-text-primary hover:border-white/20 transition-colors disabled:opacity-40"
                style={{ padding: "6px 4px", fontSize: 12 }}
              >
                <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M6 9l6 6 6-6" />
                </svg>
              </button>
            </div>

            {showSummarizeMenu && (
              <div
                className="absolute right-0 top-full mt-1 border border-white/10 rounded-xl shadow-xl z-50"
                style={{ background: "rgba(22, 27, 34, 0.95)", backdropFilter: "blur(12px)", padding: "12px", width: 260 }}
              >
                <div style={{ marginBottom: 8 }}>
                  <label className="text-text-muted block" style={{ fontSize: 11, marginBottom: 4 }}>Length</label>
                  <select
                    value={perArticleLength ?? settings?.ai.summary_length ?? "short"}
                    onChange={(e) => setPerArticleLength(e.target.value)}
                    className="w-full border border-white/10 rounded-lg text-text-primary bg-white/5"
                    style={{ padding: "4px 8px", fontSize: 12 }}
                  >
                    <option value="short">Short (~30 words)</option>
                    <option value="medium">Medium (~150 words)</option>
                    <option value="long">Long (~300 words)</option>
                    <option value="custom">Custom...</option>
                  </select>
                  {(perArticleLength ?? settings?.ai.summary_length) === "custom" && (
                    <input
                      type="number"
                      min={20}
                      max={1000}
                      placeholder="Word count"
                      value={perArticleWordCount ?? settings?.ai.summary_custom_word_count ?? ""}
                      onChange={(e) => setPerArticleWordCount(parseInt(e.target.value) || undefined)}
                      className="w-full border border-white/10 rounded-lg text-text-primary bg-white/5"
                      style={{ padding: "4px 8px", fontSize: 12, marginTop: 4 }}
                    />
                  )}
                </div>
                <div style={{ marginBottom: 8 }}>
                  <label className="text-text-muted block" style={{ fontSize: 11, marginBottom: 4 }}>Tone</label>
                  <select
                    value={perArticleTone ?? settings?.ai.summary_tone ?? "concise"}
                    onChange={(e) => setPerArticleTone(e.target.value)}
                    className="w-full border border-white/10 rounded-lg text-text-primary bg-white/5"
                    style={{ padding: "4px 8px", fontSize: 12 }}
                  >
                    <option value="concise">Concise</option>
                    <option value="detailed">Detailed</option>
                    <option value="casual">Casual</option>
                    <option value="technical">Technical</option>
                  </select>
                </div>
                <div style={{ marginBottom: 10 }}>
                  <label className="text-text-muted block" style={{ fontSize: 11, marginBottom: 4 }}>Custom prompt</label>
                  <textarea
                    value={perArticlePrompt ?? settings?.ai.summary_custom_prompt ?? ""}
                    onChange={(e) => setPerArticlePrompt(e.target.value || undefined)}
                    placeholder="e.g. Focus on financial implications..."
                    className="w-full border border-white/10 rounded-lg text-text-primary bg-white/5 placeholder-text-muted"
                    style={{ padding: "6px 8px", fontSize: 11, minHeight: 48, resize: "vertical" }}
                    rows={2}
                  />
                </div>
                <div className="flex gap-2">
                  <button
                    onClick={() => doSummarize(false)}
                    className="flex-1 text-accent border border-accent/20 hover:bg-accent/10 rounded-lg transition-colors"
                    style={{ padding: "5px 0", fontSize: 11 }}
                  >
                    Summarize
                  </button>
                  {summarize.data && (
                    <button
                      onClick={() => doSummarize(true)}
                      className="flex-1 text-text-secondary border border-white/10 hover:bg-white/5 rounded-lg transition-colors"
                      style={{ padding: "5px 0", fontSize: 11 }}
                    >
                      Re-summarize
                    </button>
                  )}
                </div>
              </div>
            )}
          </div>

          <div className="w-px h-5 bg-white/10" />

          <button
            onClick={() => toggleStar.mutate(article.id)}
            className={`p-2 rounded-lg hover:bg-white/10 transition-colors ${
              article.is_starred ? "text-warning" : "text-text-muted hover:text-text-primary"
            }`}
            title={article.is_starred ? "Unstar" : "Star"}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill={article.is_starred ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2">
              <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
            </svg>
          </button>

          <button
            onClick={() => toggleRead.mutate(article.id)}
            className={`p-2 rounded-lg hover:bg-white/10 transition-colors ${
              !article.is_read ? "text-accent" : "text-text-muted hover:text-text-primary"
            }`}
            title={article.is_read ? "Mark as unread" : "Mark as read"}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill={!article.is_read ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2">
              <circle cx="12" cy="12" r="5" />
            </svg>
          </button>

          <div className="w-px h-5 bg-white/10" />

          {/* Learning feedback buttons */}
          <button
            onClick={() => setFeedback.mutate({
              articleId: article.id,
              feedback: interaction?.feedback === "more" ? null : "more",
            })}
            className={`p-2 rounded-lg hover:bg-white/10 transition-colors ${
              interaction?.feedback === "more" ? "text-green-400" : "text-text-muted hover:text-text-primary"
            }`}
            title="More like this"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M14 9V5a3 3 0 0 0-3-3l-4 9v11h11.28a2 2 0 0 0 2-1.7l1.38-9a2 2 0 0 0-2-2.3H14zM4 22H2V11h2" />
            </svg>
          </button>
          <button
            onClick={() => setFeedback.mutate({
              articleId: article.id,
              feedback: interaction?.feedback === "less" ? null : "less",
            })}
            className={`p-2 rounded-lg hover:bg-white/10 transition-colors ${
              interaction?.feedback === "less" ? "text-red-400" : "text-text-muted hover:text-text-primary"
            }`}
            title="Less like this"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M10 15v4a3 3 0 0 0 3 3l4-9V2H5.72a2 2 0 0 0-2 1.7l-1.38 9a2 2 0 0 0 2 2.3H10zM20 2h2v11h-2" />
            </svg>
          </button>

          {article.url && (
            <a href={article.url} target="_blank" rel="noopener noreferrer"
              className="text-text-muted hover:text-text-primary p-2 rounded-lg hover:bg-white/10 transition-colors"
              title="Open in browser"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3" />
              </svg>
            </a>
          )}
        </div>
      </div>

      {fullError && (
        <div style={{ padding: "0 24px 8px" }}>
          <p className="text-danger" style={{ fontSize: 13 }}>{fullError}</p>
        </div>
      )}

      {/* Summary — visible across all panels */}
      {summarize.isPending && (
        <div className="flex-shrink-0" style={{ maxWidth: 720, margin: "0 auto", padding: "0 40px 8px", width: "100%" }}>
          <div className="rounded-xl border border-white/10" style={{ padding: "16px 20px", background: "rgba(255,255,255,0.03)" }}>
            <div className="text-text-muted uppercase tracking-wider font-semibold" style={{ fontSize: 11, marginBottom: 8 }}>AI Summary</div>
            <div className="flex items-center gap-2 text-text-muted" style={{ fontSize: 14 }}>
              <svg className="animate-spin" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M21 12a9 9 0 1 1-6.219-8.56" />
              </svg>
              Summarizing...
            </div>
          </div>
        </div>
      )}

      {summarize.data && (
        <div className="flex-shrink-0" style={{ maxWidth: 720, margin: "0 auto", padding: "0 40px 8px", width: "100%", maxHeight: "40vh", overflow: "hidden", display: "flex", flexDirection: "column" }}>
          <div className="rounded-xl border border-white/10" style={{ padding: "16px 20px", background: "rgba(255,255,255,0.03)", position: "relative", overflowY: "auto" }}>
            <button
              onClick={() => summarize.reset()}
              className="text-text-muted hover:text-text-primary transition-colors"
              style={{ position: "absolute", top: 12, right: 12, padding: 4, lineHeight: 0 }}
              title="Dismiss summary"
            >
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M18 6L6 18M6 6l12 12" />
              </svg>
            </button>
            <div className="text-text-muted uppercase tracking-wider font-semibold" style={{ fontSize: 11, marginBottom: 8 }}>AI Summary</div>
            {summarize.data.bullet_summary && (
              <div className="text-text-primary whitespace-pre-wrap" style={{ fontSize: 14, marginBottom: 10, lineHeight: 1.6 }}>{summarize.data.bullet_summary}</div>
            )}
            {summarize.data.full_summary && (
              <div
                className="text-text-primary leading-relaxed prose prose-invert prose-sm max-w-none"
                style={{ fontSize: 14, opacity: 0.85 }}
                dangerouslySetInnerHTML={{
                  __html: summarize.data.full_summary
                    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
                    .replace(/\*(.+?)\*/g, '<em>$1</em>')
                    .replace(/\n\n/g, '</p><p style="margin-top:12px">')
                    .replace(/^/, '<p>').replace(/$/, '</p>')
                }}
              />
            )}
          </div>
        </div>
      )}

      {summarize.isError && (() => {
        const msg = String(summarize.error instanceof Error ? summarize.error.message : summarize.error);
        const isConfigError = msg.toLowerCase().includes("no ai provider configured") || msg.toLowerCase().includes("no local model selected") || msg.toLowerCase().includes("go to settings");
        const isModelLoadError = msg.toLowerCase().includes("failed to load model") || msg.toLowerCase().includes("null result from llama");
        return (
          <div className="flex-shrink-0" style={{ maxWidth: 720, margin: "0 auto", padding: "0 40px 8px", width: "100%" }}>
            {isConfigError ? (
              <div className="rounded-xl border border-white/10" style={{ padding: "12px 16px", fontSize: 14, background: "rgba(255,255,255,0.03)" }}>
                <span className="text-text-secondary">AI not configured. </span>
                <button onClick={() => useUiStore.getState().setShowSettings(true)} className="text-accent hover:underline">Open Settings</button>
                <span className="text-text-secondary"> to set up a provider.</span>
              </div>
            ) : isModelLoadError ? (
              <div className="rounded-xl border border-warning/30" style={{ padding: "12px 16px", fontSize: 14, background: "rgba(255, 170, 50, 0.08)" }}>
                <span className="text-warning font-medium">Model failed to load. </span>
                <span className="text-text-secondary">It may be corrupted or too large for your system. </span>
                <button onClick={() => useUiStore.getState().setShowSettings(true)} className="text-accent hover:underline">Try a different model</button>
              </div>
            ) : (
              <div className="rounded-xl border border-danger/30 text-danger" style={{ padding: "12px 16px", fontSize: 14, background: "rgba(248, 81, 73, 0.1)" }}>
                {msg}
              </div>
            )}
          </div>
        );
      })()}

      {/* Sliding panels */}
      <div className="slide-container">
        <div
          className="slide-track"
          style={{ transform: `translateX(-${slideIndex * 100}%)` }}
        >
          {/* Panel 0: RSS preview */}
          <div className="slide-panel">

            <div style={{ maxWidth: 720, margin: "0 auto", padding: "24px 40px 80px" }}>
              <div style={{ marginBottom: 28 }}>
                <h1 className="text-text-primary" style={{ fontSize: 26, fontWeight: 700, lineHeight: 1.3, marginBottom: 12 }}>
                  {article.title}
                </h1>
                <div className="flex items-center flex-wrap gap-x-2 gap-y-1" style={{ fontSize: 13 }}>
                  <span className="text-accent font-medium">{article.feed_title}</span>
                  {article.author && (<><span className="text-text-muted">·</span><span className="text-text-secondary">{article.author}</span></>)}
                  <span className="text-text-muted">·</span>
                  <span className="text-text-muted">{formatDate(article.published_at)}</span>
                </div>
              </div>

              {rssHtml ? (
                <div className="article-content text-text-primary" dangerouslySetInnerHTML={{ __html: rssHtml }} />
              ) : article.content_text ? (
                <div className="article-content text-text-primary whitespace-pre-wrap">{article.content_text}</div>
              ) : (
                <p className="text-text-muted" style={{ fontSize: 14 }}>No preview available.</p>
              )}
            </div>
          </div>

          {/* Panel 1: Reader mode */}
          <div className="slide-panel">

            {fullContent && (
              <div style={{ maxWidth: 720, margin: "0 auto", padding: "24px 40px 80px" }}>
                <div style={{ marginBottom: 28 }}>
                  <h1 className="text-text-primary" style={{ fontSize: 26, fontWeight: 700, lineHeight: 1.3, marginBottom: 12 }}>{article.title}</h1>
                  <div className="flex items-center flex-wrap gap-x-2 gap-y-1" style={{ fontSize: 13 }}>
                    <span className="text-accent font-medium">{article.feed_title}</span>
                    {article.author && (<><span className="text-text-muted">·</span><span className="text-text-secondary">{article.author}</span></>)}
                    <span className="text-text-muted">·</span>
                    <span className="text-text-muted">{formatDate(article.published_at)}</span>
                  </div>
                </div>
                <div className="full-article-content" dangerouslySetInnerHTML={{ __html: fullContent }} />
              </div>
            )}
          </div>

          {/* Panel 2: Web view */}
          <div className="slide-panel slide-panel-web">
            {rawHtml && (
              <iframe
                ref={iframeRef}
                srcDoc={rawHtml.replace(
                  /(<head[^>]*>)/i,
                  '$1<meta name="color-scheme" content="dark"><style>:root{color-scheme:dark}*::-webkit-scrollbar{width:6px!important}*::-webkit-scrollbar-track{background:#1a1a1a!important}*::-webkit-scrollbar-thumb{background:rgba(255,255,255,0.15)!important;border-radius:3px!important}*::-webkit-scrollbar-thumb:hover{background:rgba(255,255,255,0.3)!important}html,body{scrollbar-color:rgba(255,255,255,0.15) #1a1a1a!important;scrollbar-width:thin!important}</style>'
                )}
                sandbox="allow-scripts allow-popups allow-forms allow-modals allow-pointer-lock allow-presentation"
                style={{ width: "100%", height: "100%", border: "none", background: "#1a1a1a" }}
                title="Article web view"
                onLoad={() => {
                  try {
                    const win = iframeRef.current?.contentWindow;
                    if (win) {
                      // Re-inject scrollbar styles after page loads (overrides site CSS)
                      const s = win.document.createElement("style");
                      s.textContent = "*::-webkit-scrollbar{width:6px!important}*::-webkit-scrollbar-track{background:#1a1a1a!important}*::-webkit-scrollbar-thumb{background:rgba(255,255,255,0.15)!important;border-radius:3px!important}*::-webkit-scrollbar-thumb:hover{background:rgba(255,255,255,0.3)!important}html,body{scrollbar-color:rgba(255,255,255,0.15) #1a1a1a!important;scrollbar-width:thin!important}";
                      win.document.head.appendChild(s);

                      // Prevent context menu (Inspect Element) inside iframe
                      win.document.addEventListener("contextmenu", (e: Event) => {
                        e.preventDefault();
                      });

                      // Arrow key navigation for prism
                      win.addEventListener("keydown", ((e: KeyboardEvent) => {
                        if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
                          e.preventDefault();
                          window.dispatchEvent(new KeyboardEvent("keydown", { key: e.key }));
                        }
                      }) as EventListener);
                    }
                  } catch { /* cross-origin */ }
                }}
              />
            )}
          </div>

        </div>
      </div>

      {/* Chat drawer — collapsible bottom pane */}
      <ChatDrawer articleId={article.id} articleTitle={article.title} />
    </div>
  );
}
