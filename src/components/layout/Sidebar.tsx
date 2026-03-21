import { useFeeds, useRefreshAllFeeds } from "../../hooks/useFeeds";
import { useThemes, useGenerateThemes } from "../../hooks/useThemes";
import { useUiStore } from "../../stores/uiStore";
import type { SidebarView } from "../../services/types";

export function Sidebar() {
  const { sidebarView, setSidebarView, setShowAddFeed, setShowSettings, sidebarCollapsed } =
    useUiStore();
  const { data: feeds } = useFeeds();
  const { data: themes } = useThemes();
  const refreshAll = useRefreshAllFeeds();
  const generateThemes = useGenerateThemes();

  const totalUnread = feeds?.reduce((sum, f) => sum + f.unread_count, 0) ?? 0;

  if (sidebarCollapsed) {
    return (
      <div className="w-12 border-r border-border bg-bg-secondary flex flex-col items-center pt-3">
        <button
          onClick={() => useUiStore.getState().toggleSidebar()}
          className="text-text-secondary hover:text-text-primary p-1"
          title="Expand sidebar"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M9 18l6-6-6-6" />
          </svg>
        </button>
      </div>
    );
  }

  const isActive = (view: SidebarView) => {
    if (view.type === sidebarView.type) {
      if (view.type === "feed" && sidebarView.type === "feed")
        return view.feedId === sidebarView.feedId;
      if (view.type === "theme" && sidebarView.type === "theme")
        return view.themeId === sidebarView.themeId;
      return true;
    }
    return false;
  };

  const itemClass = (view: SidebarView) =>
    `flex items-center justify-between px-3 py-1.5 rounded-md cursor-pointer text-sm transition-colors ${
      isActive(view)
        ? "bg-bg-active text-text-primary"
        : "text-text-secondary hover:bg-bg-hover hover:text-text-primary"
    }`;

  return (
    <div className="w-60 border-r border-border bg-bg-secondary flex flex-col h-full select-none">
      {/* Header */}
      <div className="px-3 py-3 flex items-center justify-between border-b border-border-light">
        <div className="flex items-center gap-2">
          <button
            onClick={() => useUiStore.getState().toggleSidebar()}
            className="text-text-muted hover:text-text-primary p-0.5"
            title="Collapse sidebar"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M15 18l-6-6 6-6" />
            </svg>
          </button>
          <span className="font-semibold text-base">Skim</span>
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={() => setShowAddFeed(true)}
            className="text-text-muted hover:text-text-primary p-1 rounded hover:bg-bg-hover"
            title="Add feed"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M12 5v14M5 12h14" />
            </svg>
          </button>
          <button
            onClick={() => refreshAll.mutate()}
            disabled={refreshAll.isPending}
            className={`text-text-muted hover:text-text-primary p-1 rounded hover:bg-bg-hover ${
              refreshAll.isPending ? "animate-spin" : ""
            }`}
            title="Refresh all feeds"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M21 2v6h-6M3 12a9 9 0 0 1 15-6.7L21 8M3 22v-6h6M21 12a9 9 0 0 1-15 6.7L3 16" />
            </svg>
          </button>
          <button
            onClick={() => setShowSettings(true)}
            className="text-text-muted hover:text-text-primary p-1 rounded hover:bg-bg-hover"
            title="Settings"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <circle cx="12" cy="12" r="3" />
              <path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42" />
            </svg>
          </button>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto py-2 px-2">
        {/* Main navigation */}
        <div className="space-y-0.5 mb-4">
          <div
            onClick={() => setSidebarView({ type: "all" })}
            className={itemClass({ type: "all" })}
          >
            <span>All Articles</span>
            {totalUnread > 0 && (
              <span className="text-xs text-text-muted">{totalUnread}</span>
            )}
          </div>
          <div
            onClick={() => setSidebarView({ type: "starred" })}
            className={itemClass({ type: "starred" })}
          >
            <span>Starred</span>
          </div>
        </div>

        {/* Themes */}
        <div className="mb-4">
          <div className="flex items-center justify-between px-3 mb-1">
            <span className="text-xs font-medium text-text-muted uppercase tracking-wider">
              Themes
            </span>
            <button
              onClick={() => generateThemes.mutate()}
              disabled={generateThemes.isPending}
              className="text-xs text-accent hover:text-accent-hover disabled:opacity-50"
              title="Generate themes with AI"
            >
              {generateThemes.isPending ? "..." : "Generate"}
            </button>
          </div>
          {themes && themes.length > 0 ? (
            <div className="space-y-0.5">
              {themes.map((theme) => (
                <div
                  key={theme.id}
                  onClick={() =>
                    setSidebarView({ type: "theme", themeId: theme.id })
                  }
                  className={itemClass({ type: "theme", themeId: theme.id })}
                >
                  <span className="truncate">{theme.label}</span>
                  {theme.article_count != null && (
                    <span className="text-xs text-text-muted ml-1">
                      {theme.article_count}
                    </span>
                  )}
                </div>
              ))}
            </div>
          ) : (
            <p className="px-3 text-xs text-text-muted">
              Configure AI in settings, then click Generate to group articles by theme.
            </p>
          )}
        </div>

        {/* Feeds */}
        <div>
          <span className="px-3 text-xs font-medium text-text-muted uppercase tracking-wider">
            Feeds
          </span>
          <div className="space-y-0.5 mt-1">
            {feeds?.map((feed) => (
              <div
                key={feed.id}
                onClick={() =>
                  setSidebarView({ type: "feed", feedId: feed.id })
                }
                className={itemClass({ type: "feed", feedId: feed.id })}
              >
                <span className="truncate">{feed.title}</span>
                {feed.unread_count > 0 && (
                  <span className="text-xs text-text-muted">
                    {feed.unread_count}
                  </span>
                )}
              </div>
            ))}
            {(!feeds || feeds.length === 0) && (
              <p className="px-3 text-xs text-text-muted py-2">
                No feeds yet. Click + to add one.
              </p>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
