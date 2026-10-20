import { describe, expect, it, vi } from "vitest";
import { render } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { TodayStory } from "./TodayStory";
import type { TodayEditionItem } from "../../services/types";

vi.mock("../../services/commands", () => ({
  getTodayStoryImage: vi.fn(async () => null),
}));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

function makeItem(overrides: Partial<TodayEditionItem>): TodayEditionItem {
  return {
    edition_id: "today-1-2-10",
    story_id: "story-default",
    story_revision_number: 1,
    position: 0,
    section: "top_stories",
    snapshot_title: "Default snapshot title",
    snapshot_summary: "Lay out dominoes legally; the dominoes have people names, not numbers.",
    snapshot_delta_summary: null,
    has_material_update: false,
    snapshot_source_count: 1,
    snapshot_reason: "high_rank_recent",
    is_unique_find: false,
    lede: null,
    is_consumed: false,
    consumed_at: null,
    representative_article_id: "article-default",
    member_article_ids: ["article-default"],
    member_articles: [
      {
        article_id: "article-default",
        feed_id: "feed-1",
        feed_title: "Feed One",
        publication: "example.com",
        feed_icon_url: null,
        title: "Default snapshot title",
        url: "https://example.com",
        author: null,
        published_at: 1000,
        membership_type: "coverage",
        confidence: 0.9,
        is_representative: true,
        is_read: false,
        is_starred: false,
      },
    ],
    ...overrides,
  };
}

function renderLead(item: TodayEditionItem) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const { container } = render(
    <QueryClientProvider client={client}>
      <TodayStory item={item} rank="lead" onToggleConsumed={() => {}} onOpenArticle={() => {}} />
    </QueryClientProvider>,
  );
  return container.querySelector("article.today-story--lead")!;
}

describe("TodayStory thin lead", () => {
  it("marks a lead with only a short lede as thin, so the rail runs under it", () => {
    expect(renderLead(makeItem({})).classList).toContain("today-story--thin-lead");
  });

  it("keeps a lead with a long lede beside the rail", () => {
    const long = "A long lede that fills the lead column. ".repeat(10);
    expect(renderLead(makeItem({ snapshot_summary: long })).classList).not.toContain("today-story--thin-lead");
  });

  it("still treats a short lede with a single quote as thin", () => {
    const item = makeItem({
      editorial: { theme: "Puzzles", summary: "Short summary.", sources: [{ article_id: "article-default", quote: "A passage from the report." }] },
    } as Partial<TodayEditionItem>);
    expect(renderLead(item).classList).toContain("today-story--thin-lead");
  });

  it("keeps a lead with two quotes beside the rail", () => {
    const second = { ...makeItem({}).member_articles[0], article_id: "article-two", is_representative: false };
    const item = makeItem({
      member_articles: [makeItem({}).member_articles[0], second],
      editorial: { theme: "Puzzles", summary: "Short summary.", sources: [
        { article_id: "article-default", quote: "A passage from the report." },
        { article_id: "article-two", quote: "Another passage from the second report." },
      ] },
    } as Partial<TodayEditionItem>);
    expect(renderLead(item).classList).not.toContain("today-story--thin-lead");
  });
});
