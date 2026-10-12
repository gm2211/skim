
export interface TodayWindow {
  /** Local midnight, inclusive. Epoch seconds — matches the Rust `i64` contract. */
  startsAt: number;
  /** Local midnight of the following day, exclusive. Epoch seconds. */
  endsAt: number;
}

/**
 * Local midnight-to-midnight window containing `now`. Constructing Date
 * objects from calendar fields (year/month/day) and letting the engine
 * recompute the UTC offset means this is correct across a DST transition —
 * the window may span 23h or 25h of wall-clock time on those days, but
 * `startsAt`/`endsAt` are still exact local midnights.
 *
 * `get_or_generate_today_edition` rejects `generated_at` outside
 * `[starts_at, ends_at)`, so callers should pass `generatedAt = now` and
 * re-derive this window (rather than caching an edition id) once the local
 * date rolls over past `endsAt`.
 */
export function todayWindow(now: Date = new Date()): TodayWindow {
  const startOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const startOfNextDay = new Date(startOfDay);
  startOfNextDay.setDate(startOfNextDay.getDate() + 1);
  return {
    startsAt: Math.floor(startOfDay.getTime() / 1000),
    endsAt: Math.floor(startOfNextDay.getTime() / 1000),
  };
}

/** Milliseconds until `now` needs a fresh window (i.e. until `endsAt`). */
export function msUntilWindowRollover(window: TodayWindow, now: Date = new Date()): number {
  return Math.max(0, window.endsAt * 1000 - now.getTime());
}

/** Stories on one newspaper page: a lead, a rail of three, a row of three
 *  features and the briefs. */
export const PAGE_SIZE = 10;

export type StoryRank = "lead" | "rail" | "feature" | "brief";

/**
 * Where a story sits on the page, from its position on that page. The edition
 * is already ordered by importance, so position is the only input: the first
 * story leads, the next three run beside it, the next three across the page,
 * and the rest become briefs. Every slot reads well without a picture; an
 * image is used where the report publishes one.
 */
export function rankFor(position: number): StoryRank {
  if (position === 0) return "lead";
  if (position < 4) return "rail";
  if (position < 7) return "feature";
  return "brief";
}

const THEME_COLORS = ["#5c7cfa", "#9775fa", "#22b8cf", "#51cf66", "#da77f2", "#ff922b", "#fcc419", "#38d9a9", "#ff6b6b"];

/** A stable accent for a theme name, so the same theme keeps its colour. */
export function themeColor(theme: string | null | undefined): string | undefined {
  const name = theme?.trim().toLowerCase();
  if (!name) return undefined;
  let hash = 0;
  for (const char of name) hash = (hash * 31 + char.charCodeAt(0)) >>> 0;
  return THEME_COLORS[hash % THEME_COLORS.length];
}

/**
 * Whether a feed excerpt reads as reporting rather than a stub. Link-only
 * bodies such as Hacker News's "Comments" are left off the page.
 */
export function isReadableExcerpt(text: string | null | undefined): boolean {
  const trimmed = text?.trim() ?? "";
  if (/^(article url:|comments url:|\[?comments\]?\b)/i.test(trimmed)) return false;
  return trimmed.length >= 40 && trimmed.split(/\s+/).length >= 7;
}

/** The first sentence of a summary, for slots that print a single line. */
export function firstSentence(text: string): string {
  const match = text.trim().match(/^.+?[.!?](?=\s+[A-Z"“‘(]|\s*$)/s);
  return (match ? match[0] : text).trim();
}
