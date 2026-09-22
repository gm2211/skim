import { useState } from "react";
import type { TodayEditionItem, TodayEditionMemberArticle } from "../../services/types";

/** Bylines beyond this collapse behind a "+N more" control. */
const COLLAPSED_SOURCE_COUNT = 3;

export type StoryRank = "lead" | "story" | "brief";

interface Props {
  item: TodayEditionItem;
  rank: StoryRank;
  /** True while the lede pass is still working toward this story. */
  isWritingLede: boolean;
  onToggleConsumed: (storyId: string, isConsumed: boolean) => void;
  onOpenArticle: (articleId: string) => void;
}

/** The articles behind a story, printed the way a byline is. */
function Byline({
  member,
  onOpenArticle,
}: {
  member: TodayEditionMemberArticle;
  onOpenArticle: (articleId: string) => void;
}) {
  return (
    <button
      onClick={() => onOpenArticle(member.article_id)}
      className="flex items-baseline gap-2 w-full text-left group min-w-0"
      style={{ padding: "2px 0" }}
      title={member.title}
    >
      <span className="text-accent flex-shrink-0" style={{ fontSize: 11.5, fontWeight: 600 }}>
        {member.publication}
      </span>
      <span
        className="truncate text-text-muted group-hover:text-text-primary transition-colors"
        style={{ fontSize: 11.5 }}
      >
        {member.title}
      </span>
      {member.is_read === false && (
        <span
          className="rounded-full bg-accent flex-shrink-0"
          style={{ width: 5, height: 5 }}
          title="Unread"
        />
      )}
    </button>
  );
}

function LedeSkeleton({ lead }: { lead: boolean }) {
  const widths = lead ? ["100%", "92%", "68%"] : ["100%", "78%"];
  return (
    <div
      className="flex flex-col"
      style={{ marginTop: 8, gap: 7 }}
      aria-label="Writing this story"
    >
      {widths.map((width) => (
        <div key={width} className="story-skeleton-line" style={{ width }} />
      ))}
    </div>
  );
}

export function TodayStory({
  item,
  rank,
  isWritingLede,
  onToggleConsumed,
  onOpenArticle,
}: Props) {
  const [expanded, setExpanded] = useState(false);
  const members = item.member_articles.filter((member) => member.membership_type !== "duplicate");
  const visible = expanded ? members : members.slice(0, COLLAPSED_SOURCE_COUNT);
  const hiddenCount = members.length - visible.length;

  const lead = rank === "lead";
  const brief = rank === "brief";
  // A written lede is the story; the mechanical excerpt is the stand-in until
  // one arrives, and briefs never get one.
  const body = item.lede?.trim() || (brief ? "" : item.snapshot_summary);
  const awaitingLede = !brief && !item.lede && isWritingLede;

  return (
    <article
      className="story-rise-in"
      style={{
        borderTop: "1px solid rgba(255,255,255,0.07)",
        paddingTop: lead ? 16 : 14,
        marginTop: lead ? 16 : 14,
        opacity: item.is_consumed ? 0.55 : 1,
      }}
    >
      <h3
        onClick={
          item.representative_article_id
            ? () => onOpenArticle(item.representative_article_id!)
            : undefined
        }
        className={`text-text-primary ${item.representative_article_id ? "cursor-pointer hover:text-accent transition-colors" : ""}`}
        style={{
          fontSize: lead ? 20 : brief ? 13.5 : 15.5,
          fontWeight: lead ? 700 : brief ? 600 : 650,
          lineHeight: lead ? 1.22 : 1.35,
          letterSpacing: lead ? -0.3 : -0.1,
        }}
      >
        {item.snapshot_title}
      </h3>

      {awaitingLede ? (
        <LedeSkeleton lead={lead} />
      ) : (
        body && (
          <p
            className="text-text-secondary"
            style={{
              marginTop: lead ? 8 : 5,
              fontSize: lead ? 14 : 12.5,
              lineHeight: 1.6,
            }}
          >
            {body}
          </p>
        )
      )}

      {item.snapshot_delta_summary && !brief && (
        <p className="text-accent" style={{ marginTop: 6, fontSize: 12, lineHeight: 1.5 }}>
          What&apos;s new: {item.snapshot_delta_summary}
        </p>
      )}

      {visible.length > 0 && (
        <div className="flex flex-col" style={{ marginTop: 7 }}>
          {visible.map((member) => (
            <Byline key={member.article_id} member={member} onOpenArticle={onOpenArticle} />
          ))}
          {hiddenCount > 0 && (
            <button
              onClick={() => setExpanded(true)}
              className="text-text-muted hover:text-text-primary transition-colors text-left"
              style={{ padding: "2px 0", fontSize: 11.5 }}
            >
              +{hiddenCount} more source{hiddenCount === 1 ? "" : "s"}
            </button>
          )}
          {expanded && members.length > COLLAPSED_SOURCE_COUNT && (
            <button
              onClick={() => setExpanded(false)}
              className="text-text-muted hover:text-text-primary transition-colors text-left"
              style={{ padding: "2px 0", fontSize: 11.5 }}
            >
              Show fewer
            </button>
          )}
        </div>
      )}

      <button
        onClick={() => onToggleConsumed(item.story_id, !item.is_consumed)}
        className="text-text-muted hover:text-text-primary transition-colors"
        style={{ marginTop: 8, fontSize: 11.5 }}
      >
        {item.is_consumed ? "Mark as unread" : "Mark as read"}
      </button>
    </article>
  );
}
