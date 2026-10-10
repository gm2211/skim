import type { Article } from "../services/types";

export type AggregatorKind = "reddit" | "hacker_news" | "lobsters";

/**
 * What a Reddit, Hacker News or Lobsters item is about, read straight from the
 * feed entry so the reader can lay it out without a network round trip. The
 * raw feed HTML ("submitted by /u/x [link] [comments]") is never shown.
 */
export interface AggregatorPost {
  kind: AggregatorKind;
  /** "Reddit", "Hacker News" or "Lobsters". */
  siteName: string;
  /** "r/technology" for Reddit; null elsewhere. */
  community: string | null;
  /** "u/name" for Reddit, the HN or Lobsters user otherwise. */
  submitter: string | null;
  /** The article the post links to, when it is a link post. */
  linkUrl: string | null;
  /** An image the post itself is (i.redd.it and similar). */
  mediaUrl: string | null;
  /** Where the comments live. */
  discussionUrl: string | null;
  thumbnailUrl: string | null;
  /** Self-post body as HTML, already limited to the post's own markdown block. */
  selfHtml: string | null;
  points: number | null;
  commentCount: number | null;
}

function parseUrl(url: string | null | undefined): URL | null {
  if (!url) return null;
  try {
    const parsed = new URL(url);
    return parsed.protocol === "http:" || parsed.protocol === "https:" ? parsed : null;
  } catch {
    return null;
  }
}

export function aggregatorKindOf(url: string | null | undefined): AggregatorKind | null {
  const host = parseUrl(url)?.hostname.toLowerCase();
  if (!host) return null;
  if (host === "news.ycombinator.com" || host.endsWith(".ycombinator.com")) return "hacker_news";
  if (host === "reddit.com" || host.endsWith(".reddit.com") || host === "redd.it") return "reddit";
  if (host === "lobste.rs" || host.endsWith(".lobste.rs")) return "lobsters";
  return null;
}

const REDDIT_MEDIA_HOSTS = new Set(["i.redd.it", "i.imgur.com"]);
const IMAGE_PATH = /\.(png|jpe?g|gif|webp|avif)$/i;

function isRedditMedia(url: URL): boolean {
  return REDDIT_MEDIA_HOSTS.has(url.hostname.toLowerCase()) && IMAGE_PATH.test(url.pathname);
}

/** Reddit wraps media hosts in its own family; those are posts, not links out. */
function isRedditFamily(url: URL): boolean {
  const host = url.hostname.toLowerCase();
  return aggregatorKindOf(url.href) === "reddit" || host.endsWith(".redd.it") || host === "redd.it";
}

const SITE_NAMES: Record<AggregatorKind, string> = {
  reddit: "Reddit",
  hacker_news: "Hacker News",
  lobsters: "Lobsters",
};

function anchorByText(doc: Document, pattern: RegExp): HTMLAnchorElement | null {
  return Array.from(doc.querySelectorAll("a[href]")).find((a) => pattern.test((a.textContent ?? "").trim())) as HTMLAnchorElement | undefined ?? null;
}

function numberAfter(text: string, label: RegExp): number | null {
  const match = text.match(label);
  return match ? Number(match[1].replace(/,/g, "")) : null;
}

function redditCommunity(url: URL | null): string | null {
  const match = url?.pathname.match(/^\/r\/([^/]+)/i);
  return match ? `r/${match[1]}` : null;
}

function cleanUser(name: string | null | undefined): string | null {
  const trimmed = name?.trim().replace(/^\/?u\//i, "");
  return trimmed ? trimmed : null;
}

/** Returns the post layout for aggregator items, or null for ordinary articles. */
export function parseAggregatorPost(article: Pick<Article, "url" | "comments_url" | "content_html" | "author">): AggregatorPost | null {
  const kind = aggregatorKindOf(article.comments_url) ?? aggregatorKindOf(article.url);
  if (!kind) return null;

  const doc = article.content_html
    ? new DOMParser().parseFromString(article.content_html, "text/html")
    : null;
  const text = doc?.body.textContent?.replace(/\s+/g, " ") ?? "";

  const articleUrl = parseUrl(article.url);
  const discussion =
    parseUrl(article.comments_url) ??
    (articleUrl && aggregatorKindOf(articleUrl.href) ? articleUrl : null) ??
    parseUrl(doc ? anchorByText(doc, /^\[?comments\]?$|^comments url/i)?.href : null);

  const post: AggregatorPost = {
    kind,
    siteName: SITE_NAMES[kind],
    community: null,
    submitter: cleanUser(article.author),
    linkUrl: null,
    mediaUrl: null,
    discussionUrl: discussion?.href ?? null,
    thumbnailUrl: null,
    selfHtml: null,
    points: numberAfter(text, /Points:\s*([\d,]+)/i),
    commentCount: numberAfter(text, /#\s*Comments:\s*([\d,]+)/i),
  };

  if (kind === "reddit") {
    post.community = redditCommunity(discussion) ?? redditCommunity(articleUrl);
    const submitter = doc ? anchorByText(doc, /^\/?u\//i) : null;
    post.submitter = cleanUser(submitter?.textContent) ?? post.submitter;
    const link = parseUrl(doc ? anchorByText(doc, /^\[link\]$/i)?.getAttribute("href") : null) ?? articleUrl;
    if (link && isRedditMedia(link)) post.mediaUrl = link.href;
    else if (link && !isRedditFamily(link)) post.linkUrl = link.href;
    const thumb = doc?.querySelector("img[src]")?.getAttribute("src");
    post.thumbnailUrl = parseUrl(thumb)?.href ?? null;
    const body = doc?.querySelector(".md");
    if (body && (body.textContent ?? "").trim()) post.selfHtml = body.innerHTML.trim();
    return post;
  }

  // Hacker News and Lobsters feeds point the item at the story itself and
  // carry the discussion separately; hnrss adds an "Article URL:" line.
  const articleLine = doc ? anchorByText(doc, /^https?:\/\//i) : null;
  const candidates = [articleUrl, parseUrl(articleLine?.getAttribute("href"))];
  post.linkUrl = candidates.find((url) => url && !aggregatorKindOf(url.href))?.href ?? null;
  return post;
}

/** "bbc.co.uk" from a full URL, for labels. */
export function displayDomain(url: string): string {
  return parseUrl(url)?.hostname.replace(/^www\./i, "") ?? url;
}

export function faviconFor(url: string): string | null {
  const host = parseUrl(url)?.hostname;
  return host ? `https://www.google.com/s2/favicons?domain=${host}&sz=64` : null;
}
