import { useId, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { TodayEditionItem, TodayEditionMemberArticle } from "../../services/types";

export type StoryRank = "lead" | "story" | "brief";

interface Props {
  item: TodayEditionItem;
  rank: StoryRank;
  isWritingLede: boolean;
  isSaving?: boolean;
  onToggleConsumed: (storyId: string, isConsumed: boolean) => void;
  onOpenArticle: (articleId: string) => void;
}

function Reference({ member, onOpenArticle }: {
  member: TodayEditionMemberArticle;
  onOpenArticle: (articleId: string) => void;
}) {
  const isDeleted = member.is_read === null;
  const activate = () => {
    if (isDeleted) {
      if (member.url) void openUrl(member.url);
    } else {
      onOpenArticle(member.article_id);
    }
  };
  const content = <>
    <span className="text-accent font-semibold">{member.publication || member.feed_title}</span>
    <span className="text-text-secondary group-hover:text-text-primary">{member.title}</span>
    <span className="text-text-secondary">{member.published_at == null
      ? "Published: unknown"
      : `Published ${new Date(member.published_at * 1000).toLocaleString()}`}</span>
    {member.membership_type === "duplicate" && <span className="text-text-muted">Syndicated report</span>}
  </>;

  if (isDeleted && !member.url) {
    return <div className="today-reference" title={member.title}>{content}</div>;
  }

  return (
    <button
      onClick={activate}
      className="today-reference group"
      title={member.title}
    >
      {content}
    </button>
  );
}

function PreviewAttribution({ member, onOpenArticle }: {
  member: TodayEditionMemberArticle;
  onOpenArticle: (articleId: string) => void;
}) {
  const isDeleted = member.is_read === null;
  const activate = () => {
    if (isDeleted) {
      if (member.url) void openUrl(member.url);
    } else {
      onOpenArticle(member.article_id);
    }
  };
  const content = <>
    <span>Report preview · {member.publication || member.feed_title}</span>
    <span className="underline">{member.title}</span>
      <span className="text-text-secondary">{member.published_at == null
      ? "Published: unknown"
      : `Published ${new Date(member.published_at * 1000).toLocaleString()}`}</span>
  </>;
  const label = `Report preview from ${member.publication || member.feed_title}: ${member.title}${member.published_at == null ? ", published time unknown" : `, published ${new Date(member.published_at * 1000).toLocaleString()}`}`;
  const style = {
    display: "flex",
    flexDirection: "column" as const,
    alignItems: "flex-start",
    justifyContent: "center",
    flexWrap: "nowrap" as const,
    gap: 3,
    width: "100%",
    minHeight: 44,
    padding: 0,
    textAlign: "left" as const,
  };

  if (isDeleted && !member.url) {
    return <div className="today-story-control text-accent" style={style} aria-label={label}>{content}</div>;
  }

  return (
    <button
      className="today-story-control text-accent hover:text-text-primary"
      style={style}
      onClick={activate}
      aria-label={label}
    >
      {content}
    </button>
  );
}

export function TodayStory({ item, rank, isWritingLede, isSaving = false, onToggleConsumed, onOpenArticle }: Props) {
  const [expanded, setExpanded] = useState(false);
  const referencesId = useId();
  // Every report remains available on request, including syndicated copies.
  // The collapsed newspaper presents the story once.
  const members = item.member_articles;
  const primary = members.find((member) => member.is_representative) ?? members[0];
  const articleId = item.representative_article_id ?? primary?.article_id;
  const lead = rank === "lead";
  const brief = rank === "brief";
  const body = item.lede?.trim() || (brief ? "" : item.snapshot_summary);
  const ledeSourceArticleId = item.lede_source_article_id;
  const ledeSource = item.lede?.trim() && ledeSourceArticleId
    ? members.find((member) => member.article_id === ledeSourceArticleId)
    : undefined;
  const awaitingLede = !brief && !item.lede && isWritingLede;

  return (
    <article className="story-rise-in today-story">
      <h3
        className={`text-text-primary ${lead ? "today-lead-headline" : ""}`}
        style={{ fontSize: lead ? undefined : brief ? 14 : 16, fontWeight: lead ? 700 : 600, lineHeight: 1.3, letterSpacing: lead ? -0.3 : -0.1 }}
      >
        {articleId ? (
          <button className="today-headline hover:text-accent transition-colors" onClick={() => onOpenArticle(articleId)}>
            {item.snapshot_title}
          </button>
        ) : item.snapshot_title}
      </h3>

      {body && <p className={`text-text-secondary ${lead ? "today-lead-summary" : ""}`} style={{ marginTop: 8, fontSize: lead ? undefined : 13, lineHeight: 1.65 }}>{body}</p>}
      {ledeSource && item.lede?.trim() && (
        <PreviewAttribution member={ledeSource} onOpenArticle={onOpenArticle} />
      )}
      {awaitingLede && (
        <div role="status" className="text-text-muted" style={{ fontSize: 12, marginTop: 8 }}>
          Preparing summary…
          <div className="story-rule-live" style={{ height: 2, borderRadius: 999, marginTop: 6 }} />
        </div>
      )}
      {item.has_material_update && item.snapshot_delta_summary && !brief && (
        <p className="text-accent" style={{ marginTop: 8, fontSize: 13, lineHeight: 1.5 }}>
          What&apos;s new: {item.snapshot_delta_summary}
        </p>
      )}

      <div className="today-story-actions">
        {members.length > 0 && (
          <button
            className="today-story-control text-text-secondary hover:text-text-primary"
            aria-expanded={expanded}
            aria-controls={referencesId}
            onClick={() => setExpanded(!expanded)}
          >
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true" style={{ transform: expanded ? "rotate(90deg)" : undefined }}><path d="m9 5 7 7-7 7" /></svg>
            {members.length} {members.length === 1 ? "report" : "reports"}
          </button>
        )}
        <button
          disabled={isSaving}
          onClick={() => onToggleConsumed(item.story_id, !item.is_consumed)}
          className="today-story-control text-text-secondary hover:text-text-primary disabled:opacity-60"
          aria-label={item.is_consumed ? "Mark as unread" : "Mark as read"}
          aria-pressed={item.is_consumed}
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true"><circle cx="12" cy="12" r="9" />{item.is_consumed && <path d="m7.5 12 3 3 6-6" />}</svg>
          {isSaving ? "Saving…" : item.is_consumed ? "Read" : "Mark read"}
        </button>
      </div>
      {expanded && (
        <div id={referencesId} className="today-references" aria-label="Story reports">
          {members.map((member) => <Reference key={member.article_id} member={member} onOpenArticle={onOpenArticle} />)}
        </div>
      )}
    </article>
  );
}
