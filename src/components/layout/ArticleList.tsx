import { useMemo, useState, useCallback, useEffect, useRef } from "react";
import { useArticles, useArticleCount, useMarkAllRead, useMarkRead, useMarkUnread, useToggleRead, useToggleStar } from "../../hooks/useArticles";
import { useInboxArticles } from "../../hooks/useInbox";
import { useThemes, useArticleThemeTags } from "../../hooks/useThemes";
import { useRecentArticles, useReadMatchCount, useRemoveRecent } from "../../hooks/useRecent";
import { useUiStore } from "../../stores/uiStore";
import { ArticleCard } from "../article/ArticleCard";
import { ArticleContextMenu } from "../article/ArticleContextMenu";
import type { ArticleFilter, ArticleWithTriage, ArticleWithInteraction } from "../../services/types";

const PRIORITY_GROUP_LABELS: Record<number, string> = {
  5: "MUST READ",
  4: "IMPORTANT",
  3: "WORTH READING",
  2: "ROUTINE",
  1: "SKIP",
};

function groupByPriority(articles: ArticleWithTriage[]) {
  const groups: { label: string; indices: number[] }[] = [];
  let currentKey: string | number = "";

  articles.forEach((article, i) => {
    const key: string | number = article.priority ?? "unscored";
    if (key !== currentKey) {
      const label =
        key === "unscored"
          ? "NOT YET SCORED"
          : PRIORITY_GROUP_LABELS[key as number] ?? `PRIORITY ${key}`;
      groups.push({ label, indices: [] });
      currentKey = key;
    }
    groups[groups.length - 1].indices.push(i);
  });

  return groups;
}

function groupByDate(articles: { published_at: number | null; fetched_at: number }[]) {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const yesterday = new Date(today.getTime() - 86400000);

  const groups: { label: string; indices: number[] }[] = [];
  let currentLabel = "";

  articles.forEach((article, i) => {
    const ts = (article.published_at ?? article.fetched_at) * 1000;
    const date = new Date(ts);
    let label: string;

    if (date >= today) {
      label = "Today";
    } else if (date >= yesterday) {
      label = "Yesterday";
    } else {
      label = date.toLocaleDateString("en-US", {
        weekday: "long",
        month: "long",
        day: "numeric",
        year: date.getFullYear() !== now.getFullYear() ? "numeric" : undefined,
      }).toUpperCase();
    }

    if (label !== currentLabel) {
      groups.push({ label, indices: [] });
      currentLabel = label;
    }
    groups[groups.length - 1].indices.push(i);
  });

  return groups;
}

