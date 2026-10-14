import { useEffect, useRef, useState } from "react";
import { CollapsedSidebarTitlebar } from "../layout/CollapsedSidebarTitlebar";
import { useRefreshAllFeeds } from "../../hooks/useFeeds";
import { useTodayEdition } from "../../hooks/useTodayEdition";
import { useUiStore } from "../../stores/uiStore";
import { PAGE_SIZE, TODAY_PAGE_COUNT, formatWindowDate, rankFor } from "../../lib/todayEdition";
import { TodayStorySkeleton } from "./TodayStorySkeleton";
import { TodayStory } from "./TodayStory";
import { ModelPicker } from "../common/ModelPicker";
import { ChatIcon, NewspaperIcon, RefreshIcon } from "../ui/icons";
import { openAgentChat } from "../../stores/agentChatStore";
import { useAgentContext } from "../../hooks/useAgentContext";
import { storyForAgent } from "../../lib/agentContext";
import { IconButton } from "../common/IconButton";
import { SettingsCog } from "../common/SettingsCog";
import "./TodayFrontPage.css";

export const NEWSPAPER_PAGE_SIZE = PAGE_SIZE;

/** The page's slots: a lead with a rail beside it, a row of features, briefs. */
function FrontPage({ cells }: { cells: { key: string; node: React.ReactNode }[] }) {
  const cell = (index: number) => cells[index] && (
    <div key={cells[index].key} className={`today-story-cell today-story-cell--${rankFor(index)}`}>{cells[index].node}</div>
  );
  const rail = [1, 2, 3].map(cell).filter(Boolean);
  const features = [4, 5, 6].map(cell).filter(Boolean);
  const briefs = cells.slice(7).map((_, index) => cell(index + 7));
  return (
    <div className="today-stories today-front">
      <div className={`today-front-top ${rail.length ? "" : "today-front-top--solo"}`}>
        {cell(0)}
        {rail.length > 0 && <div className="today-front-rail">{rail}</div>}
      </div>
      {features.length > 0 && <div className="today-front-row" data-count={features.length}>{features}</div>}
      {briefs.length > 0 && <section className="today-front-briefs" aria-label="In brief">
        <h4 className="today-briefs-label">In brief</h4>
        <div className="today-front-brief-grid">{briefs}</div>
      </section>}
    </div>
  );
}

