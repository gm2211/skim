import { useState } from "react";
import type { TodayEditionItem, TodayEditionMemberArticle } from "../../services/types";

const COLLAPSED_SOURCE_COUNT = 3;

const MEMBERSHIP_LABELS: Record<TodayEditionMemberArticle["membership_type"], string> = {
  coverage: "coverage",
  update: "update",
  duplicate: "duplicate",
};

interface Props {
  item: TodayEditionItem;
  onToggleConsumed: (storyId: string, isConsumed: boolean) => void;
  onOpenArticle: (articleId: string) => void;
}

function SourceRow({
  member,
  onOpenArticle,
}: {
  member: TodayEditionMemberArticle;
  onOpenArticle: (articleId: string) => void;
}) {
  const isDuplicate = member.membership_type === "duplicate";
  return (
    <button
      onClick={() => onOpenArticle(member.article_id)}
      className={`flex items-center gap-2 w-full text-left rounded-lg hover:bg-white/5 transition-colors ${
        isDuplicate ? "opacity-50" : ""
      }`}
      style={{ padding: "5px 8px" }}
      title={member.title}
    >
      {member.feed_icon_url && (
        <img
          src={member.feed_icon_url}
          alt=""
          className="rounded-sm flex-shrink-0"
          style={{ width: 13, height: 13 }}
          loading="lazy"
          onError={(e) => {
            (e.target as HTMLImageElement).style.display = "none";
          }}
        />
      )}
      <span
        className={`truncate flex-1 ${
          member.is_representative ? "text-text-primary" : "text-text-secondary"
        }`}
        style={{ fontSize: 12 }}
      >
        {member.feed_title}
      </span>
      <span
        className={`flex-shrink-0 rounded-full ${
          isDuplicate ? "bg-white/5 text-text-muted" : "bg-accent/10 text-accent"
        }`}
        style={{ padding: "1px 7px", fontSize: 10, textTransform: "uppercase", letterSpacing: 0.3 }}
      >
        {MEMBERSHIP_LABELS[member.membership_type]}
      </span>
      {member.is_read === false && (
        <span
          className="rounded-full bg-accent flex-shrink-0"
          style={{ width: 6, height: 6 }}
          title="Unread"
        />
      )}
    </button>
  );
}

export function TodayStoryCard({ item, onToggleConsumed, onOpenArticle }: Props) {
  const [expanded, setExpanded] = useState(false);
  const members = item.member_articles;
  const visibleMembers = expanded ? members : members.slice(0, COLLAPSED_SOURCE_COUNT);
  const hiddenCount = members.length - visibleMembers.length;

  return (
    <div
      className={`rounded-xl border border-white/8 transition-colors ${
        item.is_consumed ? "bg-white/2 opacity-70" : "bg-white/4"
      }`}
      style={{ padding: "14px 16px", marginBottom: 10 }}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2 flex-wrap" style={{ marginBottom: 6 }}>
            {item.is_unique_find && (
              <span
                className="rounded-full bg-warning/15 text-warning flex-shrink-0"
                style={{ padding: "2px 8px", fontSize: 10, fontWeight: 600, textTransform: "uppercase", letterSpacing: 0.4 }}
              >
                Unique find
              </span>
            )}
            <span className="text-text-muted" style={{ fontSize: 11 }}>
              {item.snapshot_source_count} source{item.snapshot_source_count === 1 ? "" : "s"}
            </span>
          </div>
          <h3
            className={item.is_consumed ? "text-text-muted" : "text-text-primary"}
            style={{ fontSize: 15, fontWeight: 600, lineHeight: 1.35, marginBottom: 6 }}
          >
            {item.snapshot_title}
          </h3>
          <p className="text-text-secondary" style={{ fontSize: 13, lineHeight: 1.55, marginBottom: item.snapshot_delta_summary ? 8 : 0 }}>
            {item.snapshot_summary}
          </p>
          {item.snapshot_delta_summary && (
            <div
              className="rounded-lg bg-accent/8 text-accent"
              style={{ padding: "6px 10px", fontSize: 12, lineHeight: 1.5 }}
            >
              What&apos;s new: {item.snapshot_delta_summary}
            </div>
          )}
        </div>
        <button
          onClick={() => onToggleConsumed(item.story_id, !item.is_consumed)}
          className={`flex-shrink-0 rounded-lg transition-colors ${
            item.is_consumed
              ? "bg-white/5 text-text-muted hover:bg-white/10"
              : "bg-accent/15 text-accent hover:bg-accent/25"
          }`}
          style={{ padding: "6px 12px", fontSize: 12, fontWeight: 500, whiteSpace: "nowrap" }}
        >
          {item.is_consumed ? "Undo" : "Mark done"}
        </button>
      </div>

      {members.length > 0 && (
        <div className="border-t border-white/5" style={{ marginTop: 12, paddingTop: 8 }}>
          <div className="flex flex-col">
            {visibleMembers.map((member) => (
              <SourceRow key={member.article_id} member={member} onOpenArticle={onOpenArticle} />
            ))}
          </div>
          {hiddenCount > 0 && (
            <button
              onClick={() => setExpanded(true)}
              className="text-accent hover:text-accent-hover transition-colors"
              style={{ padding: "4px 8px", fontSize: 12, fontWeight: 500 }}
            >
              +{hiddenCount} more source{hiddenCount === 1 ? "" : "s"}
            </button>
          )}
          {expanded && members.length > COLLAPSED_SOURCE_COUNT && (
            <button
              onClick={() => setExpanded(false)}
              className="text-text-muted hover:text-text-primary transition-colors"
              style={{ padding: "4px 8px", fontSize: 12 }}
            >
              Show fewer
            </button>
          )}
        </div>
      )}
    </div>
  );
}
