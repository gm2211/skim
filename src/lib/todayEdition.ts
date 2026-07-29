import {
  EDITION_SECTION_ORDER,
  type EditionSection,
  type TodayEditionItem,
} from "../services/types";

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

export interface TodayEditionSectionGroup {
  section: EditionSection;
  items: TodayEditionItem[];
}

/**
 * Groups edition items by section in the backend's fixed display order
 * (top_stories, widely_covered, updates, unique_finds), regardless of the
 * order items arrive in. Sections with no items are omitted so the UI never
 * renders an empty section header.
 */
export function groupItemsBySection(items: TodayEditionItem[]): TodayEditionSectionGroup[] {
  const bySection = new Map<EditionSection, TodayEditionItem[]>();
  for (const item of items) {
    const list = bySection.get(item.section);
    if (list) {
      list.push(item);
    } else {
      bySection.set(item.section, [item]);
    }
  }
  return EDITION_SECTION_ORDER.filter((section) => bySection.has(section)).map((section) => ({
    section,
    items: bySection.get(section)!,
  }));
}

export const SECTION_LABELS: Record<EditionSection, string> = {
  top_stories: "Top Stories",
  widely_covered: "Widely Covered",
  updates: "Updates",
  unique_finds: "Unique Finds",
};