export function ArticleList() {
  const { sidebarView, selectedArticleId, setSelectedArticleId, listFilter, setListFilter, sidebarCollapsed, listCollapsed } = useUiStore();
  const markAllRead = useMarkAllRead();
  const markRead = useMarkRead();
  const markUnread = useMarkUnread();
  const toggleRead = useToggleRead();
  const toggleStar = useToggleStar();
  const removeRecent = useRemoveRecent();
  const [searchQuery, setSearchQuery] = useState("");
  const [contextMenu, setContextMenu] = useState<{
    x: number;
    y: number;
    articleIndex: number;
  } | null>(null);

  const isInbox = sidebarView.type === "inbox";
  const isRecent = sidebarView.type === "recent";
  const [recentOrder, setRecentOrder] = useState<"engagement" | "recency">("engagement");
  const { data: themes } = useThemes();
  const { data: themeTags } = useArticleThemeTags();
  const [activeThemeId, setActiveThemeId] = useState<string | null>(null);

  // Map of articleId → [{themeId, label}]
  const themeTagsByArticle = useMemo(() => {
    const map = new Map<string, { themeId: string; label: string }[]>();
    for (const tag of themeTags ?? []) {
      const existing = map.get(tag.article_id) ?? [];
      existing.push({ themeId: tag.theme_id, label: tag.theme_label });
      map.set(tag.article_id, existing);
    }
    return map;
  }, [themeTags]);

  // Infinite scroll: grows in PAGE_SIZE steps when user scrolls near the
  // bottom. Reset whenever the view or filter changes.
  const PAGE_SIZE = 200;
  const [pageLimit, setPageLimit] = useState(PAGE_SIZE);
  useEffect(() => {
    setPageLimit(PAGE_SIZE);
  }, [sidebarView, listFilter]);

  const filter: ArticleFilter = useMemo(() => {
    const base: ArticleFilter = { limit: pageLimit };
    switch (sidebarView.type) {
      case "all":
        break;
      case "starred":
        base.is_starred = true;
        break;
      case "feed":
        base.feed_id = sidebarView.feedId;
        break;
      case "inbox":
        break; // handled by separate query
      case "theme":
        base.theme_id = sidebarView.themeId;
        break;
    }
    if (listFilter === "unread") base.is_read = false;
    if (listFilter === "starred") base.is_starred = true;
    return base;
  }, [sidebarView, listFilter, pageLimit]);

  const { data: regularArticles, isLoading: regularLoading } = useArticles(filter);
  // AI Inbox is unread-only by design — ignore listFilter entirely.
  const inboxIsRead = isInbox ? false : null;
  const { data: inboxArticles, isLoading: inboxLoading } = useInboxArticles(
    isInbox ? undefined : -1, // -1 disables the query when not in inbox view
    inboxIsRead
  );
  const { data: recentArticlesRaw, isLoading: recentLoading } = useRecentArticles(recentOrder);
  const recentArticles = useMemo(
    () => (isRecent ? (recentArticlesRaw as ArticleWithInteraction[] | undefined) : undefined),
    [isRecent, recentArticlesRaw],
  );

  const { data: readMatchCount } = useReadMatchCount(searchQuery);
  const [includeRead, setIncludeRead] = useState(false);

  const rawArticles = isInbox ? inboxArticles : isRecent ? recentArticles : regularArticles;
  const isLoading = isInbox ? inboxLoading : isRecent ? recentLoading : regularLoading;

  // Sticky selection: keep articles the user has clicked visible in the list
  // even after they get marked read and the unread-only query drops them on
  // refetch. Without this, clicking an unread article makes it vanish
  // immediately. Reset whenever the view or filter changes.
  const stickyMapRef = useRef<Map<string, any>>(new Map());
  const stickyIdsRef = useRef<Set<string>>(new Set());
  useEffect(() => {
    stickyMapRef.current = new Map();
    stickyIdsRef.current = new Set();
  }, [sidebarView, listFilter]);
  useEffect(() => {
    if (selectedArticleId) stickyIdsRef.current.add(selectedArticleId);
  }, [selectedArticleId]);
  if (rawArticles) {
    for (const a of rawArticles) stickyMapRef.current.set(a.id, a);
  }

  const articles = useMemo(() => {
    if (!rawArticles) return rawArticles;
    const have = new Set(rawArticles.map((a) => a.id));
    const injected: any[] = [];
    for (const id of stickyIdsRef.current) {
      if (!have.has(id)) {
        const cached = stickyMapRef.current.get(id);
        if (cached) injected.push(cached);
      }
    }
    if (injected.length === 0) return rawArticles;
    const combined = [...(rawArticles as any[]), ...injected];
    if (isInbox) {
      combined.sort((a, b) => {
        const pa = a.priority ?? -1;
        const pb = b.priority ?? -1;
        if (pa !== pb) return pb - pa;
        return (b.published_at ?? b.fetched_at) - (a.published_at ?? a.fetched_at);
      });
    } else {
      combined.sort(
        (a, b) => (b.published_at ?? b.fetched_at) - (a.published_at ?? a.fetched_at),
      );
    }
    return combined as typeof rawArticles;
  }, [rawArticles, isInbox, selectedArticleId]);

  const title = useMemo(() => {
    switch (sidebarView.type) {
      case "all":
        return "All Articles";
      case "starred":
        return "Starred";
      case "feed":
        return null;
      case "inbox":
        return "AI Inbox";
      case "recent":
        return "Recently Read";
      case "theme": {
        const theme = themes?.find((t) => t.id === sidebarView.themeId);
        return theme?.label ?? "Theme";
      }
    }
  }, [sidebarView, themes]);

  const feedTitle = useMemo(() => {
    if (sidebarView.type === "feed" && articles && articles.length > 0) {
      return articles[0].feed_title;
    }
    return null;
  }, [sidebarView, articles]);

  const filteredArticles = useMemo(() => {
    if (!articles) return articles;
    let result = articles;
    // Theme tab filter (inbox only)
    if (isInbox && activeThemeId) {
      result = result.filter((a) =>
        (themeTagsByArticle.get(a.id) ?? []).some((t) => t.themeId === activeThemeId),
      );
    }
    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase();
      result = result.filter((a) => {
        const hay =
          a.title.toLowerCase() +
          " " +
          (a.feed_title?.toLowerCase() ?? "") +
          " " +
          (a.content_text?.toLowerCase() ?? "");
        if (!hay.includes(q)) return false;
        // If searching in a filter that normally hides read articles,
        // require includeRead toggle before surfacing read matches.
        if (!includeRead && listFilter === "unread" && a.is_read) return false;
        return true;
      });
    }
    return result;
  }, [articles, searchQuery, isInbox, listFilter, activeThemeId, themeTagsByArticle, includeRead]);

  // True unread total for the active filter — the paged articles array is
  // capped at 200 so counting locally understates everything above that.
  const unreadFilter: ArticleFilter = useMemo(() => ({ ...filter, is_read: false, limit: null }), [filter]);
  const { data: regularUnreadCount } = useArticleCount(
    unreadFilter,
    !isInbox && !isRecent,
  );
  const unreadCount = useMemo(() => {
    if (isInbox || isRecent) {
      return articles?.filter((a) => !a.is_read).length ?? 0;
    }
    return regularUnreadCount ?? 0;
  }, [articles, isInbox, isRecent, regularUnreadCount]);

  const articleGroups = useMemo(() => {
    if (!filteredArticles) return [];
    if (isInbox) return groupByPriority(filteredArticles as ArticleWithTriage[]);
    if (isRecent && recentOrder === "engagement") {
      return [{ label: "MOST ENGAGED", indices: filteredArticles.map((_, i) => i) }];
    }
    return groupByDate(filteredArticles);
  }, [filteredArticles, isInbox, isRecent, recentOrder]);

  const handleMarkAllRead = () => {
    const feedId = sidebarView.type === "feed" ? sidebarView.feedId : null;
    markAllRead.mutate(feedId);
  };

  const displayTitle = title ?? feedTitle ?? "Articles";

  const handleArticleContextMenu = useCallback(
    (e: React.MouseEvent, index: number) => {
      e.preventDefault();
      setContextMenu({ x: e.clientX, y: e.clientY, articleIndex: index });
    },
    []
  );

  const contextArticle = contextMenu && filteredArticles
    ? filteredArticles[contextMenu.articleIndex]
    : null;

  // Infinite scroll: grow pageLimit when the user nears the bottom of the
  // list. Only applies to the paged (regular) query; inbox/recent queries
  // have their own server-side caps.
  const scrollRef = useRef<HTMLDivElement>(null);
  const canPaginate = !isInbox && !isRecent;
  const handleScroll = useCallback(() => {
    if (!canPaginate) return;
    const el = scrollRef.current;
    if (!el) return;
    const nearBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 400;
    const pageFull = (regularArticles?.length ?? 0) >= pageLimit;
    if (nearBottom && pageFull) {
      setPageLimit((n) => n + PAGE_SIZE);
    }
  }, [canPaginate, regularArticles, pageLimit]);

  return (
    <div
      className={`${listCollapsed ? '' : 'border-r border-white/5'} bg-bg-secondary/70 flex flex-col h-full overflow-hidden transition-all duration-300 ease-in-out`}
      style={{ width: listCollapsed ? 0 : 384, minWidth: listCollapsed ? 0 : 320 }}
    >
      {/* Top bar with mark-all-read, search, close */}
      <div className="flex items-center justify-end gap-2 relative z-20" style={{ height: 40, paddingLeft: sidebarCollapsed ? 78 : undefined, paddingRight: 16 }}>
        {sidebarCollapsed && (
          <button
            onClick={() => useUiStore.getState().toggleSidebar()}
            className="text-text-muted hover:text-text-primary transition-colors mr-auto"
            title="Expand sidebar"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <rect x="3" y="3" width="18" height="18" rx="2" />
              <path d="M9 3v18" />
            </svg>
          </button>
        )}
        <button
          onClick={handleMarkAllRead}
          className="text-text-muted hover:text-text-primary transition-colors"
          title="Mark all as read"
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14" />
            <polyline points="22 4 12 14.01 9 11.01" />
          </svg>
        </button>
        <button
          onClick={() => {
            const input = document.getElementById("article-search");
            if (input) input.focus();
          }}
          className="text-text-muted hover:text-text-primary transition-colors"
          title="Search"
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <circle cx="11" cy="11" r="8" />
            <line x1="21" y1="21" x2="16.65" y2="16.65" />
          </svg>
        </button>
      </div>

      {/* Title + unread count */}
      <div style={{ padding: "8px 24px 4px" }}>
        <h2 style={{ fontSize: 22, fontWeight: 700 }} className="text-text-primary truncate">
          {displayTitle}
        </h2>
        {unreadCount > 0 && (
          <p className="text-text-muted" style={{ fontSize: 13, marginTop: 2 }}>
            {unreadCount} Unread Item{unreadCount !== 1 ? "s" : ""}
          </p>
        )}
      </div>

      {/* Search box */}
      <div style={{ padding: "12px 20px 8px" }}>
        <div className="relative">
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            className="absolute text-text-muted"
            style={{ left: 12, top: 11 }}
          >
            <circle cx="11" cy="11" r="8" />
            <line x1="21" y1="21" x2="16.65" y2="16.65" />
          </svg>
          <input
            id="article-search"
            type="text"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            placeholder="Search articles..."
            className="w-full border border-white/10 rounded-lg text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/40 transition-colors"
            style={{
              background: "rgba(255, 255, 255, 0.05)",
              padding: "8px 12px 8px 34px",
              fontSize: 13,
            }}
          />
        </div>
        {searchQuery.trim().length >= 2 &&
          listFilter === "unread" &&
          (readMatchCount ?? 0) > 0 && (
            <div className="flex items-center gap-2" style={{ marginTop: 6 }}>
              <span className="text-text-muted" style={{ fontSize: 12 }}>
                {readMatchCount} match{readMatchCount === 1 ? "" : "es"} in already-read articles
              </span>
              <button
                onClick={() => setIncludeRead((v) => !v)}
                className="text-accent hover:text-accent-hover transition-colors"
                style={{ fontSize: 12, fontWeight: 500 }}
              >
                {includeRead ? "Hide read results" : "Show them"}
              </button>
            </div>
          )}
      </div>

      {/* Recent sort toggle */}
      {isRecent && (
        <div
          className="flex items-center gap-2 border-b border-white/5"
          style={{ padding: "8px 24px" }}
        >
          <span className="text-text-muted" style={{ fontSize: 12 }}>Sort:</span>
          {(["engagement", "recency"] as const).map((o) => (
            <button
              key={o}
              onClick={() => setRecentOrder(o)}
              className={`rounded-full transition-colors ${
                recentOrder === o
                  ? "bg-accent/20 text-accent"
                  : "bg-white/5 text-text-secondary hover:bg-white/10 hover:text-text-primary"
              }`}
              style={{ padding: "4px 12px", fontSize: 12, fontWeight: 500 }}
            >
              {o === "engagement" ? "Engagement" : "Recency"}
            </button>
          ))}
        </div>
      )}

      {/* Theme tabs — only in AI Inbox */}
      {isInbox && themes && themes.length > 0 && (
        <div
          className="flex items-center gap-2 border-b border-white/5 overflow-x-auto"
          style={{ padding: "8px 24px" }}
        >
          <button
            onClick={() => setActiveThemeId(null)}
            className={`rounded-full transition-colors whitespace-nowrap ${
              activeThemeId === null
                ? "bg-accent/20 text-accent"
                : "bg-white/5 text-text-secondary hover:bg-white/10 hover:text-text-primary"
            }`}
            style={{ padding: "4px 12px", fontSize: 12, fontWeight: 500 }}
          >
            All
          </button>
          {themes.map((t) => (
            <button
              key={t.id}
              onClick={() => setActiveThemeId(t.id === activeThemeId ? null : t.id)}
              title={t.summary ?? undefined}
              className={`rounded-full transition-colors whitespace-nowrap flex items-center gap-1.5 ${
                activeThemeId === t.id
                  ? "bg-accent/20 text-accent"
                  : "bg-white/5 text-text-secondary hover:bg-white/10 hover:text-text-primary"
              }`}
              style={{ padding: "4px 12px", fontSize: 12 }}
            >
              <span>{t.label}</span>
              {t.article_count != null && (
                <span className="text-text-muted tabular-nums" style={{ fontSize: 11 }}>
                  {t.article_count}
                </span>
              )}
            </button>
          ))}
        </div>
      )}

      {/* Article list */}
      <div ref={scrollRef} onScroll={handleScroll} className="flex-1 overflow-y-auto">
        {isLoading ? (
          <div className="flex items-center justify-center h-32">
            <span className="text-text-muted" style={{ fontSize: 14 }}>Loading...</span>
          </div>
        ) : filteredArticles && filteredArticles.length > 0 ? (
          articleGroups.map((group) => (
            <div key={group.label}>
              <div
                className="text-text-muted uppercase tracking-wider font-semibold"
                style={{ fontSize: 11, padding: "16px 24px 8px" }}
              >
                {group.label}
              </div>
              {group.indices.map((i) => {
                const article = filteredArticles[i];
                const triageData = isInbox ? {
                  priority: (article as ArticleWithTriage).priority ?? 3,
                  reason: (article as ArticleWithTriage).reason ?? "",
                } : null;
                return (
                  <ArticleCard
                    key={article.id}
                    article={article}
                    triage={triageData}
                    themeTags={isInbox ? themeTagsByArticle.get(article.id) : undefined}
                    isSelected={selectedArticleId === article.id}
                    onSelect={() => setSelectedArticleId(article.id)}
                    onContextMenu={(e) => handleArticleContextMenu(e, i)}
                  />
                );
              })}
            </div>
          ))
        ) : (
          <div className="flex flex-col items-center justify-center h-48 px-6">
            <svg
              width="32"
              height="32"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              className="text-text-muted mb-3 opacity-40"
            >
              <path d="M19 20H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v1m2 13a2 2 0 0 1-2-2V9a2 2 0 0 0-2-2h-1" />
            </svg>
            <span className="text-text-muted" style={{ fontSize: 13 }}>No articles</span>
          </div>
        )}
      </div>

      {contextMenu && contextArticle && filteredArticles && (
        <ArticleContextMenu
          x={contextMenu.x}
          y={contextMenu.y}
          article={contextArticle}
          onClose={() => setContextMenu(null)}
          onToggleRead={() => toggleRead.mutate(contextArticle.id)}
          onToggleStar={() => toggleStar.mutate(contextArticle.id)}
          onMarkAboveRead={() => {
            const ids = filteredArticles
              .slice(0, contextMenu.articleIndex)
              .filter((a) => !a.is_read)
              .map((a) => a.id);
            if (ids.length > 0) markRead.mutate(ids);
          }}
          onMarkBelowRead={() => {
            const ids = filteredArticles
              .slice(contextMenu.articleIndex + 1)
              .filter((a) => !a.is_read)
              .map((a) => a.id);
            if (ids.length > 0) markRead.mutate(ids);
          }}
          onMarkAboveUnread={() => {
            const ids = filteredArticles
              .slice(0, contextMenu.articleIndex)
              .filter((a) => a.is_read)
              .map((a) => a.id);
            if (ids.length > 0) markUnread.mutate(ids);
          }}
          onMarkBelowUnread={() => {
            const ids = filteredArticles
              .slice(contextMenu.articleIndex + 1)
              .filter((a) => a.is_read)
              .map((a) => a.id);
            if (ids.length > 0) markUnread.mutate(ids);
          }}
          onCopyLink={() => {
            if (contextArticle.url) navigator.clipboard.writeText(contextArticle.url);
          }}
          onRemoveFromRecent={
            isRecent ? () => removeRecent.mutate(contextArticle.id) : undefined
          }
        />
      )}

      {/* Bottom filter toolbar — hidden in AI Inbox (unread-only by design) */}
      {!isInbox && (
      <div
        className="flex items-center justify-center gap-6 border-t border-white/5"
        style={{ padding: "12px 16px" }}
      >
        <button
          onClick={() => setListFilter("starred")}
          className={`p-2 rounded-md transition-colors ${
            listFilter === "starred" ? "text-warning" : "text-text-muted hover:text-text-primary"
          }`}
          title="Starred"
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill={listFilter === "starred" ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2">
            <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
          </svg>
        </button>
        <button
          onClick={() => setListFilter("unread")}
          className={`p-2 rounded-md transition-colors ${
            listFilter === "unread" ? "text-accent" : "text-text-muted hover:text-text-primary"
          }`}
          title="Unread only"
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" stroke="none">
            <circle cx="12" cy="12" r={listFilter === "unread" ? 6 : 5} />
          </svg>
        </button>
        <button
          onClick={() => setListFilter("all")}
          className={`flex items-center gap-1.5 p-2 rounded-md transition-colors ${
            listFilter === "all" ? "text-text-primary" : "text-text-muted hover:text-text-primary"
          }`}
          title="All articles"
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <line x1="8" y1="6" x2="21" y2="6" />
            <line x1="8" y1="12" x2="21" y2="12" />
            <line x1="8" y1="18" x2="21" y2="18" />
            <line x1="3" y1="6" x2="3.01" y2="6" />
            <line x1="3" y1="12" x2="3.01" y2="12" />
            <line x1="3" y1="18" x2="3.01" y2="18" />
          </svg>
          <span style={{ fontSize: 12, fontWeight: 600 }}>ALL</span>
        </button>
      </div>
      )}
    </div>
  );
}