export function TodayEditionPane() {
  const { isPhone, sidebarCollapsed, selectedArticleId, openArticleFromToday, setPhonePane, todayPage, setTodayPage } = useUiStore();
  const { data, isLoading, isError, error, window: todayWin, setConsumed, markStoryRead, ledeProgress, isWritingLedes, canRetryLedes, retryLedes, refetch, aiEnabled, isPreparingSummaries, settingsUnavailable, retrySettings } =
    useTodayEdition();

  const [theme, setTheme] = useState<string | null>(null);
  const [sharedOnly, setSharedOnly] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);
  // Asks go to the app's assistant, which already knows the stories on the page.
  const agentContext = useAgentContext();
  const refreshFeeds = useRefreshAllFeeds();
  const isFrontPage = !isPhone && !selectedArticleId;
  const items = data?.items ?? [];
  const themes = [...new Set(items.flatMap((item) => item.editorial?.theme ? [item.editorial.theme] : []))];
  const activeTheme = themes.includes(theme ?? "") ? theme : null;
  const visibleItems = items.map((item, index) => ({ item, index })).filter(({ item }) =>
    (!activeTheme || item.editorial?.theme === activeTheme) &&
    (!sharedOnly || item.member_articles.filter((member) => member.membership_type !== "duplicate").length > 1));
  // The paper's pages are weeks: the front page is today, each page turned
  // goes back a week. Turning a page starts it at the top.
  const turnTo = (page: number) => {
    if (page < 1 || page > TODAY_PAGE_COUNT || page === todayPage) return;
    setTodayPage(page);
    setTheme(null);
    setSharedOnly(false);
    scrollRef.current?.scrollTo?.({ top: 0, behavior: "instant" });
  };
  const canTurnBack = todayPage < TODAY_PAGE_COUNT;
  const canTurnForward = todayPage > 1;
  // ← and → turn the pages while the paper itself has the window.
  useEffect(() => {
    if (!isFrontPage) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target as HTMLElement | null;
      if (target && (target.closest("input, textarea, select, [contenteditable]") || target.closest('[role="dialog"]'))) return;
      if (event.key === "ArrowRight" && canTurnBack) { event.preventDefault(); turnTo(todayPage + 1); }
      if (event.key === "ArrowLeft" && canTurnForward) { event.preventDefault(); turnTo(todayPage - 1); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }); // eslint-disable-line react-hooks/exhaustive-deps

  const handleOpenArticle = (articleId: string) => {
    openArticleFromToday(articleId);
  };

  const totalCount = data?.total_count ?? 0;
  const missingSummaries = items.filter((item) => !item.editorial?.summary.trim()).length;
  const consumedCount = data?.consumed_count ?? 0;
  const isFullyConsumed = totalCount > 0 && consumedCount === totalCount;
  const progressPct = totalCount > 0 ? Math.round((consumedCount / totalCount) * 100) : 0;

  return (
    <div
      className={`today-page ${!isPhone ? "border-r border-white/5" : ""} bg-bg-secondary/70 flex flex-col h-full overflow-hidden`}
      style={{
        width: isPhone || isFrontPage ? "100%" : 420,
        minWidth: isPhone ? "100%" : isFrontPage ? 0 : 360,
        flex: isFrontPage ? 1 : undefined,
      }}
    >
      {sidebarCollapsed && !isPhone && <CollapsedSidebarTitlebar />}
      {/* Top bar: ask, refresh and a cog for Today's few settings. */}
      <div
        className="today-topbar flex flex-shrink-0 items-center gap-1 relative z-20"
        style={{ paddingLeft: 8, paddingRight: isPhone ? 8 : 20 }}
      >
        {isPhone && (
          <button
            onClick={() => setPhonePane("sidebar")}
            className="tap-target text-text-muted hover:text-text-primary transition-colors rounded-lg hover:bg-white/10"
            title="Open sidebar"
          >
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
              <line x1="3" y1="6" x2="21" y2="6" />
              <line x1="3" y1="12" x2="21" y2="12" />
              <line x1="3" y1="18" x2="21" y2="18" />
            </svg>
          </button>
        )}
        <div className="flex-1" />
        {items.length > 0 && <IconButton
          label="Ask about Today"
          onClick={() => openAgentChat({ context: { ...agentContext, story: null } })}
          className="text-text-secondary hover:text-text-primary hover:bg-white/10"
        >
          <ChatIcon size={18} />
        </IconButton>}
        <IconButton
          label={refreshFeeds.isPending ? "Refreshing…" : "Refresh feeds"}
          disabled={refreshFeeds.isPending}
          onClick={() => refreshFeeds.mutate(undefined)}
          className="text-text-secondary hover:text-text-primary hover:bg-white/10"
        >
          <RefreshIcon size={18} className={refreshFeeds.isPending ? "smooth-spin" : undefined} />
        </IconButton>
        <SettingsCog label="Today settings" heading="Today" className="text-text-secondary">
          {(close) => (
            <>
              <div className="today-settings-row">
                <span>Summary model</span>
                <ModelPicker surface="today" compact />
              </div>
              <button className="today-settings-row" onClick={() => { close(); useUiStore.getState().setShowSettings(true, "sync"); }}>
                <span>Edition size</span><span className="text-text-muted">{data?.edition.story_limit ?? 10} stories</span>
              </button>
              {canRetryLedes && <button className="today-settings-row" onClick={() => { close(); retryLedes(); }}>Retry missing summaries</button>}
              <hr />
              <button className="today-settings-row" onClick={() => { close(); useUiStore.getState().setShowSettings(true); }}>AI settings…</button>
            </>
          )}
        </SettingsCog>
      </div>

      <div ref={scrollRef} className="today-scroll flex-1 overflow-y-auto">
      <div className="today-content">
      {/* Masthead: the nameplate, then a dateline whose rule doubles as the
          day's reading progress. */}
      <div className="today-masthead">
        <h2 className="today-title text-text-primary truncate">
          Today
        </h2>
        <div className="today-dateline">
          <span>{formatWindowDate(todayWin)}</span>
          {totalCount > 0 && (
            <span className="today-dateline-status">
              {totalCount} {totalCount === 1 ? "story" : "stories"}
              {themes.length > 0 && <> · {themes.length} {themes.length === 1 ? "theme" : "themes"}</>}
              {canRetryLedes && missingSummaries > 0 && <>
                {" · "}<span className="today-dateline-failed">{missingSummaries} not summarized</span>
                <button type="button" className="today-dateline-retry" onClick={retryLedes} aria-label="Retry summaries">Retry</button>
              </>}
            </span>
          )}
          {totalCount > 0 && (
            <span className="today-dateline-progress">
              <span>{isFullyConsumed ? "All caught up" : `${consumedCount} of ${totalCount} done`}</span>
              <span className="tabular-nums" style={{ opacity: 0.7 }}>{progressPct}%</span>
            </span>
          )}
        </div>
        <div className="today-dateline-rule" role="presentation">
          {totalCount > 0 && (
            <div
              className={`today-dateline-fill ${isFullyConsumed ? "bg-success" : "bg-accent"}`}
              style={{ width: `${progressPct}%` }}
            />
          )}
        </div>
      </div>

        {isLoading && <div aria-label="Preparing newspaper">
          <FrontPage cells={Array.from({ length: NEWSPAPER_PAGE_SIZE }, (_, index) => ({
            key: `skeleton-${index}`, node: <TodayStorySkeleton rank={rankFor(index)} />,
          }))} />
        </div>}

        {isError && (
          <div role="alert" className="text-danger" style={{ fontSize: 13, padding: "12px 4px" }}>
            <p>{error instanceof Error ? error.message : "Could not load today's edition."}</p>
            <button className="today-story-control text-text-primary" onClick={() => void refetch()}>Try again</button>
          </div>
        )}

        {settingsUnavailable && <div role="alert" className="today-summary-note">Could not load AI settings. <button className="today-story-control" onClick={() => void retrySettings()}>Retry AI settings</button></div>}
        {refreshFeeds.isError && <p role="alert" className="text-danger" style={{ fontSize: 13 }}>Could not refresh feeds. Please try again.</p>}
        {setConsumed.isError && <p role="alert" className="text-danger" style={{ fontSize: 13 }}>Could not save reading progress. Please try again.</p>}

        {!isLoading && !isError && totalCount === 0 && (
          <div className="flex flex-col items-center justify-center px-6 text-center" style={{ minHeight: 220 }}>
            <NewspaperIcon size={34} strokeWidth="1.5" className="text-text-muted mb-3 opacity-45" />
            <p className="text-text-secondary" style={{ fontSize: 14, fontWeight: 600, marginBottom: 5 }}>
              {todayPage > 1 ? "No stories that week" : "No stories yet today"}
            </p>
            <p className="text-text-muted" style={{ fontSize: 12, lineHeight: 1.5, maxWidth: 280 }}>
              Refresh your feeds to bring in new stories.
            </p>
          </div>
        )}

        {!isLoading && !isError && isWritingLedes && (
          <div style={{ marginTop: 14 }}>
            <span className="text-text-muted" style={{ fontSize: 11.5 }}>
              {ledeProgress?.message || "Preparing summaries…"}
            </span>
            <div className="story-rule-live" style={{ height: 2, borderRadius: 999, marginTop: 6 }} />
          </div>
        )}

        {!isLoading && !isError && items.length > 0 && <>
          {!aiEnabled && !settingsUnavailable && items.some((item) => !item.editorial) && <p className="today-summary-note">Unprepared summaries show source excerpts. <button className="today-story-control text-accent" onClick={() => useUiStore.getState().setShowSettings(true)}>Set up AI for thematic summaries</button></p>}
          <nav className="today-themes" aria-label="Newspaper themes">
            <button className="today-story-control" aria-pressed={!activeTheme && !sharedOnly} onClick={() => { setTheme(null); setSharedOnly(false); }}>All stories</button>
            {themes.map((name) => <button key={name} className="today-story-control" aria-pressed={activeTheme === name} onClick={() => setTheme(activeTheme === name ? null : name)}>{name}</button>)}
            <button className="today-story-control" aria-pressed={sharedOnly} onClick={() => setSharedOnly(!sharedOnly)}>Multiple reports</button>
          </nav>
          {visibleItems.length === 0 && <p className="today-summary-note">No stories with multiple reports in this selection.</p>}
        </>}
        {!isLoading && !isError && visibleItems.length > 0 && <FrontPage cells={visibleItems.map(({ item }, index) => ({
          key: item.story_id,
          node: !item.editorial && isPreparingSummaries ? <TodayStorySkeleton rank={rankFor(index)} /> : <TodayStory
            item={item}
            rank={rankFor(index)}
            isSaving={setConsumed.isPending}
            onToggleConsumed={(storyId, isConsumed) => setConsumed.mutate({ storyId, isConsumed })}
            onOpenArticle={(articleId) => { markStoryRead(item.story_id); handleOpenArticle(articleId); }}
            onAsk={() => openAgentChat({
              context: { ...agentContext, story: storyForAgent(item) },
              onSend: () => markStoryRead(item.story_id),
            })}
          />,
        }))} />}

        {isFullyConsumed && (
          <div
            className="rounded-xl border border-success/20 text-center"
            style={{ padding: "14px 16px", marginTop: 18, background: "rgba(34, 197, 94, 0.06)" }}
          >
            <p className="text-text-primary" style={{ fontSize: 13, fontWeight: 500 }}>
              {todayPage > 1 ? "You're all caught up on this page." : "You're all caught up for today."}
            </p>
          </div>
        )}
      </div>
      </div>
      {/* Turning the page goes back a week; the dateline names the week. */}
      <nav className="today-pagination" aria-label="Newspaper pages">
        <button className="today-story-control" disabled={!canTurnForward} onClick={() => turnTo(todayPage - 1)}>{todayPage === 2 ? "Today" : "Previous page"}</button>
        <div className="today-page-position">
          <span role="status" aria-live="polite">{todayPage === 1 ? "Front page" : `Page ${todayPage}`}<span className="text-text-muted"> · {formatWindowDate(todayWin)}</span></span>
          <button className="today-story-control text-text-muted" onClick={() => useUiStore.getState().setShowSettings(true, "sync")}>Edition size</button>
        </div>
        <button className="today-story-control" disabled={!canTurnBack} onClick={() => turnTo(todayPage + 1)}>{todayPage === 1 ? "Last week" : "Next page"}</button>
      </nav>
    </div>
  );
}
