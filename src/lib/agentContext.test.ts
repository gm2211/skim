import { describe, expect, it } from "vitest";
import { agentContextLabel, buildAgentContext } from "./agentContext";
import type { TodayEditionItem, TodayEditionView } from "../services/types";

const item = (story_id: string, position: number, ids: string[], extra: Partial<TodayEditionItem> = {}) =>
  ({
    story_id, position, snapshot_title: `Story ${story_id}`, snapshot_summary: "snapshot", lede: null,
    representative_article_id: ids[0], member_article_ids: ids, ...extra,
  }) as TodayEditionItem;

const edition = {
  edition: { generated_at: 1 },
  items: [item("b", 2, ["b1"]), item("a", 1, ["a1", "a2"], { lede: "The lede" })],
} as unknown as TodayEditionView;

describe("agent context", () => {
  it("on Today, lists the page's stories in order and finds the open article's story", () => {
    const context = buildAgentContext({ view: { type: "today" }, selectedArticleId: "a2", edition });
    expect(context.page_stories?.map((s) => s.story_id)).toEqual(["a", "b"]);
    expect(context.page_stories?.[0]).toMatchObject({ summary: "The lede", article_ids: ["a1", "a2"] });
    expect(context.story?.story_id).toBe("a");
    expect(context.article_id).toBe("a2");
    expect(agentContextLabel(context, "Open piece")).toBe("Reading “Open piece”");
    expect(agentContextLabel({ ...context, article_id: null })).toBe("Story: Story a");
  });

  it("names feeds and lets a caller point at a story", () => {
    const feeds = [{ id: "f1", title: "Lobsters" }] as never;
    const context = buildAgentContext({ view: { type: "feed", feedId: "f1" }, selectedArticleId: null, feeds,
      story: { story_id: "x", title: "Pointed", article_ids: [] } });
    expect(context).toMatchObject({ view: "feed", view_label: "Lobsters", story: { story_id: "x" } });
    expect(context.page_stories).toBeUndefined();
    expect(agentContextLabel({ view: "feed", view_label: "Lobsters" })).toBe("Lobsters");
  });
});
