import { useEffect, useRef, useState } from "react";
import { useFeeds, useRefreshAllFeeds, useRemoveFeed, useRenameFeed } from "../../hooks/useFeeds";
import { useTriageArticles, useTriageStats } from "../../hooks/useInbox";
import { useThemes, useGenerateThemes } from "../../hooks/useThemes";
import { useUiStore } from "../../stores/uiStore";
import { countStarredInFeed } from "../../services/commands";
import type { SidebarView, Feed } from "../../services/types";

export function Sidebar() {
  const { sidebarView, setSidebarView, setShowAddFeed, setShowSettings, sidebarCollapsed } =
    useUiStore();
  const { data: feeds } = useFeeds();
  const { data: triageStats } = useTriageStats();
  const refreshAll = useRefreshAllFeeds();
  const triage = useTriageArticles();
  const { data: themes } = useThemes();
  const generateThemes = useGenerateThemes();
  const removeFeedMut = useRemoveFeed();
  const renameFeedMut = useRenameFeed();

  const [contextMenu, setContextMenu] = useState<{ feedId: string; x: number; y: number } | null>(null);
  const [renamingFeedId, setRenamingFeedId] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState("");
  const [removeConfirm, setRemoveConfirm] = useState<{ feed: Feed; starredCount: number } | null>(null);

  const totalUnread = feeds?.reduce((sum, f) => sum + f.unread_count, 0) ?? 0;

  useEffect(() => {
    if (!contextMenu) return;
    const close = () => setContextMenu(null);
    window.addEventListener("click", close);
    window.addEventListener("scroll", close, true);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("scroll", close, true);
    };
  }, [contextMenu]);

  const openContextMenu = (e: React.MouseEvent, feedId: string) => {
    e.preventDefault();
    e.stopPropagation();
    setContextMenu({ feedId, x: e.clientX, y: e.clientY });
  };

  const startRename = (feed: Feed) => {
    setContextMenu(null);
    setRenamingFeedId(feed.id);
    setRenameValue(feed.title);
  };

  const commitRename = async () => {
    if (!renamingFeedId) return;
    const trimmed = renameValue.trim();
    const original = feeds?.find((f) => f.id === renamingFeedId);
    if (!trimmed || !original || trimmed === original.title) {
      setRenamingFeedId(null);
      return;
    }
    try {
      await renameFeedMut.mutateAsync({ feedId: renamingFeedId, title: trimmed });
    } finally {
      setRenamingFeedId(null);
    }
  };

  const startRemove = async (feed: Feed) => {
    setContextMenu(null);
    let starredCount = 0;
    try {
      starredCount = await countStarredInFeed(feed.id);
    } catch {
      // ignore
    }
    setRemoveConfirm({ feed, starredCount });
  };

  const confirmRemove = async () => {
    if (!removeConfirm) return;
    try {
      await removeFeedMut.mutateAsync(removeConfirm.feed.id);
      if (sidebarView.type === "feed" && sidebarView.feedId === removeConfirm.feed.id) {
        setSidebarView({ type: "all" });
      }
    } finally {
      setRemoveConfirm(null);
    }
  };

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

        {/* Themes section */}
        <div style={{ marginBottom: 32, padding: "0 8px" }}>
          <div className="flex items-center justify-between" style={{ marginBottom: 8 }}>
            <div className="flex items-center gap-3">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"
                className="flex-shrink-0 opacity-50"
              >
                <rect x="3" y="3" width="7" height="7" rx="1" />
                <rect x="14" y="3" width="7" height="7" rx="1" />
                <rect x="3" y="14" width="7" height="7" rx="1" />
                <rect x="14" y="14" width="7" height="7" rx="1" />
              </svg>
              <span style={{ fontSize: 17, fontWeight: 600 }} className="text-text-primary">
                Themes
              </span>
            </div>
          </div>
          <button
            onClick={() => generateThemes.mutate()}
            disabled={generateThemes.isPending}
            className="flex items-center gap-2 w-full rounded-lg text-text-muted hover:text-accent hover:bg-white/5 transition-colors relative z-20"
            style={{ padding: "8px", fontSize: 13, marginBottom: 4 }}
          >
            {generateThemes.isPending ? (
              <>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="animate-spin flex-shrink-0">
                  <path d="M21 12a9 9 0 11-6.219-8.56" />
                </svg>
                <span>Grouping articles...</span>
              </>
            ) : (
              <>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="flex-shrink-0">
                  <rect x="3" y="3" width="7" height="7" rx="1" />
                  <rect x="14" y="3" width="7" height="7" rx="1" />
                  <rect x="3" y="14" width="7" height="7" rx="1" />
                  <rect x="14" y="14" width="7" height="7" rx="1" />
                </svg>
                <span>Group by theme</span>
              </>
            )}
          </button>
          {generateThemes.isError && (
            <p className="text-red-400" style={{ fontSize: 12, padding: "4px 8px" }}>
              {generateThemes.error instanceof Error ? generateThemes.error.message : "Theme generation failed"}
            </p>
          )}
          {themes && themes.length > 0 && (
            <div className="space-y-1 mt-1">
              {themes.map((theme) => (
                <div
                  key={theme.id}
                  onClick={() => setSidebarView({ type: "theme", themeId: theme.id })}
                  className={`rounded-lg cursor-pointer transition-colors relative z-20 ${
                    isActive({ type: "theme", themeId: theme.id })
                      ? "bg-white/10 text-text-primary"
                      : "text-text-secondary hover:bg-white/5 hover:text-text-primary"
                  }`}
                  style={{ padding: "8px" }}
                >
                  <div className="flex items-center justify-between">
                    <span className="truncate" style={{ fontSize: 14 }}>{theme.label}</span>
                    {theme.article_count != null && (
                      <span className="text-text-muted tabular-nums ml-2 flex-shrink-0" style={{ fontSize: 13 }}>
                        {theme.article_count}
                      </span>
                    )}
                  </div>
                  {theme.summary && (
                    <p className="text-text-muted truncate" style={{ fontSize: 12, marginTop: 2 }}>
                      {theme.summary}
                    </p>
                  )}
                </div>
              ))}
            </div>
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
            {feeds?.map((feed) => (
              <FeedRow
                key={feed.id}
                feed={feed}
                active={isActive({ type: "feed", feedId: feed.id })}
                renaming={renamingFeedId === feed.id}
                renameValue={renameValue}
                setRenameValue={setRenameValue}
                onCommitRename={commitRename}
                onCancelRename={() => setRenamingFeedId(null)}
                onClick={() => setSidebarView({ type: "feed", feedId: feed.id })}
                onContextMenu={(e) => openContextMenu(e, feed.id)}
              />
            ))}
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

      {/* Context menu */}
      {contextMenu && (() => {
        const feed = feeds?.find((f) => f.id === contextMenu.feedId);
        if (!feed) return null;
        return (
          <div
            className="fixed z-50 rounded-lg border border-white/10 shadow-xl"
            style={{
              top: contextMenu.y,
              left: contextMenu.x,
              background: "rgba(22, 27, 34, 0.98)",
              minWidth: 160,
            }}
            onClick={(e) => e.stopPropagation()}
          >
            <button
              onClick={() => startRename(feed)}
              className="flex items-center gap-2 w-full text-left text-text-primary hover:bg-white/10 transition-colors"
              style={{ padding: "8px 12px", fontSize: 13 }}
            >
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
                <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" />
              </svg>
              Rename
            </button>
            <button
              onClick={() => startRemove(feed)}
              className="flex items-center gap-2 w-full text-left text-danger hover:bg-red-500/10 transition-colors"
              style={{ padding: "8px 12px", fontSize: 13 }}
            >
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <polyline points="3 6 5 6 21 6" />
                <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" />
                <path d="M10 11v6M14 11v6" />
                <path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2" />
              </svg>
              Remove feed...
            </button>
          </div>
        );
      })()}

      {/* Remove confirm dialog */}
      {removeConfirm && (
        <div
          className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50"
          onClick={() => setRemoveConfirm(null)}
        >
          <div
            className="border border-white/10 rounded-2xl shadow-2xl"
            style={{ background: "rgba(22, 27, 34, 0.98)", maxWidth: 420, width: "100%", margin: "0 20px" }}
            onClick={(e) => e.stopPropagation()}
          >
            <div style={{ padding: "20px 24px 16px" }}>
              <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 8 }}>
                Remove "{removeConfirm.feed.title}"?
              </h3>
              {removeConfirm.starredCount > 0 ? (
                <p className="text-text-secondary" style={{ fontSize: 13 }}>
                  This feed has{" "}
                  <strong className="text-amber-400">
                    {removeConfirm.starredCount} starred article
                    {removeConfirm.starredCount !== 1 ? "s" : ""}
                  </strong>
                  . Removing the feed deletes all its articles including the starred ones. This cannot be undone.
                </p>
              ) : (
                <p className="text-text-muted" style={{ fontSize: 13 }}>
                  All articles from this feed will be deleted. This cannot be undone.
                </p>
              )}
            </div>
            <div className="flex justify-end gap-2 border-t border-white/5" style={{ padding: "12px 20px" }}>
              <button
                onClick={() => setRemoveConfirm(null)}
                className="text-text-secondary hover:text-text-primary rounded-lg hover:bg-white/5 transition-colors"
                style={{ padding: "8px 16px", fontSize: 13 }}
              >
                Cancel
              </button>
              <button
                onClick={confirmRemove}
                disabled={removeFeedMut.isPending}
                className="bg-danger text-white rounded-lg hover:bg-red-600 disabled:opacity-40 transition-colors font-medium"
                style={{ padding: "8px 16px", fontSize: 13 }}
              >
                {removeFeedMut.isPending ? "Removing..." : "Remove"}
              </button>
            </div>
          </div>
        </div>
      )}

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

