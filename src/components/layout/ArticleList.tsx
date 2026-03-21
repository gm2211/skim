import { useMemo } from "react";
import { useArticles, useMarkAllRead } from "../../hooks/useArticles";
import { useThemes } from "../../hooks/useThemes";
import { useUiStore } from "../../stores/uiStore";
import { ArticleCard } from "../article/ArticleCard";
import type { ArticleFilter } from "../../services/types";

export function ArticleList() {
  const { sidebarView, selectedArticleId, setSelectedArticleId } = useUiStore();
  const markAllRead = useMarkAllRead();

  const filter: ArticleFilter = useMemo(() => {
    switch (sidebarView.type) {
      case "all":
        return { is_read: null, limit: 200 };
      case "starred":
        return { is_starred: true, limit: 200 };
      case "feed":
        return { feed_id: sidebarView.feedId, limit: 200 };
      case "theme":
        return { theme_id: sidebarView.themeId, limit: 200 };
    }
  }, [sidebarView]);

  const { data: articles, isLoading } = useArticles(filter);
  const { data: themes } = useThemes();

  // Get theme info if viewing a theme
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
        return null; // Will show feed name from articles
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

  const handleMarkAllRead = () => {
    const feedId = sidebarView.type === "feed" ? sidebarView.feedId : null;
    markAllRead.mutate(feedId);
  };

  return (
    <div className="w-80 min-w-72 max-w-96 border-r border-border bg-bg-secondary flex flex-col h-full">
      {/* Header */}
      <div className="px-3 py-2.5 border-b border-border-light flex items-center justify-between">
        <h2 className="font-semibold text-sm truncate">
          {title ?? feedTitle ?? "Articles"}
        </h2>
        <button
          onClick={handleMarkAllRead}
          className="text-xs text-text-muted hover:text-text-primary"
          title="Mark all as read"
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M20 6L9 17l-5-5" />
          </svg>
        </button>
      </div>

      {/* Theme summary */}
      {currentTheme?.summary && (
        <div className="px-3 py-2.5 border-b border-border-light bg-bg-tertiary">
          <p className="text-xs text-text-secondary leading-relaxed">
            {currentTheme.summary}
          </p>
        </div>
      )}

      {/* Article list */}
      <div className="flex-1 overflow-y-auto">
        {isLoading ? (
          <div className="flex items-center justify-center h-32">
            <span className="text-sm text-text-muted">Loading...</span>
          </div>
        ) : articles && articles.length > 0 ? (
          articles.map((article) => (
            <ArticleCard
              key={article.id}
              article={article}
              isSelected={selectedArticleId === article.id}
              onSelect={() => setSelectedArticleId(article.id)}
            />
          ))
        ) : (
          <div className="flex items-center justify-center h-32">
            <span className="text-sm text-text-muted">No articles</span>
          </div>
        )}
      </div>
    </div>
  );
}
