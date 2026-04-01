import { useFeeds, useRefreshAllFeeds } from "../../hooks/useFeeds";
import { useTriageArticles, useTriageStats } from "../../hooks/useInbox";
import { useUiStore } from "../../stores/uiStore";
import type { SidebarView } from "../../services/types";

export function Sidebar() {
  const { sidebarView, setSidebarView, setShowAddFeed, setShowSettings, sidebarCollapsed } =
    useUiStore();
  const { data: feeds } = useFeeds();
  const { data: triageStats } = useTriageStats();
  const refreshAll = useRefreshAllFeeds();
  const triage = useTriageArticles();

  const totalUnread = feeds?.reduce((sum, f) => sum + f.unread_count, 0) ?? 0;

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
      className={`${sidebarCollapsed ? '' : 'border-r border-white/5'} bg-white/3 flex flex-col h-full select-none overflow-hidden transition-all duration-300 ease-in-out`}
      style={{ width: sidebarCollapsed ? 0 : 320, minWidth: sidebarCollapsed ? 0 : 320 }}
    >
      {/* Top bar: action buttons right */}
      <div
        className="flex items-center justify-end gap-3 relative z-20"
        style={{ height: 40, paddingRight: 16 }}
      >
        <button
          onClick={() => useUiStore.getState().toggleSidebar()}
          className="text-text-muted hover:text-text-primary transition-colors"
          title="Collapse sidebar"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <rect x="3" y="3" width="18" height="18" rx="2" />
            <path d="M9 3v18" />
          </svg>
        </button>
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
      <div style={{ padding: "12px 24px 28px 24px" }}>
        <h1 style={{
          fontFamily: "'Aquire', sans-serif",
          fontSize: 38,
          fontWeight: 700,
          letterSpacing: "0.15em",
          transform: "scaleX(1.6)",
          transformOrigin: "left",
          color: "#e6edf3",
          textShadow: "0 0 14px rgba(136, 200, 255, 0.35)",
          lineHeight: 1,
        }}>SKIM</h1>
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

        {/* AI Inbox */}
        <div style={{ marginBottom: 32, padding: "0 8px" }}>
          <div
            onClick={() => setSidebarView({ type: "inbox" })}
            className={`flex items-center justify-between cursor-pointer transition-colors relative z-20 hover:text-text-primary ${
              isActive({ type: "inbox" }) ? "text-text-primary" : "text-text-secondary"
            }`}
            style={{ padding: "6px 0", marginBottom: 8 }}
          >
            <div className="flex items-center gap-3">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"
                className={`flex-shrink-0 ${isActive({ type: "inbox" }) ? "opacity-100" : "opacity-50"}`}
              >
                <polyline points="22 12 16 12 14 15 10 15 8 12 2 12" />
                <path d="M5.45 5.11L2 12v6a2 2 0 002 2h16a2 2 0 002-2v-6l-3.45-6.89A2 2 0 0016.76 4H7.24a2 2 0 00-1.79 1.11z" />
              </svg>
              <span style={{ fontSize: 17, fontWeight: 600 }}>
                AI Inbox
              </span>
            </div>
            {triageStats && triageStats.total > 0 && (
              <span className="text-text-muted tabular-nums" style={{ fontSize: 14 }}>
                {triageStats.total}
              </span>
            )}
          </div>
          <button
            onClick={(e) => { e.stopPropagation(); triage.mutate(false); }}
            disabled={triage.isPending}
            className="flex items-center gap-2 w-full rounded-lg text-text-muted hover:text-accent hover:bg-white/5 transition-colors relative z-20"
            style={{ padding: "8px", fontSize: 13 }}
          >
            {triage.isPending ? (
              <>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="animate-spin flex-shrink-0">
                  <path d="M21 12a9 9 0 11-6.219-8.56" />
                </svg>
                <span>Triaging...</span>
              </>
            ) : (
              <>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="flex-shrink-0">
                  <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
                </svg>
                <span>Triage unread articles</span>
              </>
            )}
          </button>
          {triage.isError && (
            <p className="text-red-400" style={{ fontSize: 12, padding: "4px 8px" }}>
              {triage.error instanceof Error ? triage.error.message : "Triage failed"}
            </p>
          )}
          {triage.isSuccess && triage.data && (
            <p className="text-text-muted" style={{ fontSize: 12, padding: "4px 8px" }}>
              {triage.data.triaged_count > 0
                ? `Triaged ${triage.data.triaged_count} articles`
                : "No new articles to triage"}
              {triage.data.errors.length > 0 && ` (${triage.data.errors.length} errors)`}
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
          className="flex items-center gap-3 w-full rounded-lg text-text-primary/90 hover:text-text-primary hover:bg-white/10 transition-colors relative z-20"
          style={{ padding: "10px 8px" }}
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
            <circle cx="12" cy="12" r="3" />
            <path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42" />
          </svg>
          <span style={{ fontSize: 14 }}>Settings</span>
        </button>
      </div>
    </div>
  );
}
