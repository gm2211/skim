import { useEffect, useState, useCallback, useRef } from "react";
import { createPortal } from "react-dom";
import { useArticle, useMarkRead, useToggleStar, useToggleRead } from "../../hooks/useArticles";
import { useSummarizeArticle } from "../../hooks/useAi";
import { useSettings } from "../../hooks/useSettings";
import { useUiStore } from "../../stores/uiStore";
import { fetchFullArticle, cancelSummarize } from "../../services/commands";
import { ChatDrawer } from "../chat/ChatPanel";
import { useReadingTimeTracker } from "../../hooks/useLearning";
import { openUrl } from "@tauri-apps/plugin-opener";
import { NumberInput } from "../ui/NumberInput";
import { AIDisclaimer } from "../common/AIDisclaimer";

type ViewMode = "reader" | "web";

type FetchedArticleContent = {
  html: string;
  raw_html: string;
};

const EMBEDDED_WEB_VIEW_CSS = `
:root{color-scheme:dark}
html,body{width:100%!important;max-width:100%!important;overflow-x:hidden!important;overscroll-behavior-x:none!important;touch-action:pan-y;background:#1a1a1a!important}
*,*::before,*::after{box-sizing:border-box!important;max-width:100%!important}
img,video,iframe,embed,object,canvas,svg{max-width:100%!important;height:auto!important}
pre,code{white-space:pre-wrap!important;overflow-wrap:anywhere!important;overflow-x:hidden!important}
table{display:block!important;width:100%!important;table-layout:fixed!important;overflow-x:hidden!important}
th,td,a,p,li,span,div{overflow-wrap:anywhere!important}
*::-webkit-scrollbar{width:6px!important}
*::-webkit-scrollbar-track{background:#1a1a1a!important}
*::-webkit-scrollbar-thumb{background:rgba(255,255,255,0.15)!important;border-radius:3px!important}
*::-webkit-scrollbar-thumb:hover{background:rgba(255,255,255,0.3)!important}
html,body{scrollbar-color:rgba(255,255,255,0.15) #1a1a1a!important;scrollbar-width:thin!important}
`;

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

function htmlToPlainText(html: string): string {
  const div = document.createElement("div");
  div.innerHTML = html;
  div.querySelectorAll("script, style, noscript, svg").forEach((el) => el.remove());
  return (div.textContent ?? "").replace(/\s+/g, " ").trim();
}

function looksLikeBlockedHtml(html: string): boolean {
  const plain = htmlToPlainText(html);
  return (
    /recaptcha (service|challenge)|captcha.{0,80}(challenge|required|verification)|verification required|access denied|are you a human|cloudflare|just a moment|please enable (javascript|js)|enable javascript/i.test(plain)
  );
}

function prepareFetchedArticle(result: FetchedArticleContent): {
  fullContent: string | null;
  rawHtml: string | null;
  error: string | null;
} {
  const stripped = stripFullArticleJunk(result.html);
  const plain = htmlToPlainText(stripped);
  const blocked = looksLikeBlockedHtml(stripped) || looksLikeBlockedHtml(result.raw_html);

  if (blocked) {
    return {
      fullContent: null,
      rawHtml: null,
      error: "Reader couldn't extract this page (likely paywall, JS-required, or anti-bot challenge). Showing RSS preview.",
    };
  }

  if (plain.length < 240) {
    return {
      fullContent: null,
      rawHtml: result.raw_html,
      error: "Reader couldn't extract this page (likely paywall, JS-required, or anti-bot challenge). Showing RSS preview.",
    };
  }

  return {
    fullContent: stripped,
    rawHtml: result.raw_html,
    error: null,
  };
}