function FeedRow({
  feed,
  active,
  renaming,
  renameValue,
  setRenameValue,
  onCommitRename,
  onCancelRename,
  onClick,
  onContextMenu,
}: {
  feed: Feed;
  active: boolean;
  renaming: boolean;
  renameValue: string;
  setRenameValue: (v: string) => void;
  onCommitRename: () => void;
  onCancelRename: () => void;
  onClick: () => void;
  onContextMenu: (e: React.MouseEvent) => void;
}) {
  const [iconFailed, setIconFailed] = useState(false);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const initial = (feed.title || "?")[0].toUpperCase();

  useEffect(() => {
    if (renaming) {
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [renaming]);

  return (
    <div
      onClick={renaming ? undefined : onClick}
      onContextMenu={onContextMenu}
      className={`flex items-center justify-between rounded-lg transition-colors relative z-20 ${
        renaming ? "" : "cursor-pointer"
      } ${
        active
          ? "bg-white/10 text-text-primary"
          : "text-text-secondary hover:bg-white/5 hover:text-text-primary"
      }`}
      style={{ padding: "8px" }}
    >
      <div className="flex items-center gap-3 min-w-0 flex-1">
        {feed.icon_url && !iconFailed ? (
          <img
            src={feed.icon_url}
            alt=""
            width={20}
            height={20}
            className="rounded-sm flex-shrink-0 bg-white/5"
            style={{ objectFit: "contain" }}
            onError={() => setIconFailed(true)}
          />
        ) : (
          <div
            className="rounded-md bg-accent/20 text-accent flex items-center justify-center font-bold flex-shrink-0"
            style={{ width: 20, height: 20, fontSize: 11 }}
          >
            {initial}
          </div>
        )}
        {renaming ? (
          <input
            ref={inputRef}
            value={renameValue}
            onChange={(e) => setRenameValue(e.target.value)}
            onBlur={onCommitRename}
            onKeyDown={(e) => {
              if (e.key === "Enter") onCommitRename();
              if (e.key === "Escape") onCancelRename();
            }}
            className="flex-1 min-w-0 bg-white/10 rounded px-2 py-0.5 text-text-primary outline-none border border-accent/40"
            style={{ fontSize: 15 }}
          />
        ) : (
          <span className="truncate" style={{ fontSize: 15 }}>
            {feed.title}
          </span>
        )}
      </div>
      {!renaming && feed.unread_count > 0 && (
        <span className="text-text-muted tabular-nums ml-2" style={{ fontSize: 14 }}>
          {feed.unread_count.toLocaleString()}
        </span>
      )}
    </div>
  );
}
