import { useState, type CSSProperties, type ReactNode } from "react";
import type { CatchupBrief, CatchupReport, CatchupSource, CatchupStory } from "../../services/commands";

/**
 * The Quick Catch-up report laid out as a newspaper front page.
 *
 * The lead runs across the top beside its picture. The next two stories share
 * a row under it, each with its picture on top; every story after that sits in
 * a two-column text grid with a small thumbnail. The briefs close the page as
 * a dense "Also" block. Stories are printed as their ledes land, so the page
 * can be shown mid-run with the trailing story still being written.
 */

interface Props {
  report: CatchupReport;
  /** The dateline printed over the page: when and what was read. */
  dateline: ReactNode;
  /** The line naming what the run read, printed on the dateline's right. */
  scopeSummary?: string | null;
  /** While the page is being written: what the backend is doing, and for how long. */
  status?: { message: string; elapsed: number } | null;
  loading: boolean;
  /** Stories whose lede is in. While loading only these plus the next print. */
  written: number;
  onOpenArticle: (articleId: string) => void;
}

const SERIF = '"New York", "Iowan Old Style", "Palatino", Georgia, "Times New Roman", serif';

/** Initials and a stable colour for a publication with no usable icon. */
export function publicationBadge(publication: string) {
  const words = publication.replace(/^www\./i, "").split(/[\s.\-_]+/).filter(Boolean);
  const initials = (words.length > 1 ? words[0][0] + words[1][0] : (words[0] ?? "S").slice(0, 2)).toUpperCase();
  const palette = ["#1f52fa", "#ad1a2b", "#5aa1ab", "#ed3b21", "#c9a227", "#852b4d"];
  let hash = 0;
  for (const ch of publication) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
  return { initials, color: palette[hash % palette.length] };
}

/** A publication's favicon, or its initials when there is none or it fails. */
export function PublicationIcon({ source, size }: { source: CatchupSource; size: number }) {
  const [failed, setFailed] = useState(false);
  if (source.icon_url && !failed) {
    return (
      <img
        src={source.icon_url}
        alt=""
        width={size}
        height={size}
        onError={() => setFailed(true)}
        style={{ width: size, height: size, borderRadius: size * 0.27, background: "rgba(255,255,255,0.92)", padding: 2, display: "block" }}
      />
    );
  }
  const { initials, color } = publicationBadge(source.publication);
  return (
    <span
      aria-hidden="true"
      className="flex items-center justify-center text-white"
      style={{ width: size, height: size, borderRadius: size * 0.27, background: color, fontSize: size * 0.42, fontWeight: 800, letterSpacing: -0.2 }}
    >
      {initials}
    </span>
  );
}

/** A story's picture; it removes itself when the image cannot load. */
function StoryImage({ src, style, onClick }: { src: string; style: CSSProperties; onClick?: () => void }) {
  const [failed, setFailed] = useState(false);
  if (failed) return null;
  return (
    <img
      src={src}
      alt=""
      loading="lazy"
      referrerPolicy="no-referrer"
      onError={() => setFailed(true)}
      onClick={onClick}
      className={`catchup-picture ${onClick ? "cursor-pointer" : ""}`}
      style={{ objectFit: "cover", display: "block", ...style }}
    />
  );
}

/** Shimmering rules where a lede is about to land. */
function LedeSkeleton({ lines }: { lines: number }) {
  const widths = ["100%", "92%", "68%", "84%"];
  return (
    <div className="flex flex-col" style={{ marginTop: 10, gap: 8 }} aria-label="Writing this story">
      {Array.from({ length: lines }, (_, i) => (
        <div key={i} className="story-skeleton-line" style={{ width: widths[i % widths.length] }} />
      ))}
    </div>
  );
}

/**
 * The page before there is one: the dateline over the shape of a front page,
 * drawn in faint rules. While a run is reading, the rules shimmer and the
 * dateline carries the backend's status; before a run, `children` sits over
 * the page as the invitation to start one.
 */
