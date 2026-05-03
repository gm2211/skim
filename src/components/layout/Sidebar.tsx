import { useEffect, useRef, useState } from "react";
import { useRefreshAllFeeds, useFeeds } from "../../hooks/useFeeds";
import { useTriageArticles, useTriageStats, useTriageProgress } from "../../hooks/useInbox";
import { useGenerateThemes, useThemeProgress } from "../../hooks/useThemes";
import { useUiStore } from "../../stores/uiStore";
import type { SidebarView } from "../../services/types";
import { FeedsSection } from "./FeedsSection";
import { AskSkimDialog } from "../chat/AskSkimDialog";
import { CatchupDialog } from "../chat/CatchupDialog";

export function Sidebar() {
  const [askOpen, setAskOpen] = useState(false);
  const [catchupOpen, setCatchupOpen] = useState(false);
  const { sidebarView, setSidebarView, setShowAddFeed, setShowSettings, sidebarCollapsed, isPhone } =
    useUiStore();
  const { data: feeds } = useFeeds();
  const { data: triageStats } = useTriageStats();
  const refreshAll = useRefreshAllFeeds();
  const triage = useTriageArticles();
  const triageProgress = useTriageProgress();
  const generateThemes = useGenerateThemes();
  const themeProgress = useThemeProgress();

  const totalUnread = feeds?.reduce((sum, f) => sum + f.unread_count, 0) ?? 0;

  // Auto-run triage + theme grouping when the user lands on the AI Inbox.
  // Fires once per entry into the view. Skips if a run is already in flight.
  const autoRanFor = useRef<string | null>(null);
  useEffect(() => {
    if (sidebarView.type !== "inbox") {
      autoRanFor.current = null;
      return;
    }
    if (autoRanFor.current === "inbox") return;
    autoRanFor.current = "inbox";
    if (!triage.isPending) triage.mutate(false);
    if (!generateThemes.isPending) generateThemes.mutate();
  }, [sidebarView.type, triage, generateThemes]);

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
      className={`${sidebarCollapsed && !isPhone ? '' : 'border-r border-white/5'} bg-white/3 flex flex-col h-full select-none overflow-hidden transition-all duration-300 ease-in-out`}
      style={{
        width: isPhone ? "100%" : (sidebarCollapsed ? 0 : 320),
        minWidth: isPhone ? "100%" : (sidebarCollapsed ? 0 : 320),
      }}
    >
      {/* Top bar: action buttons right */}
      <div
        className="flex items-center gap-3 relative z-20"
        style={{ height: isPhone ? 60 : 40, paddingLeft: isPhone ? 10 : 0, paddingRight: isPhone ? 10 : 16 }}
      >
        <div className="flex-1" />
        <button
          onClick={() => useUiStore.getState().toggleSidebar()}
          className={`text-text-muted hover:text-text-primary transition-colors ${isPhone ? "hidden" : ""}`}
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
          className="tap-target rounded-lg hover:bg-white/10 text-text-muted hover:text-text-primary transition-colors"
          title="Refresh all feeds"
        >
          <svg className={refreshAll.isPending ? "smooth-spin" : undefined} width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M21 2v6h-6M3 12a9 9 0 0 1 15-6.7L21 8M3 22v-6h6M21 12a9 9 0 0 1-15 6.7L3 16" />
          </svg>
        </button>
        <button
          onClick={() => setAskOpen(true)}
          className="tap-target rounded-lg hover:bg-white/10 text-text-muted hover:text-accent transition-colors"
          title="Ask Skim — search your feed with AI"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
          </svg>
        </button>
        <button
          onClick={() => setCatchupOpen(true)}
          className="tap-target rounded-lg hover:bg-white/10 text-text-muted hover:text-accent transition-colors"
          title="Super-quick catch-up"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M13 2L3 14h9l-1 8 10-12h-9z" />
          </svg>
        </button>
        <button
          onClick={() => setShowAddFeed(true)}
          className="tap-target rounded-lg hover:bg-white/10 text-text-muted hover:text-text-primary transition-colors"
          title="Add feed"
        >
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 5v14M5 12h14" />
          </svg>
        </button>
      </div>
      {askOpen && (
        <AskSkimDialog
          onClose={() => setAskOpen(false)}
          onOpenArticle={(id) => {
            useUiStore.getState().setSelectedArticleId(id);
          }}
        />
      )}
      {catchupOpen && (
        <CatchupDialog
          onClose={() => setCatchupOpen(false)}
          onOpenArticle={(id) => {
            useUiStore.getState().setSelectedArticleId(id);
          }}
        />
      )}

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
          <div
            onClick={() => setSidebarView({ type: "recent" })}
            className="flex items-center gap-3 cursor-pointer transition-colors relative z-20 hover:text-text-primary"
            style={{ padding: "6px 0" }}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"
              className={`flex-shrink-0 ${isActive({ type: "recent" }) ? "opacity-100" : "opacity-50"}`}
            >
              <circle cx="12" cy="12" r="9" />
              <path d="M12 7v5l3 3" />
            </svg>
            <span
              className={isActive({ type: "recent" }) ? "text-text-primary" : "text-text-secondary"}
              style={{ fontSize: 15 }}
            >
              Recent
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
                {triageStats.total.toLocaleString()}
              </span>
            )}
          </div>
          {(triage.isPending || generateThemes.isPending) && (
            <div className="flex flex-col gap-2" style={{ padding: "4px 8px 0" }}>
              {triage.isPending && (
                <div className="flex items-center gap-2 text-text-muted" style={{ fontSize: 12 }}>
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="smooth-spin flex-shrink-0">
                    <path d="M21 12a9 9 0 11-6.219-8.56" />
                  </svg>
                  <span className="flex-1 truncate">{triageProgress?.message ?? "Triaging..."}</span>
                  {triageProgress && triageProgress.total > 0 && (
                    <span className="tabular-nums" style={{ fontSize: 11 }}>
                      {triageProgress.completed}/{triageProgress.total}
                    </span>
                  )}
                </div>
              )}
              {generateThemes.isPending && (
                <div className="flex items-center gap-2 text-text-muted" style={{ fontSize: 12 }}>
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="smooth-spin flex-shrink-0">
                    <path d="M21 12a9 9 0 11-6.219-8.56" />
                  </svg>
                  <span className="flex-1 truncate">{themeProgress?.message ?? "Grouping..."}</span>
                  {themeProgress && themeProgress.total > 0 && (
                    <span className="tabular-nums" style={{ fontSize: 11 }}>
                      {themeProgress.completed}/{themeProgress.total}
                    </span>
                  )}
                </div>
              )}
            </div>
          )}
        </div>

        {/* Feeds section */}
        <FeedsSection
          sidebarView={sidebarView}
          setSidebarView={setSidebarView}
          isActive={isActive}
          setShowAddFeed={setShowAddFeed}
        />
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
