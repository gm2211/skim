import { beforeAll, describe, expect, it } from "vitest";
import {
  groupItemsBySection,
  msUntilWindowRollover,
  todayWindow,
} from "./todayEdition";
import type { TodayEditionItem } from "../services/types";

// Pin the timezone so local-midnight math (and the DST case below) is
// deterministic regardless of the machine/CI runner's own TZ.
beforeAll(() => {
  // @ts-expect-error process is a nodejs global (vitest runs under node)
  process.env.TZ = "America/New_York";
});

function makeItem(overrides: Partial<TodayEditionItem>): TodayEditionItem {
  return {
    edition_id: "today-1-2-5",
    story_id: "story-1",
    story_revision_number: 1,
    position: 0,
    section: "top_stories",
    snapshot_title: "Title",
    snapshot_summary: "Summary",
    snapshot_delta_summary: null,
    snapshot_source_count: 1,
    snapshot_reason: "high_rank_recent",
    is_unique_find: false,
    is_consumed: false,
    consumed_at: null,
    representative_article_id: "article-1",
    member_article_ids: ["article-1"],
    member_articles: [],
    ...overrides,
  };
}

describe("todayWindow", () => {
  it("returns exact local midnight-to-midnight bounds on an ordinary day", () => {
    const now = new Date(2024, 5, 15, 14, 30, 0); // June 15 2024, 2:30pm — no DST transition
    const win = todayWindow(now);
    expect(new Date(win.startsAt * 1000)).toEqual(new Date(2024, 5, 15, 0, 0, 0));
    expect(new Date(win.endsAt * 1000)).toEqual(new Date(2024, 5, 16, 0, 0, 0));
    expect(win.endsAt - win.startsAt).toBe(24 * 3600);
    // `now` must fall inside [startsAt, endsAt) — this is exactly what the
    // backend's validate_window_and_limit enforces.
    const nowSeconds = Math.floor(now.getTime() / 1000);
    expect(nowSeconds).toBeGreaterThanOrEqual(win.startsAt);
    expect(nowSeconds).toBeLessThan(win.endsAt);
  });

  it("still yields exact local midnights on a DST spring-forward day (23h window)", () => {
    // 2024-03-10 is when America/New_York springs forward at 2am.
    const now = new Date(2024, 2, 10, 12, 0, 0);
    const win = todayWindow(now);
    expect(new Date(win.startsAt * 1000)).toEqual(new Date(2024, 2, 10, 0, 0, 0));
    expect(new Date(win.endsAt * 1000)).toEqual(new Date(2024, 2, 11, 0, 0, 0));
    // Lost an hour of wall-clock time, so fewer than 24h actually elapsed
    // between the two local midnights.
    expect(win.endsAt - win.startsAt).toBe(23 * 3600);
  });

  it("yields a 25h window on a DST fall-back day", () => {
    // 2024-11-03 is when America/New_York falls back at 2am.
    const now = new Date(2024, 10, 3, 12, 0, 0);
    const win = todayWindow(now);
    expect(win.endsAt - win.startsAt).toBe(25 * 3600);
  });
});

describe("msUntilWindowRollover", () => {
  it("is zero once now has reached or passed endsAt", () => {
    const win = todayWindow(new Date(2024, 5, 15, 12, 0, 0));
    const afterEnd = new Date(2024, 5, 16, 0, 0, 1);
    expect(msUntilWindowRollover(win, afterEnd)).toBe(0);
  });

  it("counts down the remaining milliseconds before endsAt", () => {
    const win = todayWindow(new Date(2024, 5, 15, 12, 0, 0));
    const oneHourBefore = new Date(2024, 5, 15, 23, 0, 0);
    expect(msUntilWindowRollover(win, oneHourBefore)).toBe(3600_000);
  });
});

describe("groupItemsBySection", () => {
  it("orders sections top_stories, widely_covered, updates, unique_finds regardless of input order", () => {
    const items = [
      makeItem({ story_id: "u1", section: "unique_finds" }),
      makeItem({ story_id: "up1", section: "updates" }),
      makeItem({ story_id: "w1", section: "widely_covered" }),
      makeItem({ story_id: "t1", section: "top_stories" }),
      makeItem({ story_id: "t2", section: "top_stories" }),
    ];
    const groups = groupItemsBySection(items);
    expect(groups.map((g) => g.section)).toEqual([
      "top_stories",
      "widely_covered",
      "updates",
      "unique_finds",
    ]);
    expect(groups.find((g) => g.section === "top_stories")?.items.map((i) => i.story_id)).toEqual([
      "t1",
      "t2",
    ]);
  });

  it("omits sections with no items", () => {
    const items = [makeItem({ story_id: "t1", section: "top_stories" })];
    const groups = groupItemsBySection(items);
    expect(groups).toEqual([{ section: "top_stories", items: [items[0]] }]);
  });

  it("returns an empty array for an empty edition", () => {
    expect(groupItemsBySection([])).toEqual([]);
  });
});