export function CatchupGhostPage({
  dateline,
  status,
  children,
}: {
  dateline: ReactNode;
  status?: { message: string; elapsed: number } | null;
  children?: ReactNode;
}) {
  const live = !!status;
  const line = (width: string, height = 9) => (
    <div className={live ? "story-skeleton-line" : "catchup-ghost-line"} style={{ width, height }} />
  );
  return (
    <div className="catchup-page catchup-ghost-page">
      <div className="catchup-dateline">
        <div className="catchup-dateline-row">
          <span>{dateline}</span>
          {status && (
            <span className="catchup-dateline-scope flex items-center" style={{ gap: 8 }}>
              <span>{status.message}</span>
              <span className="tabular-nums" style={{ opacity: 0.7 }}>{status.elapsed}s</span>
            </span>
          )}
        </div>
        <div className={`catchup-dateline-rule ${live ? "story-rule-live" : ""}`} />
      </div>
      <div className="catchup-ghost" style={{ opacity: live ? 1 : 0.55 }} aria-hidden="true">
        <div className="catchup-lead" style={{ borderBottomColor: "transparent" }}>
          <div className="catchup-lead-text flex flex-col" style={{ gap: 10 }}>
            {line("38%", 20)}
            {line("92%", 20)}
            {line("64%", 20)}
            <div style={{ height: 6 }} />
            {line("100%")}
            {line("96%")}
            {line("88%")}
            {line("52%")}
          </div>
          <div className={live ? "story-skeleton-line" : "catchup-ghost-line"} style={{ width: "100%", aspectRatio: "4 / 3", height: "auto", borderRadius: 6 }} />
        </div>
        <div className="catchup-tier catchup-features" style={{ borderBottomColor: "transparent", paddingTop: 0 }}>
          {[0, 1].map((i) => (
            <div key={i} className="flex flex-col" style={{ gap: 9 }}>
              <div className={live ? "story-skeleton-line" : "catchup-ghost-line"} style={{ width: "100%", aspectRatio: "21 / 9", height: "auto", borderRadius: 5, marginBottom: 4 }} />
              {line("84%", 15)}
              {line("100%")}
              {line("72%")}
            </div>
          ))}
        </div>
      </div>
      {children && <div className="catchup-ghost-overlay">{children}</div>}
    </div>
  );
}

