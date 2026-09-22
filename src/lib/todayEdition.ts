
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

/** Stories that get a written lede and full-size setting. */
export const LEAD_COUNT = 6;

export type StoryRank = "lead" | "story" | "brief";

/**
 * Where a story sits on the page, from its position in the edition. The
 * edition is already ordered by importance, so position is the only input:
 * the first story leads, the next few run as stories, and the tail becomes
 * one-line briefs.
 */
export function rankFor(position: number): StoryRank {
  if (position === 0) return "lead";
  if (position < LEAD_COUNT) return "story";
  return "brief";
}
