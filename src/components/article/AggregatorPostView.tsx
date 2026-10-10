import type { ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { openUrl } from "@tauri-apps/plugin-opener";
import { fetchAggregatorDetails } from "../../services/commands";
import type { AggregatorComment } from "../../services/types";
import { displayDomain, faviconFor, type AggregatorPost } from "../../lib/aggregatorPost";

export type ReaderCopyState = "loading" | "ready" | "unavailable";

function open(url: string) {
  void openUrl(url).catch((err) => console.error("Failed to open link", err));
}

function linkPath(url: string): string {
  try {
    const parsed = new URL(url);
    return `${parsed.pathname}${parsed.search}`.replace(/\/+$/, "");
  } catch {
    return "";
  }
}

function formatCount(value: number): string {
  return value >= 10_000 ? `${Math.round(value / 1000)}k` : value >= 1000 ? `${(value / 1000).toFixed(1)}k` : String(value);
}

function plural(value: number, word: string): string {
  return `${formatCount(value)} ${word}${value === 1 ? "" : "s"}`;
}

const ExternalIcon = ({ size = 14 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M7 17 17 7M8 7h9v9" />
  </svg>
);

const CommentIcon = ({ size = 16 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12Z" />
  </svg>
);

const UpIcon = () => (
  <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
    <path d="M12 4 3 15h6v5h6v-5h6z" />
  </svg>
);

function Favicon({ url }: { url: string }) {
  const src = faviconFor(url);
  return (
    <span className="relative flex-shrink-0 rounded-md bg-white/10 flex items-center justify-center overflow-hidden text-text-secondary font-bold uppercase" style={{ width: 22, height: 22, fontSize: 11 }} aria-hidden="true">
      {displayDomain(url).charAt(0)}
      {src && <img src={src} alt="" width={16} height={16} className="absolute" onError={(e) => { e.currentTarget.style.display = "none"; }} />}
    </span>
  );
}

/**
 * The article a Reddit or Hacker News post points at. Before a reader copy is
 * ready it is the page's centerpiece with a clear way to read the story; once
 * the story is extracted below it shrinks to a one-line source row.
 */
function LinkCard({ url, thumbnailUrl, state }: { url: string; thumbnailUrl: string | null; state: ReaderCopyState }) {
  const domain = displayDomain(url);
  const path = linkPath(url);

  if (state === "ready") {
    return (
      <button
        type="button"
        onClick={() => open(url)}
        className="aggregator-link-row w-full min-w-0 flex items-center gap-3 text-left rounded-xl border border-white/10 bg-white/[0.03] hover:bg-white/[0.06] transition-colors"
        style={{ padding: "10px 14px" }}
        aria-label={`Open the original on ${domain}`}
      >
        <Favicon url={url} />
        <span className="min-w-0 flex-1">
          <span className="block text-text-primary text-sm font-semibold truncate">{domain}</span>
          {path && <span className="block text-text-muted text-xs truncate">{path}</span>}
        </span>
        <span className="flex-shrink-0 flex items-center gap-1 text-text-secondary text-xs font-medium">
          Original <ExternalIcon size={12} />
        </span>
      </button>
    );
  }

  return (
    <section className="aggregator-link-card rounded-2xl border border-white/10 bg-white/[0.035] overflow-hidden" aria-label="Linked story">
      {thumbnailUrl && (
        <button type="button" onClick={() => open(url)} className="block w-full bg-black/30" tabIndex={-1} aria-hidden="true">
          <img
            src={thumbnailUrl}
            alt=""
            className="block w-full object-cover"
            style={{ aspectRatio: "1.91 / 1", maxHeight: 360 }}
            onError={(e) => { (e.currentTarget.parentElement as HTMLElement).style.display = "none"; }}
          />
        </button>
      )}
      <div className="flex flex-col gap-4" style={{ padding: "16px 18px 18px" }}>
        <div className="flex items-center gap-3 min-w-0">
          <Favicon url={url} />
          <div className="min-w-0">
            <div className="text-text-primary font-semibold truncate" style={{ fontSize: 15 }}>{domain}</div>
            {path && <div className="text-text-muted text-xs truncate">{path}</div>}
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
          <button
            type="button"
            onClick={() => open(url)}
            className="inline-flex items-center gap-2 rounded-lg bg-accent text-bg-primary font-semibold hover:bg-accent-hover transition-colors"
            style={{ padding: "9px 16px", fontSize: 14 }}
          >
            Read on {domain} <ExternalIcon />
          </button>
          {state === "loading" ? (
            <span className="flex items-center gap-2 text-text-muted" style={{ fontSize: 13 }}>
              <svg className="smooth-spin" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
                <path d="M21 12a9 9 0 1 1-6.219-8.56" />
              </svg>
              Getting a reader copy…
            </span>
          ) : (
            <span className="text-text-muted" style={{ fontSize: 13 }}>This site doesn't offer a reader copy, so it opens in your browser.</span>
          )}
        </div>
      </div>
    </section>
  );
}

function CommentRow({ comment }: { comment: AggregatorComment }) {
  return (
    <li className="flex flex-col gap-1.5" style={{ padding: "14px 0" }}>
      <div className="flex items-center gap-2 text-xs">
        <span className="text-text-secondary font-semibold">{comment.author}</span>
        {comment.score != null && (
          <span className="flex items-center gap-1 text-text-muted"><UpIcon />{formatCount(comment.score)}</span>
        )}
      </div>
      <p className="text-text-primary whitespace-pre-wrap break-words" style={{ fontSize: 15, lineHeight: 1.6 }}>{comment.body}</p>
    </li>
  );
}

function Discussion({ post, url }: { post: AggregatorPost; url: string }) {
  const { data, isLoading, isError } = useQuery({
    queryKey: ["aggregatorDetails", url],
    queryFn: () => fetchAggregatorDetails(url, 10),
    staleTime: 5 * 60 * 1000,
  });
  const points = data?.points ?? post.points;
  const count = data?.comment_count ?? post.commentCount;
  const comments = data?.comments ?? [];
  const stats = [points != null ? plural(points, "point") : null, count != null ? plural(count, "comment") : null].filter(Boolean).join(" · ");
  const failed = !isLoading && (isError || !data);

  return (
    <section className="aggregator-discussion flex flex-col" aria-label="Discussion">
      <header className="flex items-center justify-between gap-3 border-b border-white/10" style={{ paddingBottom: 12 }}>
        <div className="flex items-baseline gap-3 min-w-0">
          <h2 className="text-text-primary font-bold" style={{ fontSize: 18 }}>Discussion</h2>
          {stats && <span className="text-text-muted truncate" style={{ fontSize: 13 }}>{stats}</span>}
        </div>
        <button
          type="button"
          onClick={() => open(url)}
          className="flex-shrink-0 inline-flex items-center gap-1.5 rounded-lg border border-white/15 text-text-primary hover:bg-white/[0.06] transition-colors"
          style={{ padding: "6px 12px", fontSize: 13 }}
        >
          Open on {post.siteName} <ExternalIcon size={12} />
        </button>
      </header>

      {isLoading ? (
        <div className="flex flex-col gap-4" style={{ paddingTop: 18 }} aria-label="Loading comments">
          {[0.9, 0.7, 0.8].map((width, i) => (
            <div key={i} className="flex flex-col gap-2 animate-pulse">
              <div className="h-2.5 rounded bg-white/10" style={{ width: 90 }} />
              <div className="h-3 rounded bg-white/[0.07]" style={{ width: `${width * 100}%` }} />
            </div>
          ))}
        </div>
      ) : failed || comments.length === 0 ? (
        <button
          type="button"
          onClick={() => open(url)}
          className="flex items-center gap-3 text-left rounded-xl border border-white/10 bg-white/[0.03] hover:bg-white/[0.06] transition-colors"
          style={{ marginTop: 16, padding: "14px 16px" }}
        >
          <span className="text-accent"><CommentIcon size={20} /></span>
          <span className="min-w-0 flex-1">
            <span className="block text-text-primary font-semibold" style={{ fontSize: 14 }}>
              {failed ? `Read the conversation on ${post.siteName}` : "No comments yet"}
            </span>
            <span className="block text-text-muted" style={{ fontSize: 13 }}>
              {failed ? (count ? `${plural(count, "comment")} so far` : "Comments open in your browser") : "Be the first to reply"}
            </span>
          </span>
          <span className="text-text-muted"><ExternalIcon /></span>
        </button>
      ) : (
        <>
          <ul className="flex flex-col divide-y divide-white/[0.06]">
            {comments.map((comment) => <CommentRow key={comment.id} comment={comment} />)}
          </ul>
          <button
            type="button"
            onClick={() => open(url)}
            className="self-start inline-flex items-center gap-1.5 text-accent hover:underline"
            style={{ fontSize: 14, marginTop: 4 }}
          >
            {count && count > comments.length ? `See all ${plural(count, "comment")}` : "Join the discussion"} on {post.siteName} <ExternalIcon size={12} />
          </button>
        </>
      )}
    </section>
  );
}

/**
 * Purpose-built reader layout for Reddit, Hacker News and Lobsters items:
 * the post itself (text, image, or the story it links to), the extracted
 * story when Skim could make a reader copy, then the discussion.
 */
export function AggregatorPostView({
  post,
  readerState,
  children,
}: {
  post: AggregatorPost;
  readerState: ReaderCopyState;
  /** The extracted linked story, rendered when readerState is "ready". */
  children?: ReactNode;
}) {
  const discussionUrl = post.discussionUrl;
  const { data } = useQuery({
    queryKey: ["aggregatorDetails", discussionUrl],
    queryFn: () => fetchAggregatorDetails(discussionUrl!, 10),
    enabled: !!discussionUrl,
    staleTime: 5 * 60 * 1000,
  });
  const linkUrl = post.linkUrl ?? data?.external_url ?? null;
  const selfText = !post.selfHtml && !linkUrl ? data?.selftext ?? null : null;

  return (
    <div className="aggregator-post flex flex-col" style={{ gap: 28 }}>
      {post.selfHtml && (
        <div className="article-content text-text-primary" dangerouslySetInnerHTML={{ __html: post.selfHtml }} />
      )}
      {selfText && <div className="article-content text-text-primary whitespace-pre-wrap">{selfText}</div>}
      {post.mediaUrl && (
        <img src={post.mediaUrl} alt="" className="block w-full rounded-2xl border border-white/10 object-contain bg-black/30" style={{ maxHeight: 640 }} />
      )}
      {linkUrl && (
        <div className="flex flex-col" style={{ gap: 24 }}>
          <LinkCard url={linkUrl} thumbnailUrl={post.thumbnailUrl} state={readerState} />
          {readerState === "ready" && children}
        </div>
      )}
      {discussionUrl && <Discussion post={post} url={discussionUrl} />}
    </div>
  );
}
