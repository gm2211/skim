import { useEffect, useState, useCallback, useRef } from "react";
import { useArticle, useMarkRead, useToggleStar, useToggleRead } from "../../hooks/useArticles";
import { useSummarizeArticle } from "../../hooks/useAi";
import { useUiStore } from "../../stores/uiStore";
import { fetchFullArticle } from "../../services/commands";

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
  const { selectedArticleId, setSelectedArticleId } = useUiStore();
  const { data: article } = useArticle(selectedArticleId);
  const markRead = useMarkRead();
  const toggleStar = useToggleStar();
  const toggleRead = useToggleRead();
  const summarize = useSummarizeArticle();
  const [fullContent, setFullContent] = useState<string | null>(null);
  const [rawHtml, setRawHtml] = useState<string | null>(null);
  const [loadingFull, setLoadingFull] = useState(false);
  const [fullError, setFullError] = useState<string | null>(null);
  const [viewMode, setViewMode] = useState<ViewMode>("rss");
  const prismRef = useRef<HTMLDivElement>(null);
  const [prismZ, setPrismZ] = useState(200);

  // Reset state when article changes
  useEffect(() => {
    setFullContent(null);
    setRawHtml(null);
    setFullError(null);
    setViewMode("rss");
  }, [selectedArticleId]);

  // Calculate prism depth from container width (Y-axis rotation)
  useEffect(() => {
    if (!prismRef.current) return;
    const observer = new ResizeObserver((entries) => {
      const w = entries[0]?.contentRect.width ?? 600;
      setPrismZ(w / (2 * Math.tan(Math.PI / 3)));
    });
    observer.observe(prismRef.current);
    return () => observer.disconnect();
  }, []);

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
    if (viewMode === "reader") {
      setViewMode("rss");
      return;
    }
    await fetchFull();
    setViewMode("reader");
  }, [viewMode, fetchFull]);

  const handleWebView = useCallback(async () => {
    if (viewMode === "web") {
      setViewMode("rss");
      return;
    }
    await fetchFull();
    setViewMode("web");
  }, [viewMode, fetchFull]);

  // Arrow key navigation: right cycles rss→reader→web, left goes back
  useEffect(() => {
    if (!article?.url) return;
    const handler = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      if (e.key === "ArrowRight") {
        if (viewMode === "rss") handleReader();
        else if (viewMode === "reader") handleWebView();
      } else if (e.key === "ArrowLeft") {
        if (viewMode === "web") handleReader();
        else if (viewMode === "reader") setViewMode("rss");
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [article?.url, viewMode, handleReader, handleWebView]);

  if (!article) {
    return (
      <div className="flex-1 flex items-center justify-center bg-bg-primary/60">
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

  const modeBtn = (mode: ViewMode, label: string, icon: JSX.Element) => (
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
      {loadingFull && viewMode !== mode ? null : icon}
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
        <button
          onClick={() => setSelectedArticleId(null)}
          className="text-text-muted hover:text-text-primary p-2 rounded-lg hover:bg-white/10 transition-colors"
          title="Close"
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M19 12H5M12 19l-7-7 7-7" />
          </svg>
        </button>

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

          <button
            onClick={() => summarize.mutate(article.id)}
            disabled={summarize.isPending}
            className="rounded-lg border border-white/10 text-text-secondary hover:text-text-primary hover:border-white/20 transition-colors disabled:opacity-40"
            style={{ padding: "6px 12px", fontSize: 12 }}
          >
            {summarize.isPending ? "..." : "Summarize"}
          </button>

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

      {/* Triangular prism — 3 faces rotating on X-axis */}
      <div
        ref={prismRef}
        className="prism-container"
        style={{ "--prism-z": `${prismZ}px` } as React.CSSProperties}
      >
        <div
          className="prism-inner"
          data-face={viewMode === "rss" ? "0" : viewMode === "reader" ? "1" : "2"}
        >
          {/* Face 0: RSS preview */}
          <div className="prism-face prism-face-0">
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

              {summarize.data && (
                <div className="rounded-xl border border-white/10" style={{ padding: "20px", marginBottom: 28, background: "rgba(255,255,255,0.03)" }}>
                  <div className="text-text-muted uppercase tracking-wider font-semibold" style={{ fontSize: 11, marginBottom: 10 }}>AI Summary</div>
                  {summarize.data.bullet_summary && (
                    <div className="text-text-primary whitespace-pre-wrap" style={{ fontSize: 14, marginBottom: 12, lineHeight: 1.6 }}>{summarize.data.bullet_summary}</div>
                  )}
                  {summarize.data.full_summary && (
                    <div className="text-text-secondary leading-relaxed" style={{ fontSize: 14 }}>{summarize.data.full_summary}</div>
                  )}
                </div>
              )}

              {summarize.isError && (
                <div className="rounded-xl border border-danger/30 text-danger" style={{ padding: "12px 16px", marginBottom: 28, fontSize: 14, background: "rgba(248, 81, 73, 0.1)" }}>
                  {String(summarize.error instanceof Error ? summarize.error.message : summarize.error)}
                </div>
              )}

              {rssHtml ? (
                <div className="article-content text-text-primary" dangerouslySetInnerHTML={{ __html: rssHtml }} />
              ) : article.content_text ? (
                <div className="article-content text-text-primary whitespace-pre-wrap">{article.content_text}</div>
              ) : (
                <p className="text-text-muted" style={{ fontSize: 14 }}>No preview available.</p>
              )}
            </div>
          </div>

          {/* Face 1: Reader mode */}
          <div className="prism-face prism-face-1">
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

          {/* Face 2: Web view */}
          <div className="prism-face prism-face-2">
            {rawHtml && (
              <iframe
                srcDoc={rawHtml}
                sandbox="allow-same-origin"
                style={{ width: "100%", height: "100%", border: "none", background: "white" }}
                title="Article web view"
              />
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
