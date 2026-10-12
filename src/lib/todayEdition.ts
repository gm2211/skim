
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
export function todayWindow(now: Date = new Date(), days: number = 1): TodayWindow {
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  // "Going back": the window opens at local midnight `days - 1` days ago and
  // still closes at the coming midnight, so the page is the same kind of
  // paper over a wider span.
  const startOfWindow = new Date(startOfToday);
  startOfWindow.setDate(startOfWindow.getDate() - (Math.max(1, Math.floor(days)) - 1));
  const startOfNextDay = new Date(startOfToday);
  startOfNextDay.setDate(startOfNextDay.getDate() + 1);
  return {
    startsAt: Math.floor(startOfWindow.getTime() / 1000),
    endsAt: Math.floor(startOfNextDay.getTime() / 1000),
  };
}

/** How far back the paper can reach, as the cog offers it. */
export const TODAY_RANGES = [
  { days: 1, label: "Today" },
  { days: 2, label: "Past 2 days" },
  { days: 3, label: "Past 3 days" },
  { days: 7, label: "Past week" },
  { days: 14, label: "Past two weeks" },
] as const;

/** The dateline: one day's date, or the span of a wider window. */
export function formatWindowDate(window: TodayWindow): string {
  const start = new Date(window.startsAt * 1000);
  const last = new Date(window.endsAt * 1000 - 1);
  if (start.toDateString() === last.toDateString()) {
    return start.toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" });
  }
  const sameMonth = start.getMonth() === last.getMonth() && start.getFullYear() === last.getFullYear();
  const from = start.toLocaleDateString("en-US", { month: "long", day: "numeric" });
  const to = sameMonth ? String(last.getDate()) : last.toLocaleDateString("en-US", { month: "long", day: "numeric" });
  return `${from} – ${to}`;
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
