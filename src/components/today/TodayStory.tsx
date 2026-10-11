import { useId, useMemo, useState } from "react";
import { IconButton, RefreshIcon } from "../common/IconButton";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { TodayEditionItem, TodayEditionMemberArticle } from "../../services/types";

import { useArticle } from "../../hooks/useArticles";

export type StoryRank = "lead" | "story" | "brief";

interface Props {
  item: TodayEditionItem;
  rank: StoryRank;
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

/** A short, readable time for a byline: the clock today, the date otherwise. */
function bylineTime(publishedAt: number | null): string {
  if (publishedAt == null) return "time unknown";
  const date = new Date(publishedAt * 1000);
  const today = new Date();
  const sameDay = date.toDateString() === today.toDateString();
  return sameDay
    ? date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
    : date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

/**
 * Names the report the lede was written from, as a byline under the lede:
 * the publication, then the report's own title and when it was published.
 */
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
  const publication = member.publication || member.feed_title;
  const content = <>
    <span className="today-byline-kicker">Report preview · {publication}</span>
    <span className="today-byline-title">
      <span className="today-byline-report">{member.title}</span>
      <span className="text-text-muted"> · Published {bylineTime(member.published_at)}</span>
    </span>
  </>;
  const label = `Report preview from ${publication}: ${member.title}${member.published_at == null ? ", published time unknown" : `, published ${new Date(member.published_at * 1000).toLocaleString()}`}`;

  if (isDeleted && !member.url) {
    return <div className="today-story-control today-byline" aria-label={label}>{content}</div>;
  }

  return (
    <button
      className="today-story-control today-byline group"
      onClick={activate}
      aria-label={label}
    >
      {content}
    </button>
  );
}

// Only images already supplied in the report are used; no unrelated stock art.
function ReportImage({ articleId, title }: { articleId: string; title: string }) {
  const { data: article } = useArticle(articleId);
  const [failedUrl, setFailedUrl] = useState<string | null>(null);
  const image = useMemo(() => {
    if (!article?.content_html) return null;
    const doc = new DOMParser().parseFromString(article.content_html, "text/html");
    for (const node of doc.querySelectorAll("img")) {
      const src = node.getAttribute("src");
      if (!src || /feedburner|pixel|badge/i.test(src)) continue;
      const width = Number(node.getAttribute("width"));
      const height = Number(node.getAttribute("height"));
      if ((width > 0 && width < 100) || (height > 0 && height < 100)) continue;
      try {
        const url = new URL(src, article.url || undefined);
        if (url.protocol === "https:" || url.protocol === "http:") return url.href;
      } catch { /* An invalid source should not leave a broken illustration. */ }
    }
    return null;
  }, [article?.content_html, article?.url]);
  if (!image || image === failedUrl) return null;
  return <img className="today-report-image" src={image} alt={`Image from report: ${title}`} referrerPolicy="no-referrer" onError={() => setFailedUrl(image)} />;
}

export function TodayStory({ item, rank, isSaving = false, onToggleConsumed, onOpenArticle }: Props) {
  const [expanded, setExpanded] = useState(false);
  const referencesId = useId();
  // Every report remains available on request, including syndicated copies.
  // The collapsed newspaper presents the story once.
  const members = item.member_articles;
  const primary = members.find((member) => member.is_representative) ?? members[0];
  const articleId = item.representative_article_id ?? primary?.article_id;
  const lead = rank === "lead";
  const brief = rank === "brief";
  const body = item.editorial?.summary.trim() || item.lede?.trim() || (brief ? "" : item.snapshot_summary);
  const ledeSourceArticleId = item.lede_source_article_id;
  const ledeSource = item.lede?.trim() && ledeSourceArticleId
    ? members.find((member) => member.article_id === ledeSourceArticleId)
    : undefined;
  const coverageCount = members.filter((member) => member.membership_type !== "duplicate").length;

  return (
    <article className={`story-rise-in today-story today-story--${rank}`}>
      <div className="today-byline">
        {item.editorial?.theme || primary?.publication || primary?.feed_title}
        {coverageCount > 1 && <span className="today-coverage"> · {coverageCount} reports covering this story</span>}
      </div>
      {lead && articleId && primary?.is_read !== null && <ReportImage key={articleId} articleId={articleId} title={item.snapshot_title} />}

      <h3
        className={`catchup-headline text-text-primary ${lead ? "today-lead-headline" : ""}`}
        style={{ fontSize: lead ? undefined : brief ? 15 : 19, fontWeight: 700, lineHeight: lead ? 1.12 : 1.22, letterSpacing: lead ? -0.5 : -0.15 }}
      >
        {articleId ? (
          <button className="today-headline hover:text-accent transition-colors" onClick={() => onOpenArticle(articleId)}>
            {item.snapshot_title}
          </button>
        ) : item.snapshot_title}
      </h3>

      {body && <p className={`today-body text-text-primary ${lead ? "today-lead-summary" : ""}`} style={{ marginTop: lead ? 10 : 7, fontSize: lead ? undefined : 13.5, lineHeight: 1.55 }}>{body}</p>}
      {body && item.editorial && (
        <p className="today-summary-kind">AI summary · Based on {item.editorial.sources.length} of {members.length} {members.length === 1 ? "report" : "reports"}</p>
      )}
      {!item.editorial && ledeSource && item.lede?.trim() && (
        <PreviewAttribution member={ledeSource} onOpenArticle={onOpenArticle} />
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
        <IconButton
          disabled={isSaving}
          tooltipAlign="left"
          tooltipSide="top"
          aria-busy={isSaving}
          tooltip={isSaving ? "Saving…" : item.is_consumed ? "Mark as unread" : "Mark as read"}
          onClick={() => onToggleConsumed(item.story_id, !item.is_consumed)}
          className="text-text-secondary hover:text-text-primary hover:bg-white/10"
          label={item.is_consumed ? "Mark as unread" : "Mark as read"}
          aria-pressed={item.is_consumed}
        >
          {isSaving ? <RefreshIcon spinning /> : <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true"><circle cx="12" cy="12" r="9" />{item.is_consumed && <path d="m7.5 12 3 3 6-6" />}</svg>}
        </IconButton>
        <span role="status" className="sr-only">{isSaving ? "Saving reading progress…" : ""}</span>
      </div>
      {expanded && (
        <div id={referencesId} className="today-references" aria-label="Story reports">
          {members.map((member) => <div key={member.article_id}>
            <Reference member={member} onOpenArticle={onOpenArticle} />
            {item.editorial?.sources.filter((source) => source.article_id === member.article_id).map((source, index) => (
              <blockquote className="today-evidence" key={index}>{source.quote}</blockquote>
            ))}
          </div>)}
        </div>
      )}
    </article>
  );
}
