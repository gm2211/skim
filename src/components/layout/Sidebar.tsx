import { useEffect, useRef, useState } from "react";
import { useRefreshAllFeeds, useFeeds } from "../../hooks/useFeeds";
import { useTriageArticles, useTriageProgress } from "../../hooks/useInbox";
import { AiErrorText } from "../common/AiSettingsButton";
import { useGenerateThemes, useThemeProgress } from "../../hooks/useThemes";
import { ChatIcon, NewspaperIcon, PlusIcon, RefreshIcon, SidebarIcon } from "../ui/icons";
import { useUiStore } from "../../stores/uiStore";
import type { SidebarView } from "../../services/types";
import { FeedsSection } from "./FeedsSection";
import { AskSkimDialog } from "../chat/AskSkimDialog";
import { SkimTitle } from "./SkimTitle";
import { useAppCommand } from "../../lib/appCommands";

export function Sidebar() {
  const askButtonRef = useRef<HTMLButtonElement>(null);
  const [askOpen, setAskOpen] = useState(false);
  const [askVisited, setAskVisited] = useState(false);
  const [returnToAsk, setReturnToAsk] = useState(false);
  const { selectedArticleId, sidebarView, setSidebarView, setShowAddFeed, setShowSettings, sidebarCollapsed, isPhone, listSort } =
    useUiStore();
  const { data: feeds } = useFeeds();
  const refreshAll = useRefreshAllFeeds();
  const triage = useTriageArticles();
  const triageProgress = useTriageProgress();
  const generateThemes = useGenerateThemes();
  const themeProgress = useThemeProgress();

  useEffect(() => {
    if (returnToAsk && !selectedArticleId) {
      setReturnToAsk(false);
      setAskOpen(true);
    }
  }, [returnToAsk, selectedArticleId]);

  useAppCommand("ask-skim", () => {
    setAskVisited(true);
    setAskOpen(true);
  });

  const totalUnread = feeds?.reduce((sum, f) => sum + f.unread_count, 0) ?? 0;

  // Auto-run triage + theme grouping when a list is sorted For you. Fires
  // once per switch to that sort. Skips if a run is already in flight.
  const autoRanFor = useRef<string | null>(null);
  useEffect(() => {
    if (listSort !== "forYou") {
      autoRanFor.current = null;
      return;
    }
    if (autoRanFor.current === "forYou") return;
    autoRanFor.current = "forYou";
    if (!triage.isPending) triage.mutate(false);
    if (!generateThemes.isPending) generateThemes.mutate();
  }, [listSort, triage, generateThemes]);

  const isActive = (view: SidebarView) => {
    if (view.type === sidebarView.type) {
      if (view.type === "feed" && sidebarView.type === "feed")
        return view.feedId === sidebarView.feedId;
      if (view.type === "theme" && sidebarView.type === "theme")
        return view.themeId === sidebarView.themeId;
      if (view.type === "folder" && sidebarView.type === "folder")
        return view.folderId === sidebarView.folderId;
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
      <div
        className={`sidebar-header flex flex-shrink-0 items-center relative z-20 ${isPhone ? "" : "sidebar-header-desktop"}`}
        data-tauri-drag-region={!isPhone ? true : undefined}
        style={{
          height: isPhone ? 60 : 40,
          paddingLeft: isPhone ? 16 : 80,
          paddingRight: isPhone ? 10 : 8,
          gap: isPhone ? 0 : 2,
          WebkitAppRegion: !isPhone ? "drag" : undefined,
        } as React.CSSProperties}
      >
        <SkimTitle isPhone={isPhone} />
        <div className="flex-1" />
        {!isPhone && <button
          onClick={() => useUiStore.getState().toggleSidebar()}
          className="sidebar-header-action tap-target rounded-lg text-text-muted hover:text-text-primary hover:bg-white/10 transition-colors"
          title="Collapse sidebar"
          aria-label="Collapse sidebar"
        >
          <SidebarIcon />
        </button>}
        <button
          onClick={() => refreshAll.mutate()}
          disabled={refreshAll.isPending}
          className="sidebar-header-action tap-target rounded-lg hover:bg-white/10 text-text-muted hover:text-text-primary transition-colors"
          title="Refresh all feeds"
          aria-label="Refresh all feeds"
        >
          <RefreshIcon className={refreshAll.isPending ? "smooth-spin" : undefined} />
        </button>
        <button
          ref={askButtonRef}
          onClick={() => { setAskVisited(true); setAskOpen(true); }}
          className="sidebar-header-action tap-target rounded-lg hover:bg-white/10 text-text-muted hover:text-accent transition-colors"
          title="Ask Skim — search your feed with AI"
          aria-label="Ask Skim"
        >
          <ChatIcon />
        </button>
        <button
          onClick={() => setSidebarView({ type: "today" })}
          className="sidebar-header-action tap-target rounded-lg hover:bg-white/10 text-text-muted hover:text-accent transition-colors"
          title="Today — your finite, sectioned daily edition"
          aria-label="Today"
        >
          <NewspaperIcon />
        </button>
        <button
          onClick={() => setShowAddFeed(true)}
          className="sidebar-header-action tap-target rounded-lg hover:bg-white/10 text-text-muted hover:text-text-primary transition-colors"
          title="Discover and follow feeds"
          aria-label="Add feed"
        >
          <PlusIcon />
        </button>
      </div>
      {askVisited && <AskSkimDialog
          open={askOpen}
          restoreFocusTarget={() => askButtonRef.current}
          onClose={() => setAskOpen(false)}
          onOpenArticle={(id) => {
            setReturnToAsk(true);
            useUiStore.getState().setSelectedArticleId(id);
          }}
        />}

      {/* Scrollable content */}
      <div className="flex-1 overflow-y-auto" style={{ padding: "8px 16px 16px 16px" }}>
        {/* Today — finite, sectioned daily edition. Above All Articles since
            it's the primary daily entry point; All Articles stays the
            complete chronological/searchable archive one click below. */}
        <div style={{ marginBottom: 32, padding: "0 8px" }}>
          <div
            onClick={() => setSidebarView({ type: "today" })}
            className="flex items-center gap-3 cursor-pointer transition-colors relative z-20 hover:text-text-primary"
            style={{ padding: "6px 0" }}
          >
            <NewspaperIcon
              size={16}
              strokeWidth="1.5"
              className={`flex-shrink-0 ${isActive({ type: "today" }) ? "opacity-100" : "opacity-50"}`}
            />
            <span
              className={isActive({ type: "today" }) ? "text-text-primary" : "text-text-secondary"}
              style={{ fontSize: 17, fontWeight: 600 }}
            >
              Today
            </span>
          </div>
        </div>

        {/* Discover — find and follow new feeds. */}
        <div style={{ marginTop: -24, marginBottom: 32, padding: "0 8px" }}>
          <div
            onClick={() => setSidebarView({ type: "discover" })}
            className="flex items-center gap-3 cursor-pointer transition-colors relative z-20 hover:text-text-primary"
            style={{ padding: "6px 0" }}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"
              className={`flex-shrink-0 ${isActive({ type: "discover" }) ? "opacity-100" : "opacity-50"}`} aria-hidden="true">
              <circle cx="12" cy="12" r="9" />
              <path d="m15.5 8.5-2 5-5 2 2-5z" />
            </svg>
            <span
              className={isActive({ type: "discover" }) ? "text-text-primary" : "text-text-secondary"}
              style={{ fontSize: 15 }}
            >
              Discover feeds
            </span>
          </div>
        </div>

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
          {!triage.isPending && !generateThemes.isPending && (triage.error || generateThemes.error) && (
            <AiErrorText
              stacked
              error={`Couldn't rank For you: ${String((triage.error ?? generateThemes.error) instanceof Error ? (triage.error ?? generateThemes.error)!.message : (triage.error ?? generateThemes.error))}`}
              style={{ padding: "4px 8px 0", fontSize: 12 }}
            />
          )}
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
