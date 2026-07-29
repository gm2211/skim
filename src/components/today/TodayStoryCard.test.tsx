import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { TodayStoryCard } from "./TodayStoryCard";
import type { TodayEditionItem, TodayEditionMemberArticle } from "../../services/types";

function makeMember(overrides: Partial<TodayEditionMemberArticle>): TodayEditionMemberArticle {
  return {
    article_id: "article-1",
    feed_id: "feed-1",
    feed_title: "Feed 1",
    feed_icon_url: null,
    title: "Article title",
    url: "https://example.com/1",
    author: null,
    published_at: 1000,
    membership_type: "coverage",
    confidence: 0.9,
    is_representative: false,
    is_read: false,
    is_starred: false,
    ...overrides,
  };
}

function makeItem(overrides: Partial<TodayEditionItem> = {}): TodayEditionItem {
  const members = overrides.member_articles ?? [
    makeMember({ article_id: "a1", feed_title: "Source One", is_representative: true }),
    makeMember({ article_id: "a2", feed_title: "Source Two" }),
    makeMember({ article_id: "a3", feed_title: "Source Three" }),
    makeMember({ article_id: "a4", feed_title: "Source Four" }),
    makeMember({ article_id: "a5", feed_title: "Source Five", membership_type: "duplicate" }),
  ];
  return {
    edition_id: "today-1-2-10",
    story_id: "story-1",
    story_revision_number: 1,
    position: 0,
    section: "top_stories",
    snapshot_title: "Snapshot headline",
    snapshot_summary: "Snapshot summary text.",
    snapshot_delta_summary: null,
    snapshot_source_count: members.length,
    snapshot_reason: "high_rank_recent",
    is_unique_find: false,
    is_consumed: false,
    consumed_at: null,
    representative_article_id: "a1",
    member_article_ids: members.map((m) => m.article_id),
    member_articles: members,
    ...overrides,
  };
}

describe("TodayStoryCard", () => {
  it("renders the immutable snapshot title, not any live article title", () => {
    const item = makeItem();
    render(
      <TodayStoryCard item={item} onToggleConsumed={() => {}} onOpenArticle={() => {}} />,
    );
    expect(screen.getByText("Snapshot headline")).toBeInTheDocument();
  });

  it("shows the unique-find badge only when is_unique_find is true", () => {
    const { rerender } = render(
      <TodayStoryCard item={makeItem({ is_unique_find: false })} onToggleConsumed={() => {}} onOpenArticle={() => {}} />,
    );
    expect(screen.queryByText("Unique find")).not.toBeInTheDocument();

    rerender(
      <TodayStoryCard item={makeItem({ is_unique_find: true })} onToggleConsumed={() => {}} onOpenArticle={() => {}} />,
    );
    expect(screen.getByText("Unique find")).toBeInTheDocument();
  });

  it("shows the representative source first and collapses the rest, expanding to the full member count on demand", async () => {
    const user = userEvent.setup();
    const item = makeItem();
    render(
      <TodayStoryCard item={item} onToggleConsumed={() => {}} onOpenArticle={() => {}} />,
    );

    // Collapsed: representative first, only the first 3 of 5 shown.
    const sourceButtons = screen.getAllByTitle("Article title");
    expect(sourceButtons).toHaveLength(3);
    expect(screen.getByText("Source One")).toBeInTheDocument();
    expect(screen.getByText("Source Two")).toBeInTheDocument();
    expect(screen.getByText("Source Three")).toBeInTheDocument();
    expect(screen.queryByText("Source Five")).not.toBeInTheDocument();

    await user.click(screen.getByText("+2 more sources"));

    expect(screen.getAllByTitle("Article title")).toHaveLength(item.member_articles.length);
    expect(screen.getByText("Source Five")).toBeInTheDocument();
  });

  it("de-emphasises duplicate sources relative to coverage/update sources", () => {
    const item = makeItem({
      member_articles: [
        makeMember({ article_id: "a1", feed_title: "Primary", is_representative: true }),
        makeMember({ article_id: "a2", feed_title: "Also Covered", membership_type: "duplicate" }),
      ],
      member_article_ids: ["a1", "a2"],
    });
    render(
      <TodayStoryCard item={item} onToggleConsumed={() => {}} onOpenArticle={() => {}} />,
    );
    const duplicateRow = screen.getByText("Also Covered").closest("button");
    const primaryRow = screen.getByText("Primary").closest("button");
    expect(duplicateRow?.className).toMatch(/opacity-50/);
    expect(primaryRow?.className).not.toMatch(/opacity-50/);
  });

  it("invokes onToggleConsumed with the item's story_id when Mark done is clicked", async () => {
    const user = userEvent.setup();
    const onToggleConsumed = vi.fn();
    const item = makeItem({ story_id: "story-xyz", is_consumed: false });
    render(
      <TodayStoryCard item={item} onToggleConsumed={onToggleConsumed} onOpenArticle={() => {}} />,
    );

    await user.click(screen.getByText("Mark done"));

    expect(onToggleConsumed).toHaveBeenCalledTimes(1);
    expect(onToggleConsumed).toHaveBeenCalledWith("story-xyz", true);
  });

  it("clicking a source invokes onOpenArticle with that article's id", async () => {
    const user = userEvent.setup();
    const onOpenArticle = vi.fn();
    const item = makeItem();
    render(
      <TodayStoryCard item={item} onToggleConsumed={() => {}} onOpenArticle={onOpenArticle} />,
    );

    await user.click(screen.getByText("Source One"));

    expect(onOpenArticle).toHaveBeenCalledWith("a1");
  });
});
