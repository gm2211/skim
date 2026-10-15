// Mirrors `looks_like_url` in src-tauri/src/feed/discovery.rs: an address has a
// scheme, or is one token with a dot and a letter-only suffix. `r/rust` counts.
export function looksLikeUrl(input: string): boolean {
  const s = input.trim();
  if (!s || /\s/.test(s)) return false;
  if (s.includes("://") || /^\/?r\/[A-Za-z0-9_]+\/?$/.test(s)) return true;
  const host = (s.split(/[/?#]/)[0] ?? "").split("@").pop() ?? "";
  const dot = host.lastIndexOf(".");
  if (dot <= 0) return false;
  const tld = host.slice(dot + 1);
  return tld.length >= 2 && /^[A-Za-z]+$/.test(tld);
}

/** "www.theverge.com" for display; falls back to the input. */
export function displayHost(url: string | null | undefined): string {
  if (!url) return "";
  try {
    return new URL(url).host.replace(/^www\./, "");
  } catch {
    return url;
  }
}

/** 1234 -> "1.2K", 1200000 -> "1.2M". */
export function compactCount(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n >= 10_000_000 ? 0 : 1).replace(/\.0$/, "")}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(n >= 10_000 ? 0 : 1).replace(/\.0$/, "")}K`;
  return String(n);
}

/** "3h", "2d", "Oct 3" for a unix-seconds timestamp. */
export function shortAge(publishedAt: number | null, now = Date.now()): string {
  if (!publishedAt) return "";
  const minutes = Math.max(0, Math.round((now - publishedAt * 1000) / 60_000));
  if (minutes < 60) return `${Math.max(1, minutes)}m`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.round(hours / 24);
  if (days < 7) return `${days}d`;
  return new Date(publishedAt * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

/** "Today", "Yesterday", "Monday", "Oct 3", or "Earlier" for undated posts. */
export function dayLabel(publishedAt: number | null, now = Date.now()): string {
  if (!publishedAt) return "Earlier";
  const start = (t: number) => {
    const d = new Date(t);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  };
  const days = Math.round((start(now) - start(publishedAt * 1000)) / 86_400_000);
  if (days <= 0) return "Today";
  if (days === 1) return "Yesterday";
  const date = new Date(publishedAt * 1000);
  if (days < 7) return date.toLocaleDateString(undefined, { weekday: "long" });
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}
