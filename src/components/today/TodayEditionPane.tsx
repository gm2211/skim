import { Fragment, useState } from "react";
import { CollapsedSidebarTitlebar } from "../layout/CollapsedSidebarTitlebar";
import { useRefreshAllFeeds } from "../../hooks/useFeeds";
import { useTodayEdition } from "../../hooks/useTodayEdition";
import { useUiStore } from "../../stores/uiStore";
import { rankFor } from "../../lib/todayEdition";
import { TodayStory } from "./TodayStory";
import { ModelPicker } from "../common/ModelPicker";

function formatWindowDate(startsAtSeconds: number): string {
  return new Date(startsAtSeconds * 1000).toLocaleDateString("en-US", {
    weekday: "long",
    month: "long",
    day: "numeric",
  });
}

export function TodayEditionPane() {
  const { isPhone, sidebarCollapsed, selectedArticleId, openArticleFromToday, setPhonePane } = useUiStore();
  const { data, isLoading, isError, error, window: todayWin, setConsumed, ledeProgress, isWritingLedes, canRetryLedes, retryLedes, refetch, aiEnabled } =
    useTodayEdition();

  const [theme, setTheme] = useState<string | null>(null);
  const [sharedOnly, setSharedOnly] = useState(false);
  const refreshFeeds = useRefreshAllFeeds();
  const isFrontPage = !isPhone && !selectedArticleId;
  const items = data?.items ?? [];
  const themes = [...new Set(items.flatMap((item) => item.editorial?.theme ? [item.editorial.theme] : []))];
  const activeTheme = themes.includes(theme ?? "") ? theme : null;
  const visibleItems = items.map((item, index) => ({ item, index })).filter(({ item }) =>
    (!activeTheme || item.editorial?.theme === activeTheme) &&
    (!sharedOnly || item.member_articles.filter((member) => member.membership_type !== "duplicate").length > 1));
  const briefsStart = visibleItems.find(({ index }) => rankFor(index) === "brief")?.index;

  const handleOpenArticle = (articleId: string) => {
    openArticleFromToday(articleId);
  };

  const totalCount = data?.total_count ?? 0;
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
      {/* Top bar */}
      <div
        className="flex flex-shrink-0 items-center gap-2 relative z-20"
        style={{
          height: isPhone ? 52 : 44,
          paddingLeft: 8,
          paddingRight: isPhone ? 8 : 16,
        }}
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
        <ModelPicker surface="today" compact disabled={isWritingLedes} />
        <button className="today-story-control text-text-secondary hover:text-text-primary" disabled={refreshFeeds.isPending} onClick={() => refreshFeeds.mutate(undefined)}>
          {refreshFeeds.isPending ? "Refreshing…" : "Refresh feeds"}
        </button>
      </div>

      <div className="today-scroll flex-1 overflow-y-auto">
      <div className="today-content">
      <header className="today-masthead">
        <p className="today-edition-label">Your daily edition</p>
        <h2 className="today-title" aria-label="Skim daily edition">Skim</h2>
        <div className="today-edition-meta">
          <span>Today · {formatWindowDate(todayWin.startsAt)}</span>
          {totalCount > 0 && <span>{isFullyConsumed ? "All caught up" : `${consumedCount} of ${totalCount} done`}</span>}
        </div>
        {totalCount > 0 && <progress className="today-reading-progress" value={consumedCount} max={totalCount} aria-label="Edition reading progress">{progressPct}%</progress>}
      </header>

      {/* Body */}
        {isLoading && (
          <div className="flex items-center justify-center h-32">
            <span className="text-text-muted" style={{ fontSize: 14 }}>Loading...</span>
          </div>
        )}

        {isError && (
          <div role="alert" className="text-danger" style={{ fontSize: 13, padding: "12px 4px" }}>
            <p>{error instanceof Error ? error.message : "Could not load today's edition."}</p>
            <button className="today-story-control text-text-primary" onClick={() => void refetch()}>Try again</button>
          </div>
        )}

        {refreshFeeds.isError && <p role="alert" className="text-danger" style={{ fontSize: 13 }}>Could not refresh feeds. Please try again.</p>}
        {setConsumed.isError && <p role="alert" className="text-danger" style={{ fontSize: 13 }}>Could not save reading progress. Please try again.</p>}

        {!isLoading && !isError && totalCount === 0 && (
          <div className="flex flex-col items-center justify-center px-6 text-center" style={{ minHeight: 220 }}>
            <svg
              width="34"
              height="34"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              className="text-text-muted mb-3 opacity-45"
            >
              <path d="M13 2L3 14h9l-1 8 10-12h-9z" />
            </svg>
            <p className="text-text-secondary" style={{ fontSize: 14, fontWeight: 600, marginBottom: 5 }}>
              No stories yet today
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

        {!isLoading && !isError && canRetryLedes && (
          <button type="button" onClick={retryLedes}
            className="today-story-control text-text-secondary border border-white/10 bg-white/5"
            style={{ marginTop: 14 }}>
            Retry summaries
          </button>
        )}

        {!isLoading && !isError && items.length > 0 && <>
          {!aiEnabled && items.some((item) => !item.editorial) && <p className="today-summary-note">Unprepared summaries show source excerpts. <button className="today-story-control text-accent" onClick={() => useUiStore.getState().setShowSettings(true)}>Set up AI for thematic summaries</button></p>}
          <nav className="today-themes" aria-label="Newspaper themes">
            <button className="today-story-control" aria-pressed={!activeTheme && !sharedOnly} onClick={() => { setTheme(null); setSharedOnly(false); }}>All stories</button>
            {themes.map((name) => <button key={name} className="today-story-control" aria-pressed={activeTheme === name} onClick={() => setTheme(activeTheme === name ? null : name)}>{name}</button>)}
            <button className="today-story-control" aria-pressed={sharedOnly} onClick={() => setSharedOnly(!sharedOnly)}>Multiple reports</button>
          </nav>
          {visibleItems.length === 0 && <p className="today-summary-note">No stories with multiple reports in this selection.</p>}
        </>}
        <div className="today-stories">
        {!isLoading &&
          !isError &&
          visibleItems.map(({ item, index }) => (
            <Fragment key={item.story_id}>
              {index === briefsStart && (
                <div
                  className="today-briefs-label text-text-muted uppercase font-bold"
                  style={{ fontSize: 10.5, letterSpacing: 1.2, marginTop: 24 }}
                >
                  In brief
                </div>
              )}
              <div className={`today-story-cell today-story-cell--${rankFor(index)}`}>
              <TodayStory
                item={item}
                rank={rankFor(index)}
                isWritingLede={isWritingLedes}
                isSaving={setConsumed.isPending}
                onToggleConsumed={(storyId, isConsumed) => setConsumed.mutate({ storyId, isConsumed })}
                onOpenArticle={handleOpenArticle}
              />
              </div>
            </Fragment>
          ))}
        </div>

        {isFullyConsumed && (
          <div
            className="rounded-xl border border-success/20 text-center"
            style={{ padding: "14px 16px", marginTop: 18, background: "rgba(34, 197, 94, 0.06)" }}
          >
            <p className="text-text-primary" style={{ fontSize: 13, fontWeight: 500 }}>
              You&apos;re all caught up for today.
            </p>
          </div>
        )}
      </div>
      </div>
    </div>
  );
}