export function ArticleDetail() {
  const { selectedArticleId, setSelectedArticleId, listCollapsed, sidebarCollapsed, sidebarView, isPhone, phoneBack } = useUiStore();
  const { data: article } = useArticle(selectedArticleId);
  const markRead = useMarkRead();
  const toggleStar = useToggleStar();
  const toggleRead = useToggleRead();
  const summarize = useSummarizeArticle();
  const { data: settings } = useSettings();
  // Don't count engagement when browsing the Recent tab — that view already
  // reflects past engagement and would otherwise self-reinforce.
  useReadingTimeTracker(selectedArticleId, sidebarView.type === "recent");
  const [showSummarizeMenu, setShowSummarizeMenu] = useState(false);
  const [perArticleLength, setPerArticleLength] = useState<string | undefined>();
  const [perArticleTone, setPerArticleTone] = useState<string | undefined>();
  const [perArticlePrompt, setPerArticlePrompt] = useState<string | undefined>();
  const [perArticleWordCount, setPerArticleWordCount] = useState<number | undefined>();
  const sumMenuRef = useRef<HTMLDivElement>(null);
  const longPressTimer = useRef<number | null>(null);
  const longPressFired = useRef(false);
  const longPressStart = useRef<{ x: number; y: number } | null>(null);
  const articleSwipeRef = useRef<{ x: number; y: number; handled: boolean } | null>(null);
  const [fullContent, setFullContent] = useState<string | null>(null);
  const [rawHtml, setRawHtml] = useState<string | null>(null);
  const [loadingFull, setLoadingFull] = useState(false);
  const [fullError, setFullError] = useState<string | null>(null);
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const fullFetchSeqRef = useRef(0);
  const [viewMode, setViewMode] = useState<ViewMode>("reader");

  // Reset state when article changes — cancel any in-flight summary
  useEffect(() => {
    fullFetchSeqRef.current += 1;
    cancelSummarize().catch(() => {});
    setFullContent(null);
    setRawHtml(null);
    setLoadingFull(false);
    setFullError(null);
    setViewMode("reader");
    summarize.reset();
    setShowSummarizeMenu(false);
    setPerArticleLength(undefined);
    setPerArticleTone(undefined);
    setPerArticlePrompt(undefined);
    setPerArticleWordCount(undefined);
  }, [selectedArticleId]);

  // Auto-fetch full article on open so Reader has content immediately.
  // Inlined (instead of calling fetchFull) so the fetch isn't gated on the
  // previous article's fullContent value during the reset → fetch transition.
  useEffect(() => {
    const articleId = article?.id;
    const url = article?.url;
    if (!articleId || !url) return;
    let cancelled = false;
    const seq = ++fullFetchSeqRef.current;
    setLoadingFull(true);
    setFullError(null);
    (async () => {
      try {
        const result = await fetchFullArticle(url);
        if (cancelled || seq !== fullFetchSeqRef.current) return;
        const prepared = prepareFetchedArticle(result);
        setRawHtml(prepared.rawHtml);
        setFullContent(prepared.fullContent);
        setFullError(prepared.error);
      } catch (e) {
        if (!cancelled && seq === fullFetchSeqRef.current) setFullError(String(e));
      } finally {
        if (!cancelled && seq === fullFetchSeqRef.current) setLoadingFull(false);
      }
    })();
    return () => { cancelled = true; };
  }, [selectedArticleId, article?.id, article?.url]);

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
    const articleId = article?.id;
    const url = article?.url;
    if (!articleId || !url || rawHtml) return;
    const seq = ++fullFetchSeqRef.current;
    setLoadingFull(true);
    setFullError(null);
    try {
      const result = await fetchFullArticle(url);
      if (seq !== fullFetchSeqRef.current || useUiStore.getState().selectedArticleId !== articleId) return;
      const prepared = prepareFetchedArticle(result);
      setFullContent(prepared.fullContent);
      setRawHtml(prepared.rawHtml);
      setFullError(prepared.error);
    } catch (e) {
      if (seq === fullFetchSeqRef.current) setFullError(String(e));
    } finally {
      if (seq === fullFetchSeqRef.current) setLoadingFull(false);
    }
  }, [article?.id, article?.url, rawHtml]);

  const handleReader = useCallback(async () => {
    if (viewMode === "reader") return;
    await fetchFull();
    setViewMode("reader");
  }, [viewMode, fetchFull]);

  const handleWebView = useCallback(async () => {
    if (viewMode === "web") { setViewMode("reader"); return; }
    await fetchFull();
    setViewMode("web");
  }, [viewMode, fetchFull]);

  const handleArticleTouchStart = useCallback((e: React.TouchEvent<HTMLDivElement>) => {
    if (!isPhone) return;
    const t = e.touches[0];
    if (!t) return;
    articleSwipeRef.current = { x: t.clientX, y: t.clientY, handled: false };
  }, [isPhone]);

  const handleArticleTouchMove = useCallback((e: React.TouchEvent<HTMLDivElement>) => {
    if (!isPhone || !articleSwipeRef.current) return;
    const t = e.touches[0];
    if (!t) return;

    const dx = t.clientX - articleSwipeRef.current.x;
    const absDx = Math.abs(dx);
    const dy = Math.abs(t.clientY - articleSwipeRef.current.y);
    if (dy > 40 && dy > absDx) {
      articleSwipeRef.current.handled = true;
      return;
    }
    if (absDx <= 10 || absDx <= dy) return;

    e.preventDefault();
    if (articleSwipeRef.current.handled || absDx < 60) return;
    articleSwipeRef.current.handled = true;

    if (dx < 0 && viewMode === "reader" && article?.url) {
      void handleWebView();
    } else if (dx > 0 && viewMode === "web") {
      void handleReader();
    } else if (dx > 0 && viewMode === "reader") {
      phoneBack();
    }
  }, [article?.url, handleReader, handleWebView, isPhone, phoneBack, viewMode]);

  const handleArticleTouchEnd = useCallback(() => {
    articleSwipeRef.current = null;
  }, []);

  // Arrow key navigation — toggle between reader and web views
  useEffect(() => {
    if (!article?.url) return;
    const handler = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      if (e.key === "ArrowRight") {
        e.preventDefault();
        fetchFull();
        setViewMode("web");
      } else if (e.key === "ArrowLeft") {
        e.preventDefault();
        setViewMode("reader");
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
      onClick={mode === "reader" ? handleReader : handleWebView}
      disabled={loadingFull}
      className={`flex items-center gap-1.5 rounded-lg border transition-colors disabled:opacity-40 ${
        viewMode === mode
          ? "border-accent/30 text-accent bg-accent/10"
          : "border-white/10 text-text-secondary hover:text-text-primary hover:border-white/20"
      }`}
      style={{ padding: isPhone ? "6px 8px" : "6px 12px", fontSize: 12 }}
      aria-label={label}
      title={label}
    >
      {icon}
      {!isPhone && label}
    </button>
  );

  const renderSummarizeMenuBody = () => (
    <>
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
          <NumberInput
            min={20}
            max={1000}
            placeholder="Word count"
            value={perArticleWordCount ?? settings?.ai.summary_custom_word_count ?? null}
            onChange={(n) => setPerArticleWordCount(n ?? undefined)}
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
    </>
  );

  return (
    <div className="flex-1 flex flex-col h-full bg-bg-primary/60 overflow-hidden">
      {/* Toolbar */}
      <div
        className="flex items-center justify-between relative z-20 flex-shrink-0"
        style={{ height: 52, padding: isPhone ? "0 10px" : "0 24px", gap: isPhone ? 4 : undefined }}
      >
        {(isPhone || !(sidebarCollapsed && listCollapsed)) && (
          <button
            onClick={() => {
              if (isPhone) {
                phoneBack();
                return;
              }
              setSelectedArticleId(null);
              const state = useUiStore.getState();
              if (state.listCollapsed) state.toggleList();
            }}
            className="text-text-muted hover:text-text-primary p-2 rounded-lg hover:bg-white/10 transition-colors"
            title={isPhone ? "Back" : "Close"}
          >
            <svg width={isPhone ? 22 : 16} height={isPhone ? 22 : 16} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M19 12H5M12 19l-7-7 7-7" />
            </svg>
          </button>
        )}

        <div
          className="flex items-center gap-2 min-w-0"
          style={isPhone ? { gap: 6, flex: "1 1 auto", flexWrap: "nowrap" } : undefined}
        >
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

          {!isPhone && <div className="w-px h-5 bg-white/10" />}

          <div className="relative" ref={sumMenuRef}>
            <div className="flex">
              <button
                onClick={() => {
                  if (longPressFired.current) { longPressFired.current = false; return; }
                  doSummarize(false);
                }}
                onPointerDown={isPhone ? (e) => {
                  if (e.pointerType !== "touch") return;
                  longPressFired.current = false;
                  longPressStart.current = { x: e.clientX, y: e.clientY };
                  if (longPressTimer.current) window.clearTimeout(longPressTimer.current);
                  longPressTimer.current = window.setTimeout(() => {
                    longPressFired.current = true;
                    setShowSummarizeMenu(true);
                    if (navigator.vibrate) navigator.vibrate(8);
                  }, 450);
                } : undefined}
                onPointerUp={isPhone ? () => {
                  if (longPressTimer.current) { window.clearTimeout(longPressTimer.current); longPressTimer.current = null; }
                  longPressStart.current = null;
                } : undefined}
                onPointerMove={isPhone ? (e) => {
                  if (!longPressStart.current || !longPressTimer.current) return;
                  const dx = e.clientX - longPressStart.current.x;
                  const dy = e.clientY - longPressStart.current.y;
                  if (Math.hypot(dx, dy) > 10) {
                    window.clearTimeout(longPressTimer.current);
                    longPressTimer.current = null;
                  }
                } : undefined}
                onPointerLeave={isPhone ? () => {
                  if (longPressTimer.current) { window.clearTimeout(longPressTimer.current); longPressTimer.current = null; }
                } : undefined}
                onContextMenu={isPhone ? (e) => e.preventDefault() : undefined}
                disabled={summarize.isPending}
                className={`${isPhone ? "rounded-lg" : "rounded-l-lg border-r-0"} border border-white/10 text-text-secondary hover:text-text-primary hover:border-white/20 transition-colors disabled:opacity-40`}
                style={{ padding: isPhone ? "6px 10px" : "6px 12px", fontSize: 12, minHeight: isPhone ? 32 : undefined, touchAction: "manipulation", userSelect: "none", WebkitUserSelect: "none", WebkitTouchCallout: "none" }}
                title={isPhone ? "Tap: summarize • Long press: options" : "Summarize"}
                aria-label="Summarize"
              >
                {summarize.isPending ? "..." : (isPhone ? (
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
                    <polyline points="14 2 14 8 20 8" />
                    <line x1="16" y1="13" x2="8" y2="13" />
                    <line x1="16" y1="17" x2="8" y2="17" />
                  </svg>
                ) : "Summarize")}
              </button>
              {!isPhone && (
                <button
                  onClick={() => setShowSummarizeMenu(!showSummarizeMenu)}
                  disabled={summarize.isPending}
                  className="rounded-r-lg border border-white/10 text-text-secondary hover:text-text-primary hover:border-white/20 transition-colors disabled:opacity-40 flex items-center justify-center"
                  style={{ padding: "6px 4px", fontSize: 12 }}
                  aria-label="Summary options"
                  title="Summary options"
                >
                  <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M6 9l6 6 6-6" />
                  </svg>
                </button>
              )}
            </div>

            {showSummarizeMenu && (
              isPhone ? createPortal(
                <div className="fixed inset-0 z-50" onClick={() => setShowSummarizeMenu(false)}>
                  <div
                    className="absolute left-1/2 -translate-x-1/2 border border-white/10 rounded-xl shadow-xl"
                    style={{ background: "rgba(22, 27, 34, 0.95)", backdropFilter: "blur(12px)", padding: "12px", width: "min(320px, calc(100vw - 24px))", top: "calc(env(safe-area-inset-top, 0px) + 70px)" }}
                    onClick={(e) => e.stopPropagation()}
                  >
                    {renderSummarizeMenuBody()}
                  </div>
                </div>,
                document.body
              ) : (
                <div
                  className="absolute right-0 top-full mt-1 border border-white/10 rounded-xl shadow-xl z-50"
                  style={{ background: "rgba(22, 27, 34, 0.95)", backdropFilter: "blur(12px)", padding: "12px", width: 260 }}
                >
                  {renderSummarizeMenuBody()}
                </div>
              )
            )}
          </div>

          {!isPhone && <div className="w-px h-5 bg-white/10" />}

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


          {article.url && !isPhone && (
            <button
              onClick={() => { if (article.url) openUrl(article.url); }}
              className="text-text-muted hover:text-text-primary p-2 rounded-lg hover:bg-white/10 transition-colors"
              title="Open in browser"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3" />
              </svg>
            </button>
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
          <div className="rounded-xl border border-white/10" style={{ background: "rgba(255,255,255,0.03)", overflowY: "auto", display: "flex", flexDirection: "column", minHeight: 0 }}>
            <div
              className="flex items-center justify-between"
              style={{
                position: "sticky",
                top: 0,
                background: "rgba(28, 33, 40, 0.96)",
                backdropFilter: "blur(8px)",
                padding: "10px 16px",
                borderBottom: "1px solid rgba(255,255,255,0.06)",
                zIndex: 1,
              }}
            >
              <div className="text-text-muted uppercase tracking-wider font-semibold" style={{ fontSize: 11 }}>AI Summary</div>
              <button
                onClick={() => summarize.reset()}
                className="text-text-muted hover:text-text-primary transition-colors"
                style={{ padding: 4, lineHeight: 0 }}
                title="Dismiss summary"
              >
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M18 6L6 18M6 6l12 12" />
                </svg>
              </button>
            </div>
            <div style={{ padding: "12px 16px 16px" }}>
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
              <div style={{ marginTop: 12 }}>
                <AIDisclaimer />
              </div>
            </div>
          </div>
        </div>
      )}

      {summarize.isError && (() => {
        const msg = String(summarize.error instanceof Error ? summarize.error.message : summarize.error);
        const lower = msg.toLowerCase();
        const isConfigError = msg.includes("[configure-ai]") || lower.includes("no ai provider configured") || lower.includes("no local model selected") || lower.includes("go to settings");
        const isModelLoadError = lower.includes("failed to load model") || lower.includes("null result from llama");
        const isNotSignedIn = lower.includes("not signed in to claude");
        const isUnknownModel = lower.includes("not_found_error") && lower.includes("model:");
        const modelMatch = isUnknownModel ? msg.match(/"model:\s*([^"}\s]+)"?/i) : null;
        const badModel = modelMatch ? modelMatch[1] : null;
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
            ) : isNotSignedIn ? (
              <div className="rounded-xl border border-warning/30" style={{ padding: "12px 16px", fontSize: 14, background: "rgba(255, 170, 50, 0.08)" }}>
                <span className="text-warning font-medium">Not signed in to Claude. </span>
                <button onClick={() => useUiStore.getState().setShowSettings(true)} className="text-accent hover:underline">Sign in</button>
              </div>
            ) : isUnknownModel ? (
              <div className="rounded-xl border border-warning/30" style={{ padding: "12px 16px", fontSize: 14, background: "rgba(255, 170, 50, 0.08)", lineHeight: 1.5 }}>
                <div className="text-warning font-medium" style={{ marginBottom: 4 }}>
                  Model not found{badModel ? `: ${badModel}` : ""}
                </div>
                <div className="text-text-secondary">
                  Anthropic's model IDs change over time. Find the current ID at{" "}
                  <a href="https://docs.anthropic.com/en/docs/about-claude/models" target="_blank" rel="noreferrer" className="text-accent hover:underline">
                    docs.anthropic.com/models
                  </a>{" "}
                  (or use a family alias like <code className="text-accent">claude-sonnet-4-5</code>), then{" "}
                  <button onClick={() => useUiStore.getState().setShowSettings(true)} className="text-accent hover:underline">
                    paste it into Settings → AI Provider → Model
                  </button>.
                </div>
              </div>
            ) : (
              <div className="rounded-xl border border-danger/30 text-danger" style={{ padding: "12px 16px", fontSize: 14, background: "rgba(248, 81, 73, 0.1)" }}>
                {msg}
              </div>
            )}
          </div>
        );
      })()}

      {/* Single panel — toggles between reader and web view */}
      <div
        className="flex-1 min-h-0 relative overflow-hidden"
        onTouchStart={handleArticleTouchStart}
        onTouchMove={handleArticleTouchMove}
        onTouchEnd={handleArticleTouchEnd}
        onTouchCancel={handleArticleTouchEnd}
      >
        {viewMode === "reader" ? (
          <div className="h-full overflow-y-auto overflow-x-hidden" style={{ overscrollBehaviorX: "none", touchAction: "pan-y" }}>
            <div style={{ maxWidth: 720, width: "100%", margin: "0 auto", padding: isPhone ? "16px 16px 64px" : "24px 40px 80px", overflowX: "hidden" }}>
              <div style={{ marginBottom: 28 }}>
                <h1 className="text-text-primary" style={{ fontSize: 26, fontWeight: 700, lineHeight: 1.3, marginBottom: 12 }}>{article.title}</h1>
                <div className="flex items-center flex-wrap gap-x-2 gap-y-1" style={{ fontSize: 13 }}>
                  <span className="text-accent font-medium">{article.feed_title}</span>
                  {article.author && (<><span className="text-text-muted">·</span><span className="text-text-secondary">{article.author}</span></>)}
                  <span className="text-text-muted">·</span>
                  <span className="text-text-muted">{formatDate(article.published_at)}</span>
                </div>
              </div>
              {fullContent ? (
                <div className="full-article-content" dangerouslySetInnerHTML={{ __html: fullContent }} />
              ) : loadingFull ? (
                <div className="flex items-center gap-2 text-text-muted" style={{ fontSize: 14 }}>
                  <svg className="animate-spin" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M21 12a9 9 0 1 1-6.219-8.56" />
                  </svg>
                  Loading article…
                </div>
              ) : rssHtml ? (
                <div className="article-content text-text-primary" dangerouslySetInnerHTML={{ __html: rssHtml }} />
              ) : article.content_text ? (
                <div className="article-content text-text-primary whitespace-pre-wrap">{article.content_text}</div>
              ) : (
                <p className="text-text-muted" style={{ fontSize: 14 }}>No preview available.</p>
              )}
            </div>
          </div>
        ) : (
          <div className="h-full relative">
            {article.url && (
              <button
                onClick={() => { if (article.url) openUrl(article.url); }}
                className="absolute bg-bg-secondary/90 hover:bg-bg-secondary border border-white/15 text-text-primary backdrop-blur-md rounded-full shadow-lg transition-colors flex items-center justify-center z-10"
                style={{ bottom: 16, right: 16, width: 40, height: 40 }}
                title="Open original in external browser"
                aria-label="Open in browser"
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3" />
                </svg>
              </button>
            )}
            {loadingFull && !rawHtml && (
              <div className="absolute inset-0 flex flex-col items-center justify-center text-center" style={{ padding: "0 24px" }}>
                <svg className="animate-spin text-text-muted" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ marginBottom: 12 }}>
                  <path d="M21 12a9 9 0 1 1-6.219-8.56" />
                </svg>
                <p className="text-text-muted" style={{ fontSize: 14 }}>
                  Loading web view...
                </p>
              </div>
            )}
            {!rawHtml && !loadingFull && (
              <div className="flex flex-col items-center justify-center h-full text-center" style={{ padding: "0 24px" }}>
                <p className="text-text-muted" style={{ fontSize: 14, marginBottom: 8 }}>
                  {fullError ? "Couldn't load page in the embedded view." : "No embedded page preview is available."}
                </p>
                <p className="text-text-muted" style={{ fontSize: 12 }}>
                  Use the "Open in browser" button.
                </p>
              </div>
            )}
            {rawHtml && (
              <iframe
                key={`${article.id}:${article.url}`}
                ref={iframeRef}
                srcDoc={rawHtml.replace(
                  /(<head[^>]*>)/i,
                  `$1<meta name="color-scheme" content="dark"><style>${EMBEDDED_WEB_VIEW_CSS}</style>`
                )}
                sandbox="allow-scripts allow-popups allow-forms allow-modals allow-pointer-lock allow-presentation"
                style={{ width: "100%", height: "100%", border: "none", background: "#1a1a1a", overflow: "hidden" }}
                title="Article web view"
                onLoad={() => {
                  try {
                    const win = iframeRef.current?.contentWindow;
                    if (!win) return;
                    const s = win.document.createElement("style");
                    s.textContent = EMBEDDED_WEB_VIEW_CSS;
                    win.document.head.appendChild(s);
                    win.document.addEventListener("contextmenu", (e: Event) => e.preventDefault());
                    win.addEventListener("keydown", ((e: KeyboardEvent) => {
                      if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
                        e.preventDefault();
                        window.dispatchEvent(new KeyboardEvent("keydown", { key: e.key }));
                      }
                    }) as EventListener);
                  } catch { /* cross-origin */ }
                }}
              />
            )}
          </div>
        )}
      </div>

      {/* Chat drawer — collapsible bottom pane */}
      <ChatDrawer articleId={article.id} articleTitle={article.title} />
    </div>
  );
}
