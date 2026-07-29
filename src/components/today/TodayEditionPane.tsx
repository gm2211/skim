import { useMemo } from "react";
import { useTodayEdition } from "../../hooks/useTodayEdition";
import { useUiStore } from "../../stores/uiStore";
import { groupItemsBySection, SECTION_LABELS } from "../../lib/todayEdition";
import { TodayStoryCard } from "./TodayStoryCard";

function formatWindowDate(startsAtSeconds: number): string {
  return new Date(startsAtSeconds * 1000).toLocaleDateString("en-US", {
    weekday: "long",
    month: "long",
    day: "numeric",
  });
}

export function TodayEditionPane() {
  const { isPhone, sidebarCollapsed, openArticleFromToday, setPhonePane } = useUiStore();
  const { data, isLoading, isError, error, window: todayWin, setConsumed } = useTodayEdition();

  const sections = useMemo(() => groupItemsBySection(data?.items ?? []), [data]);

  const handleOpenArticle = (articleId: string) => {
    openArticleFromToday(articleId);
  };

  const totalCount = data?.total_count ?? 0;
  const consumedCount = data?.consumed_count ?? 0;
  const isFullyConsumed = totalCount > 0 && consumedCount === totalCount;
  const progressPct = totalCount > 0 ? Math.round((consumedCount / totalCount) * 100) : 0;

  return (
    <div
      className={`${!isPhone ? "border-r border-white/5" : ""} bg-bg-secondary/70 flex flex-col h-full overflow-hidden`}
      style={{
        width: isPhone ? "100%" : 420,
        minWidth: isPhone ? "100%" : 360,
      }}
    >
      {/* Top bar */}
      <div
        className="flex items-center gap-2"
        style={{
          height: isPhone ? 52 : 40,
          paddingLeft: isPhone ? 8 : sidebarCollapsed ? 78 : undefined,
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
        {sidebarCollapsed && !isPhone && (
          <button
            onClick={() => useUiStore.getState().toggleSidebar()}
            className="tap-target text-text-muted hover:text-text-primary transition-colors rounded-lg hover:bg-white/10"
            title="Expand sidebar"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <rect x="3" y="3" width="18" height="18" rx="2" />
              <path d="M9 3v18" />
            </svg>
          </button>
        )}
        <div className="flex-1" />
      </div>

      {/* Title + progress */}
      <div style={{ padding: "8px 24px 14px" }}>
        <h2 style={{ fontSize: 22, fontWeight: 700 }} className="text-text-primary truncate">
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

      {/* Body */}
      <div className="flex-1 overflow-y-auto" style={{ padding: "0 20px 20px" }}>
        {isLoading && (
          <div className="flex items-center justify-center h-32">
            <span className="text-text-muted" style={{ fontSize: 14 }}>Loading...</span>
          </div>
        )}

        {isError && (
          <p className="text-danger" style={{ fontSize: 12, padding: "12px 4px" }}>
            {error instanceof Error ? error.message : "Could not load today's edition."}
          </p>
        )}

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
              Refresh your feeds to pull in today&apos;s coverage — Today fills in as stories are clustered and ranked.
            </p>
          </div>
        )}

        {!isLoading &&
          !isError &&
          sections.map((group) => (
            <div key={group.section} style={{ marginTop: 18 }}>
              <div
                className="text-text-muted uppercase tracking-wider font-semibold"
                style={{ fontSize: 11, marginBottom: 8 }}
              >
                {SECTION_LABELS[group.section]}
              </div>
              {group.items.map((item) => (
                <TodayStoryCard
                  key={item.story_id}
                  item={item}
                  onToggleConsumed={(storyId, isConsumed) => setConsumed.mutate({ storyId, isConsumed })}
                  onOpenArticle={handleOpenArticle}
                />
              ))}
            </div>
          ))}

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
  );
}