export function CatchupFrontPage({ report, dateline, scopeSummary, status, loading, written, onOpenArticle }: Props) {
  const sourcesById = new Map<string, CatchupSource>();
  report.sources.forEach((s) => sourcesById.set(s.id, s));
  const cited = (ids: string[]) => ids.map((id) => sourcesById.get(id)).filter((s): s is CatchupSource => !!s);

  const open = (ids: string[]) => (ids[0] ? () => onOpenArticle(ids[0]) : undefined);

  // The articles behind a story, as a compact row of publication icons; each
  // one opens its article, and hovering names it.
  const renderRelated = (ids: string[], size = 20) => {
    const sources = cited(ids);
    if (sources.length === 0) return null;
    return (
      <div className="catchup-related flex items-center flex-wrap" style={{ marginTop: 10, gap: 5 }}>
        {sources.map((source) => (
          <button
            key={source.id}
            onClick={(e) => {
              e.stopPropagation();
              onOpenArticle(source.id);
            }}
            title={source.title}
            aria-label={`${source.title}, ${source.publication}`}
            className="catchup-source-icon"
          >
            <PublicationIcon source={source} size={size} />
          </button>
        ))}
        <span className="text-text-muted" style={{ fontSize: 11.5, fontWeight: 600, marginLeft: 3, letterSpacing: 0.1 }}>
          {sources.length === 1 ? sources[0].publication : `${sources.length} sources`}
        </span>
      </div>
    );
  };

  // Publications behind a story, printed over its headline when it has more
  // than one, so a story many outlets carried reads as such at a glance.
  const renderKicker = (ids: string[]) => {
    const names = [...new Set(cited(ids).map((s) => s.publication))];
    if (names.length < 2) return null;
    return <div className="catchup-kicker">{names.join(" · ")}</div>;
  };

  const renderHeadline = (story: CatchupStory, size: number, tight = false) => (
    <h4
      onClick={open(story.article_ids)}
      className={`catchup-headline text-text-primary ${story.article_ids[0] ? "catchup-headline-link" : ""}`}
      style={{ fontFamily: SERIF, fontSize: size, lineHeight: tight ? 1.12 : 1.2, fontWeight: 700, letterSpacing: size >= 28 ? -0.5 : -0.15 }}
    >
      {story.headline}
    </h4>
  );

  const renderLede = (story: CatchupStory, writing: boolean, size: number, clamp?: number) =>
    story.lede ? (
      <p
        className="catchup-lede text-text-primary"
        style={{
          marginTop: size >= 15 ? 10 : 7,
          fontSize: size,
          lineHeight: 1.55,
          ...(clamp ? { display: "-webkit-box", WebkitLineClamp: clamp, WebkitBoxOrient: "vertical" as const, overflow: "hidden" } : {}),
        }}
      >
        {story.lede}
      </p>
    ) : writing ? (
      <LedeSkeleton lines={clamp ? Math.min(clamp, 3) : 4} />
    ) : null;

  // The lead: headline and lede on the left, its picture on the right, the
  // way a broadsheet runs its top story.
  const renderLead = (story: CatchupStory, writing: boolean) => (
    <article key={`0-${story.headline}`} className="story-rise-in catchup-lead">
      <div className="catchup-lead-text">
        {renderKicker(story.article_ids)}
        {renderHeadline(story, 34, true)}
        {renderLede(story, writing, 16)}
        {renderRelated(story.article_ids, 22)}
      </div>
      {story.image_url && (
        <StoryImage
          src={story.image_url}
          onClick={open(story.article_ids)}
          style={{ width: "100%", aspectRatio: "4 / 3", borderRadius: 6 }}
        />
      )}
    </article>
  );

  // Second tier: picture on top, then the headline and lede.
  const renderFeature = (story: CatchupStory, index: number, writing: boolean) => (
    <article key={`${index}-${story.headline}`} className="story-rise-in catchup-feature">
      {story.image_url && (
        <StoryImage
          src={story.image_url}
          onClick={open(story.article_ids)}
          style={{ width: "100%", aspectRatio: "21 / 9", borderRadius: 5, marginBottom: 12 }}
        />
      )}
      {renderKicker(story.article_ids)}
      {renderHeadline(story, 21)}
      {renderLede(story, writing, 13.5, 4)}
      {renderRelated(story.article_ids)}
    </article>
  );

  // Everything else: text beside a small thumbnail.
  const renderStory = (story: CatchupStory, index: number, writing: boolean, wide = false) => (
    <article key={`${index}-${story.headline}`} className={`story-rise-in catchup-story ${wide ? "catchup-story-wide" : ""}`}>
      <div className="min-w-0 flex-1">
        {renderKicker(story.article_ids)}
        {renderHeadline(story, 17.5)}
        {renderLede(story, writing, 13, 3)}
        {renderRelated(story.article_ids, 18)}
      </div>
      {story.image_url && (
        <StoryImage
          src={story.image_url}
          onClick={open(story.article_ids)}
          style={wide ? { width: 168, height: 104, flexShrink: 0, borderRadius: 5 } : { width: 84, height: 84, flexShrink: 0, borderRadius: 5 }}
        />
      )}
    </article>
  );

  const renderBrief = (brief: CatchupBrief, index: number) => {
    const first = cited(brief.article_ids)[0];
    return (
      <li key={`${index}-${brief.text}`} className="story-rise-in catchup-brief">
        {first ? (
          <button
            onClick={() => onOpenArticle(first.id)}
            title={first.title}
            aria-label={`${first.title}, ${first.publication}`}
            className="catchup-source-icon flex-shrink-0"
          >
            <PublicationIcon source={first} size={18} />
          </button>
        ) : (
          <span style={{ width: 18, flexShrink: 0 }} />
        )}
        <div className="min-w-0 flex-1">
          <p
            onClick={first ? () => onOpenArticle(first.id) : undefined}
            className={`text-text-primary ${first ? "catchup-headline-link cursor-pointer" : ""}`}
            style={{ fontSize: 13.5, lineHeight: 1.4, fontWeight: 600, fontFamily: SERIF }}
          >
            {brief.text}
          </p>
          {first && (
            <span className="text-text-muted" style={{ fontSize: 11, fontWeight: 600, letterSpacing: 0.1 }}>
              {first.publication}
            </span>
          )}
        </div>
      </li>
    );
  };

  const stories = report.stories.slice(0, written + 1);
  const pending = loading ? Math.max(0, report.stories.length - written - 1) : 0;
  const writing = (index: number) => loading && index >= written;

  const lead = stories[0];
  const features = stories.slice(1, 3);
  const rest = stories.slice(3);

  return (
    <div className="catchup-page">
      <div className="catchup-dateline">
        <div className="catchup-dateline-row">
          <span>{dateline}</span>
          {loading && status ? (
            <span className="catchup-dateline-scope flex items-center" style={{ gap: 8 }}>
              <span>{status.message}</span>
              <span className="tabular-nums" style={{ opacity: 0.7 }}>{status.elapsed}s</span>
            </span>
          ) : (
            scopeSummary && <span className="catchup-dateline-scope">{scopeSummary}</span>
          )}
        </div>
        <div className={`catchup-dateline-rule ${loading ? "story-rule-live" : ""}`} />
      </div>

      {lead && renderLead(lead, writing(0))}

      {features.length > 0 && (
        <div className="catchup-tier catchup-features" style={{ gridTemplateColumns: features.length === 1 ? "1fr" : undefined }}>
          {features.map((story, i) => renderFeature(story, i + 1, writing(i + 1)))}
        </div>
      )}

      {rest.length > 0 && (
        <div className="catchup-tier catchup-stories">
          {rest.map((story, i) => renderStory(story, i + 3, writing(i + 3), i === rest.length - 1 && rest.length % 2 === 1 && !pending))}
        </div>
      )}

      {pending > 0 && (
        <p className="text-text-muted flex items-center" style={{ fontSize: 12, marginTop: 22, gap: 8 }}>
          <span className="story-skeleton-line" style={{ width: 28, height: 6 }} />
          {pending === 1 ? "1 more story on the way" : `${pending} more stories on the way`}
        </p>
      )}

      {report.briefs.length > 0 && (
        <section className="catchup-also" style={{ marginTop: stories.length > 0 ? 26 : 0 }}>
          <h4 className="catchup-section-title">Also</h4>
          <ul className="catchup-briefs">{report.briefs.map((brief, index) => renderBrief(brief, index))}</ul>
        </section>
      )}
    </div>
  );
}
