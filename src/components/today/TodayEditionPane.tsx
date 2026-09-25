import { Fragment } from "react";
import { CollapsedSidebarTitlebar } from "../layout/CollapsedSidebarTitlebar";
import { useRefreshAllFeeds } from "../../hooks/useFeeds";
import { useTodayEdition } from "../../hooks/useTodayEdition";
import { useUiStore } from "../../stores/uiStore";
import { rankFor, LEAD_COUNT } from "../../lib/todayEdition";
import { TodayStory } from "./TodayStory";

function formatWindowDate(startsAtSeconds: number): string {
  return new Date(startsAtSeconds * 1000).toLocaleDateString("en-US", {
    weekday: "long",
    month: "long",
    day: "numeric",
  });
}

export function TodayEditionPane() {
  const { isPhone, sidebarCollapsed, selectedArticleId, openArticleFromToday, setPhonePane } = useUiStore();
  const { data, isLoading, isError, error, window: todayWin, setConsumed, ledeProgress, isWritingLedes, canRetryLedes, retryLedes, refetch,
    preparationStatus, preparationLoading, preparationError, preparationStatusError, retryPreparation, retryPreparationStatus, isRetryingPreparation, openUpdatedEdition, isPublishingPreparation } =
    useTodayEdition();

  const refreshFeeds = useRefreshAllFeeds();
  const isFrontPage = !isPhone && !selectedArticleId;
  const items = data?.items ?? [];
  const briefsStart = items.findIndex((_, index) => rankFor(index) === "brief");

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
        <button className="today-story-control text-text-secondary hover:text-text-primary" disabled={refreshFeeds.isPending} onClick={() => refreshFeeds.mutate(undefined)}>
          {refreshFeeds.isPending ? "Refreshing…" : "Refresh feeds"}
        </button>
      </div>

      <div className="flex-1 overflow-y-auto" style={{ padding: "0 24px 24px" }}>
      <div className="today-content">
      {/* Title + progress */}
      <div className="today-masthead" style={{ padding: "8px 0 14px" }}>
        <h2 style={{ fontWeight: 700 }} className="today-title text-text-primary truncate">
          Today
        </h2>
        <p className="text-text-muted" style={{ fontSize: 13, marginTop: 2 }}>
          {formatWindowDate(todayWin.startsAt)}
        </p>
        {totalCount > 0 && (
          <div style={{ marginTop: 10 }}>
            <div className="flex items-center justify-between" style={{ marginBottom: 4 }}>
              <span className="text-text-muted" style={{ fontSize: 12 }}>
                {isFullyConsumed ? "All caught up" : `${consumedCount} of ${totalCount} done`}
              </span>
              <span className="text-text-muted tabular-nums" style={{ fontSize: 12 }}>
                {progressPct}%
              </span>
            </div>
            <div className="rounded-full bg-white/8" style={{ height: 4, overflow: "hidden" }}>
              <div
                className={`h-full rounded-full transition-all ${isFullyConsumed ? "bg-success" : "bg-accent"}`}
                style={{ width: `${progressPct}%` }}
              />
            </div>
          </div>
        )}
      </div>

      {preparationLoading && !preparationStatus && (
        <div role="status" aria-live="polite" className="text-text-muted" style={{ fontSize: 12, padding: "8px 0 12px" }}>
          Checking today&apos;s coverage…
        </div>
      )}
      {preparationStatus && preparationStatus.state !== "disabled" && preparationStatus.state !== "empty" && (
        <section aria-label="Today coverage preparation" aria-live="polite" className="border border-white/10 rounded-xl bg-white/[0.025]" style={{ padding: "10px 12px", marginBottom: 10 }}>
          <div className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-2 sm:gap-3">
            <div className="min-w-0">
              <p className="text-text-secondary" style={{ fontSize: 12, fontWeight: 600 }}>
                {preparationStatus.state === "ready" ? "Updated edition ready" : preparationStatus.state === "failed"
                  ? preparationStatus.assessment_failed_count > 0 ? "Some stories could not be reviewed" : "Related-report checks need another look"
                  : "Preparing today’s update"}
              </p>
              <p className="text-text-muted" style={{ fontSize: 11, lineHeight: 1.5, marginTop: 3 }}>
                {preparationStatus.assessed_count} of {preparationStatus.eligible_count} stories reviewed
                {" · "}{preparationStatus.state === "ready" ? "Related-report checks finished" : preparationStatus.state === "failed"
                  ? preparationStatus.assessment_failed_count > 0 ? "Review is incomplete" : "Some related reports need another check"
                  : preparationStatus.assessed_count < preparationStatus.eligible_count ? "Reviewing stories" : "Checking related reports"}
              </p>
              {preparationStatus.assessment_failed_count > 0 && (
                <p className="text-text-muted" style={{ fontSize: 11, marginTop: 3 }}>
                  {preparationStatus.assessment_failed_count} {preparationStatus.assessment_failed_count === 1 ? "story could" : "stories could"} not be reviewed.
                </p>
              )}
            </div>
            {preparationStatus.can_publish && (
              <button type="button" className="today-story-control text-text-primary border border-white/10 bg-white/5 flex-shrink-0 w-full sm:w-auto"
                disabled={isPublishingPreparation} onClick={() => void openUpdatedEdition()}>
                {isPublishingPreparation ? "Opening…" : "Open updated edition"}
              </button>
            )}
            {(preparationStatus.state === "failed" || preparationError) && (
              <button type="button" className="today-story-control text-text-secondary border border-white/10 bg-white/5 flex-shrink-0 w-full sm:w-auto"
                disabled={isRetryingPreparation} onClick={() => void retryPreparation()}>
                {isRetryingPreparation ? "Retrying…" : "Retry checks"}
              </button>
            )}
          </div>
          {preparationStatus.state === "preparing" && <div className="story-rule-live" style={{ height: 2, borderRadius: 999, marginTop: 8 }} />}
          {preparationError && <p role="alert" className="text-danger" style={{ fontSize: 11, marginTop: 6 }}>{preparationError}</p>}
        </section>
      )}
      {preparationStatusError && (
        <div role="alert" className="text-danger" style={{ fontSize: 12, padding: "8px 0 12px" }}>
          Could not load story coverage status. <button className="today-story-control text-text-primary" onClick={() => void retryPreparationStatus()}>Retry status</button>
        </div>
      )}

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

        <div className="today-stories">
        {!isLoading &&
          !isError &&
          items.map((item, index) => (
            <Fragment key={item.story_id}>
              {index === briefsStart && (
                <div
                  className="today-briefs-label text-text-muted uppercase font-bold"
                  style={{ fontSize: 10.5, letterSpacing: 1.2, marginTop: 24 }}
                >
                  Also
                </div>
              )}
              <div className="today-story-cell">
              <TodayStory
                item={item}
                rank={rankFor(index)}
                isWritingLede={isWritingLedes && index < LEAD_COUNT}
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
