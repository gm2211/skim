import "./TodayStorySkeleton.css";

export type TodayStorySkeletonRank = "lead" | "story" | "brief";

interface TodayStorySkeletonProps {
  rank: TodayStorySkeletonRank;
}

/** Newspaper-shaped loading placeholder with no invented story content. */
export function TodayStorySkeleton({ rank }: TodayStorySkeletonProps) {
  const lead = rank === "lead";
  const brief = rank === "brief";

  return (
    <article
      className={`today-story today-story--${rank} today-story-skeleton`}
      aria-label="Preparing story"
      aria-busy="true"
      role="status"
    >
      <div className="today-story-skeleton-byline" aria-hidden="true">
        <span className="today-story-skeleton-bar" />
      </div>
      {lead && <div className="today-story-skeleton-image" aria-hidden="true" />}
      <h3 className="today-story-skeleton-headline" aria-hidden="true">
        <span className="today-story-skeleton-bar" />
        {!brief && <span className="today-story-skeleton-bar" />}
        {!brief && <span className="today-story-skeleton-bar" />}
      </h3>
      {!brief && (
        <div className="today-story-skeleton-summary" aria-hidden="true">
          <span className="today-story-skeleton-bar" />
          <span className="today-story-skeleton-bar" />
          {lead && <span className="today-story-skeleton-bar" />}
        </div>
      )}
    </article>
  );
}
