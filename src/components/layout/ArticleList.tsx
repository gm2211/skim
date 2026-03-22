import { useMemo, useState } from "react";
import { useArticles, useMarkAllRead } from "../../hooks/useArticles";
import { useThemes } from "../../hooks/useThemes";
import { useUiStore } from "../../stores/uiStore";
import { ArticleCard } from "../article/ArticleCard";
import type { ArticleFilter } from "../../services/types";

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
  const { sidebarView, selectedArticleId, setSelectedArticleId, listFilter, setListFilter } = useUiStore();
  const markAllRead = useMarkAllRead();
  const [searchQuery, setSearchQuery] = useState("");

  const filter: ArticleFilter = useMemo(() => {
    const base: ArticleFilter = { limit: 200 };
    switch (sidebarView.type) {
      case "all":
        break;
      case "starred":
        base.is_starred = true;
        break;
      case "feed":
        base.feed_id = sidebarView.feedId;
        break;
      case "theme":
        base.theme_id = sidebarView.themeId;
        break;
    }
    if (listFilter === "unread") base.is_read = false;
    if (listFilter === "starred") base.is_starred = true;
    return base;
  }, [sidebarView, listFilter]);

  const { data: articles, isLoading } = useArticles(filter);
  const { data: themes } = useThemes();

  const currentTheme = useMemo(() => {
    if (sidebarView.type !== "theme") return null;
    return themes?.find((t) => t.id === sidebarView.themeId);
  }, [sidebarView, themes]);

  const title = useMemo(() => {
    switch (sidebarView.type) {
      case "all":
        return "All Articles";
      case "starred":
        return "Starred";
      case "feed":
        return null;
      case "theme":
        return currentTheme?.label ?? "Theme";
    }
  }, [sidebarView, currentTheme]);

  const feedTitle = useMemo(() => {
    if (sidebarView.type === "feed" && articles && articles.length > 0) {
      return articles[0].feed_title;
    }
    return null;
  }, [sidebarView, articles]);

  const filteredArticles = useMemo(() => {
    if (!articles || !searchQuery.trim()) return articles;
    const q = searchQuery.toLowerCase();
    return articles.filter(
      (a) =>
        a.title.toLowerCase().includes(q) ||
        a.feed_title?.toLowerCase().includes(q) ||
        a.content_text?.toLowerCase().includes(q)
    );
  }, [articles, searchQuery]);

  const unreadCount = useMemo(() => {
    return articles?.filter((a) => !a.is_read).length ?? 0;
  }, [articles]);

  const dateGroups = useMemo(() => {
    if (!filteredArticles) return [];
    return groupByDate(filteredArticles);
  }, [filteredArticles]);

  const handleMarkAllRead = () => {
    const feedId = sidebarView.type === "feed" ? sidebarView.feedId : null;
    markAllRead.mutate(feedId);
  };

  const displayTitle = title ?? feedTitle ?? "Articles";

  return (
    <div className="w-96 min-w-80 border-r border-white/5 bg-bg-secondary/70 flex flex-col h-full">
      {/* Top bar with mark-all-read, search, close */}
      <div className="flex items-center justify-end gap-2 relative z-20" style={{ height: 40, paddingRight: 16 }}>
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
      </div>

      {/* Theme summary */}
      {currentTheme?.summary && (
        <div style={{ padding: "4px 20px 8px" }}>
          <div className="rounded-lg bg-white/5" style={{ padding: "10px 12px" }}>
            <p className="text-text-secondary leading-relaxed" style={{ fontSize: 12 }}>
              {currentTheme.summary}
            </p>
          </div>
        </div>
      )}

      {/* Article list */}
      <div className="flex-1 overflow-y-auto">
        {isLoading ? (
          <div className="flex items-center justify-center h-32">
            <span className="text-text-muted" style={{ fontSize: 14 }}>Loading...</span>
          </div>
        ) : filteredArticles && filteredArticles.length > 0 ? (
          dateGroups.map((group) => (
            <div key={group.label}>
              <div
                className="text-text-muted uppercase tracking-wider font-semibold"
                style={{ fontSize: 11, padding: "16px 24px 8px" }}
              >
                {group.label}
              </div>
              {group.indices.map((i) => {
                const article = filteredArticles[i];
                return (
                  <ArticleCard
                    key={article.id}
                    article={article}
                    isSelected={selectedArticleId === article.id}
                    onSelect={() => setSelectedArticleId(article.id)}
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

      {/* Bottom filter toolbar */}
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
    </div>
  );
}
