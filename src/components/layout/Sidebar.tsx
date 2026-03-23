import { useFeeds, useRefreshAllFeeds } from "../../hooks/useFeeds";
import { useThemes, useGenerateThemes } from "../../hooks/useThemes";
import { useUiStore } from "../../stores/uiStore";
import type { SidebarView } from "../../services/types";
import titleImg from "../../assets/title.png";

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
      <div className="w-12 border-r border-white/5 bg-white/3 flex flex-col items-center pt-14">
        <button
          onClick={() => useUiStore.getState().toggleSidebar()}
          className="text-text-secondary hover:text-text-primary p-1 relative z-20"
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

  return (
    <div
      className="border-r border-white/5 bg-white/3 flex flex-col h-full select-none"
      style={{ width: 320, minWidth: 320 }}
    >
      {/* Top bar: traffic light spacing left, action buttons right */}
      <div
        className="flex items-center justify-end gap-3 relative z-20"
        style={{ height: 40, paddingRight: 16 }}
      >
        <button
          onClick={() => refreshAll.mutate()}
          disabled={refreshAll.isPending}
          className={`text-text-muted hover:text-text-primary transition-colors ${
            refreshAll.isPending ? "animate-spin" : ""
          }`}
          title="Refresh all feeds"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M21 2v6h-6M3 12a9 9 0 0 1 15-6.7L21 8M3 22v-6h6M21 12a9 9 0 0 1-15 6.7L3 16" />
          </svg>
        </button>
        <button
          onClick={() => setShowAddFeed(true)}
          className="text-text-muted hover:text-text-primary transition-colors"
          title="Add feed"
        >
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 5v14M5 12h14" />
          </svg>
        </button>
      </div>

      {/* App title */}
      <div style={{ padding: "8px 16px 24px 16px" }}>
        <img src={titleImg} alt="Skim" style={{ width: 140, height: "auto" }} />
      </div>

      {/* Scrollable content */}
      <div className="flex-1 overflow-y-auto" style={{ padding: "0 16px 16px 16px" }}>
        {/* All Articles */}
        <div style={{ marginBottom: 32, padding: "0 8px" }}>
          <div
            onClick={() => setSidebarView({ type: "all" })}
            className="flex items-center justify-between cursor-pointer transition-colors relative z-20 hover:text-text-primary"
            style={{ padding: "6px 0", marginBottom: 4 }}
          >
            <span
              className={isActive({ type: "all" }) ? "text-text-primary" : "text-text-secondary"}
              style={{ fontSize: 17, fontWeight: 600 }}
            >
              All Articles
            </span>
            {totalUnread > 0 && (
              <span className="text-text-muted tabular-nums" style={{ fontSize: 15 }}>
                {totalUnread.toLocaleString()}
              </span>
            )}
          </div>
          <div
            onClick={() => setSidebarView({ type: "starred" })}
            className="flex items-center gap-3 cursor-pointer transition-colors relative z-20 hover:text-text-primary"
            style={{ padding: "6px 0" }}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"
              className={`flex-shrink-0 ${isActive({ type: "starred" }) ? "opacity-100" : "opacity-50"}`}
            >
              <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
            </svg>
            <span
              className={isActive({ type: "starred" }) ? "text-text-primary" : "text-text-secondary"}
              style={{ fontSize: 15 }}
            >
              Starred
            </span>
          </div>
        </div>

        {/* Themes section */}
        <div style={{ marginBottom: 32 }}>
          <div className="flex items-center justify-between" style={{ padding: "0 8px", marginBottom: 12 }}>
            <span style={{ fontSize: 17, fontWeight: 600 }} className="text-text-primary">
              Themes
            </span>
            <button
              onClick={() => generateThemes.mutate()}
              disabled={generateThemes.isPending}
              className="text-text-muted hover:text-text-primary transition-colors relative z-20"
              title="Generate themes with AI"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M6 9l6-6 6 6M6 15l6 6 6-6" />
              </svg>
            </button>
          </div>
          {themes && themes.length > 0 ? (
            <div className="space-y-1">
              {themes.map((theme) => (
                <div
                  key={theme.id}
                  onClick={() => setSidebarView({ type: "theme", themeId: theme.id })}
                  className={`flex items-center justify-between rounded-lg cursor-pointer transition-colors relative z-20 ${
                    isActive({ type: "theme", themeId: theme.id })
                      ? "bg-white/10 text-text-primary"
                      : "text-text-secondary hover:bg-white/5 hover:text-text-primary"
                  }`}
                  style={{ padding: "10px 8px" }}
                >
                  <div className="flex items-center gap-3 min-w-0">
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" className="flex-shrink-0 opacity-60">
                      <path d="M20.59 13.41l-7.17 7.17a2 2 0 01-2.83 0L2 12V2h10l8.59 8.59a2 2 0 010 2.82z" />
                      <line x1="7" y1="7" x2="7.01" y2="7" />
                    </svg>
                    <span className="truncate" style={{ fontSize: 15 }}>{theme.label}</span>
                  </div>
                  {theme.article_count != null && (
                    <span className="text-text-muted tabular-nums ml-2" style={{ fontSize: 14 }}>
                      {theme.article_count}
                    </span>
                  )}
                </div>
              ))}
            </div>
          ) : (
            <p className="text-text-muted leading-relaxed" style={{ fontSize: 13, padding: "0 8px" }}>
              Configure AI in settings, then click Generate to group articles by theme.
            </p>
          )}
        </div>

        {/* Feeds section */}
        <div>
          <div className="flex items-center justify-between" style={{ padding: "0 8px", marginBottom: 12 }}>
            <span style={{ fontSize: 17, fontWeight: 600 }} className="text-text-primary">
              Feeds
            </span>
          </div>
          <div className="space-y-1">
            {feeds?.map((feed) => {
              const initial = (feed.title || "?")[0].toUpperCase();
              return (
                <div
                  key={feed.id}
                  onClick={() => setSidebarView({ type: "feed", feedId: feed.id })}
                  className={`flex items-center justify-between rounded-lg cursor-pointer transition-colors relative z-20 ${
                    isActive({ type: "feed", feedId: feed.id })
                      ? "bg-white/10 text-text-primary"
                      : "text-text-secondary hover:bg-white/5 hover:text-text-primary"
                  }`}
                  style={{ padding: "8px" }}
                >
                  <div className="flex items-center gap-3 min-w-0">
                    <div
                      className="rounded-md bg-accent/20 text-accent flex items-center justify-center font-bold flex-shrink-0"
                      style={{ width: 28, height: 28, fontSize: 12 }}
                    >
                      {initial}
                    </div>
                    <span className="truncate" style={{ fontSize: 15 }}>{feed.title}</span>
                  </div>
                  {feed.unread_count > 0 && (
                    <span className="text-text-muted tabular-nums ml-2" style={{ fontSize: 14 }}>
                      {feed.unread_count.toLocaleString()}
                    </span>
                  )}
                </div>
              );
            })}
            {(!feeds || feeds.length === 0) && (
              <div style={{ padding: "20px 8px" }} className="text-center">
                <p className="text-text-muted" style={{ fontSize: 14, marginBottom: 8 }}>No feeds yet</p>
                <button
                  onClick={() => setShowAddFeed(true)}
                  className="text-accent hover:text-accent-hover transition-colors relative z-20"
                  style={{ fontSize: 14 }}
                >
                  + Add your first feed
                </button>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Settings at bottom */}
      <div className="border-t border-white/5" style={{ padding: "8px 16px 16px" }}>
        <button
          onClick={() => setShowSettings(true)}
          className="flex items-center gap-3 w-full rounded-lg text-text-muted hover:text-text-primary hover:bg-white/5 transition-colors relative z-20"
          style={{ padding: "10px 8px" }}
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" className="opacity-70">
            <circle cx="12" cy="12" r="3" />
            <path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42" />
          </svg>
          <span style={{ fontSize: 14 }}>Settings</span>
        </button>
      </div>
    </div>
  );
}
