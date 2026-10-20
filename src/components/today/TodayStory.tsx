import { useId, useState, type CSSProperties } from "react";
import { useQuery } from "@tanstack/react-query";
import { IconButton, RefreshIcon } from "../common/IconButton";
import { openUrl } from "@tauri-apps/plugin-opener";
import * as commands from "../../services/commands";
import { ChatIcon } from "../ui/icons";
import type { TodayEditionItem, TodayEditionMemberArticle } from "../../services/types";
import { firstSentence, isReadableExcerpt, themeColor, type StoryRank } from "../../lib/todayEdition";
import "./TodayStorySkeleton.css";

interface Props {
  item: TodayEditionItem;
  rank: StoryRank;
  isSaving?: boolean;
  onToggleConsumed: (storyId: string, isConsumed: boolean) => void;
  onOpenArticle: (articleId: string) => void;
  /** Opens a chat that reads this story's reports. */
  onAsk?: () => void;
  /** The story's AI summary is being written; its slot shimmers meanwhile. */
  isWritingSummary?: boolean;
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

// Slots restyle themselves with :has(.today-report-image), so a story whose
// picture is missing or fails to load still fills its place on the page.
// Only images the reports themselves publish are used; no unrelated stock art.
function ReportImage({ articleIds, title }: { articleIds: string[]; title: string }) {
  const { data: image } = useQuery({
    queryKey: ["todayStoryImage", ...articleIds],
    queryFn: () => commands.getTodayStoryImage(articleIds),
    staleTime: 10 * 60 * 1000,
  });
  const [failedUrl, setFailedUrl] = useState<string | null>(null);
  if (!image || image === failedUrl) return null;
  return <img className="today-report-image" src={image} alt={`Image from report: ${title}`} referrerPolicy="no-referrer"
    onError={() => setFailedUrl(image)} />;
}

/** A report's own sentence, set large where a picture would otherwise go. */
function PullQuote({ quote, source, large = false }: { quote: string; source?: string; large?: boolean }) {
  return (
    <blockquote className={`today-pull-quote ${large ? "today-pull-quote--large" : ""}`}>
      <p>{quote}</p>
      {source && <cite>{source}</cite>}
    </blockquote>
  );
}

function Figure({ value, label }: { value: string; label: string }) {
  return <p className="today-figure"><strong>{value}</strong><span>{label}</span></p>;
}

/** Ledes shorter than this stay in one column. */
const LEAD_COLUMNS_MIN_CHARS = 260;

export function TodayStory({ item, rank, isSaving = false, onToggleConsumed, onOpenArticle, onAsk, isWritingSummary = false }: Props) {
  const [expanded, setExpanded] = useState(false);
  const referencesId = useId();
  // Every report remains available on request, including syndicated copies.
  // The collapsed newspaper presents the story once.
  const members = item.member_articles;
  const primary = members.find((member) => member.is_representative) ?? members[0];
  // A report the app no longer keeps can't open in the reader, so the
  // headline opens one it still has, or the web page when none is left.
  const live = (id: string | null | undefined) => members.find((member) => member.article_id === id && member.is_read !== null);
  const opens = live(item.representative_article_id) ?? live(primary?.article_id) ?? members.find((member) => member.is_read !== null);
  const articleId = opens?.article_id ?? item.representative_article_id ?? primary?.article_id;
  const webUrl = opens ? undefined : (primary?.url ?? members.find((member) => member.url)?.url ?? undefined);
  const lead = rank === "lead";
  const brief = rank === "brief";
  const compact = rank === "rail" || brief;
  const excerpt = isReadableExcerpt(item.snapshot_summary) ? item.snapshot_summary : "";
  const summary = item.editorial?.summary.trim() ?? "";
  const fullBody = summary || item.lede?.trim() || excerpt;
  // Briefs keep one sentence. The rail runs the whole AI summary; cut to its
  // first sentence it read like the feed's own snippet.
  const body = fullBody && (brief || (compact && !summary)) ? firstSentence(fullBody) : fullBody;
  const ledeSourceArticleId = item.lede_source_article_id;
  const ledeSource = item.lede?.trim() && ledeSourceArticleId
    ? members.find((member) => member.article_id === ledeSourceArticleId)
    : undefined;
  const coverageCount = members.filter((member) => member.membership_type !== "duplicate").length;
  const publicationOf = (id: string) => {
    const member = members.find((candidate) => candidate.article_id === id);
    return member ? member.publication || member.feed_title : undefined;
  };
  const quotes = (item.editorial?.sources ?? []).filter((source) => source.quote.trim());
  const figure = item.editorial?.figure;
  const publications = [...new Set(members.filter((member) => member.membership_type !== "duplicate")
    .map((member) => member.publication || member.feed_title))];
  const showsImage = (lead || rank === "feature") && !!articleId && primary?.is_read !== null;
  // Image lookups prefer the representative report, then the rest of the coverage.
  const imageArticleIds = [articleId, ...members.map((member) => member.article_id)]
    .filter((id, index, ids): id is string => !!id && ids.indexOf(id) === index);
  const accent = themeColor(item.editorial?.theme);
  // A lead with little to show (a short lede, at most one quote, no figure)
  // ends well above a three-story rail; the front page then runs the rail
  // under it instead of beside it.
  const thinLead = lead && quotes.length <= 1 && !figure && (body?.length ?? 0) < LEAD_COLUMNS_MIN_CHARS;

  return (
    <article className={`story-rise-in today-story today-story--${rank} ${thinLead ? "today-story--thin-lead" : ""} ${item.is_consumed ? "today-story--read" : ""}`}
      style={accent ? { "--today-theme": accent } as CSSProperties : undefined}>
      {showsImage && <ReportImage key={imageArticleIds.join(",")} articleIds={imageArticleIds} title={item.snapshot_title} />}
      <div className="today-byline today-kicker">
        {item.editorial?.theme || primary?.publication || primary?.feed_title}
        {coverageCount > 1 && <span className="today-coverage"> · {coverageCount} reports covering this story</span>}
      </div>
      {rank === "feature" && figure && <Figure value={figure.value} label={figure.label} />}

      <h3 className={`catchup-headline text-text-primary ${lead ? "today-lead-headline" : ""}`}>
        {opens || webUrl ? (
          <button className="today-headline hover:text-accent transition-colors"
            onClick={() => { if (opens) onOpenArticle(opens.article_id); else if (webUrl) void openUrl(webUrl); }}>
            {item.snapshot_title}
          </button>
        ) : item.snapshot_title}
      </h3>

      {rank === "feature" && !figure && quotes[0] && <PullQuote quote={quotes[0].quote} large />}
      {/* A lead without a picture runs its lede in two columns, but only when
          there is enough of it: a short lede balanced across two columns can
          push the drop cap into the second one. */}
      {body && <p className={`today-body text-text-primary ${lead ? "today-lead-summary" : ""} ${lead && body.length >= LEAD_COLUMNS_MIN_CHARS ? "today-body--columns" : ""}`}>{body}</p>}
      {lead && figure && <Figure value={figure.value} label={figure.label} />}
      {lead && quotes.length > 0 && (
        <div className="today-lead-quotes">
          {quotes.slice(0, 2).map((source) => <PullQuote key={source.article_id} quote={source.quote} source={publicationOf(source.article_id)} />)}
        </div>
      )}
      {isWritingSummary && !summary && (
        <div className="today-summary-writing" role="status" aria-label="Writing summary">
          <span className="today-story-skeleton-bar" />
          <span className="today-story-skeleton-bar" />
        </div>
      )}
      {!isWritingSummary && !summary && item.editorial_error && (
        <p className="today-summary-failed" role="note">Not summarized: {item.editorial_error}</p>
      )}
      {body && item.editorial && !brief && (
        <p className="today-summary-kind">AI summary · Based on {item.editorial.sources.length} of {members.length} {members.length === 1 ? "report" : "reports"}</p>
      )}
      {!item.editorial && ledeSource && item.lede?.trim() && !compact && (
        <PreviewAttribution member={ledeSource} onOpenArticle={onOpenArticle} />
      )}
      {item.has_material_update && item.snapshot_delta_summary && !brief && (
        <p className="text-accent" style={{ marginTop: 8, fontSize: 13, lineHeight: 1.5 }}>
          What&apos;s new: {item.snapshot_delta_summary}
        </p>
      )}

      <div className="today-story-actions">
        {!compact && publications.length > 0 && (
          <span className="today-publications">{publications.slice(0, 2).join(", ")}{publications.length > 2 ? ` +${publications.length - 2}` : ""}</span>
        )}
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
        {onAsk && (
          <button className="today-story-control today-story-ask text-text-secondary hover:text-text-primary" onClick={onAsk} aria-label={`Ask about ${item.snapshot_title}`}>
            <ChatIcon size={14} />
            Ask
          </button>
        )}
        <IconButton
          disabled={isSaving}
          tooltipAlign="left"
          tooltipSide="top"
          aria-busy={isSaving}
          tooltip={isSaving ? "Saving…" : item.is_consumed ? "Mark as unread" : "Mark as read"}
          onClick={() => onToggleConsumed(item.story_id, !item.is_consumed)}
          className={`today-read-toggle ${item.is_consumed ? "text-success" : "text-text-secondary"} hover:text-text-primary hover:bg-white/10`}
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
