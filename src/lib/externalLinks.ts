import { openUrl } from "@tauri-apps/plugin-opener";

const EXTERNAL_PROTOCOLS = new Set(["http:", "https:", "mailto:", "tel:"]);

/**
 * Resolves a link clicked inside article content to the URL it should open.
 * Relative links resolve against the article's own URL (not the app's origin),
 * and in-page `#anchors` return null so they keep scrolling the reader.
 */
export function resolveArticleLink(href: string | null | undefined, articleUrl?: string | null): string | null {
  const raw = href?.trim();
  if (!raw || raw.startsWith("#")) return null;
  let url: URL;
  try {
    url = articleUrl ? new URL(raw, articleUrl) : new URL(raw);
  } catch {
    return null;
  }
  return EXTERNAL_PROTOCOLS.has(url.protocol) ? url.href : null;
}

/** The link element a click landed on, if any. */
export function anchorFromEvent(event: Event): HTMLAnchorElement | null {
  const target = event.target;
  if (!(target instanceof Element)) return null;
  return target.closest("a[href]") as HTMLAnchorElement | null;
}

/**
 * Opens an article link in the default browser instead of letting it replace
 * Skim's window, which leaves no way back. Returns true when it handled the click.
 */
export function openArticleLink(event: MouseEvent, articleUrl?: string | null): boolean {
  if (event.defaultPrevented || event.button !== 0) return false;
  const anchor = anchorFromEvent(event);
  if (!anchor) return false;
  if (!resolveArticleLink(anchor.getAttribute("href"), articleUrl)) return false;
  event.preventDefault();
  return openArticleHref(anchor.getAttribute("href"), articleUrl);
}

/** Opens a raw article href in the default browser. Returns false if it isn't a web link. */
export function openArticleHref(href: string | null | undefined, articleUrl?: string | null): boolean {
  const url = resolveArticleLink(href, articleUrl);
  if (!url) return false;
  void openUrl(url).catch((err) => console.error("Failed to open link", err));
  return true;
}
