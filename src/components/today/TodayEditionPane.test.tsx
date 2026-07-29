import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { TodayEditionPane } from "./TodayEditionPane";
import type { AppSettings, TodayEditionItem, TodayEditionView } from "../../services/types";

vi.mock("../../services/commands", () => ({
  getOrGenerateTodayEdition: vi.fn(),
  listTodayEditionItems: vi.fn(),
  setTodayEditionItemConsumed: vi.fn(),
  getSettings: vi.fn(),
  updateSettings: vi.fn(),
}));

import * as commands from "../../services/commands";

const DEFAULT_SETTINGS: AppSettings = {
  ai: {
    provider: "none",
    api_key: null,
    model: null,
    endpoint: null,
    local_model_path: null,
    local_gpu_layers: null,
    local_preload: null,
    local_idle_evict_minutes: null,
    local_power_mode: null,
    models_directory: null,
    summary_length: null,
    summary_tone: null,
    summary_format: null,
    summary_custom_prompt: null,
    summary_custom_word_count: null,
    chat_provider: null,
    chat_model: null,
    chat_api_key: null,
    chat_endpoint: null,
  },
  appearance: { theme: "dark", font_size: 14, show_excerpt_in_list: false },
  sync: { refresh_interval_minutes: 30, max_articles_per_feed: 200, recent_cap: 3000, today_story_limit: 10 },
};

function makeItem(overrides: Partial<TodayEditionItem>): TodayEditionItem {
  return {
    edition_id: "today-1-2-10",
    story_id: "story-default",
    story_revision_number: 1,
    position: 0,
    section: "top_stories",
    snapshot_title: "Default snapshot title",
    snapshot_summary: "Default summary",
    snapshot_delta_summary: null,
    snapshot_source_count: 1,
    snapshot_reason: "high_rank_recent",
    is_unique_find: false,
    is_consumed: false,
    consumed_at: null,
    representative_article_id: "article-default",
    member_article_ids: ["article-default"],
    member_articles: [
      {
        article_id: "article-default",
        feed_id: "feed-1",
        feed_title: "Feed One",
        feed_icon_url: null,
        // Deliberately different from snapshot_title/snapshot_summary — the
        // card must never fall back to a live/member field for its headline.
        title: "A differing live-looking title",
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

function makeView(items: TodayEditionItem[]): TodayEditionView {
  const consumed = items.filter((i) => i.is_consumed).length;
  return {
    edition: {
      id: "today-1-2-10",
      title: "Today",
      scope: "today",
      story_limit: 10,
      status: items.length > 0 && consumed === items.length ? "completed" : "ready",
      starts_at: 1,
      ends_at: 2,
      generated_at: 1,
      completed_at: null,
      total_source_count: items.length,
    },
    items,
    consumed_count: consumed,
    total_count: items.length,
  };
}

function renderPane() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <TodayEditionPane />
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.mocked(commands.getSettings).mockResolvedValue(DEFAULT_SETTINGS);
});

afterEach(() => {
  vi.mocked(commands.getOrGenerateTodayEdition).mockReset();
  vi.mocked(commands.setTodayEditionItemConsumed).mockReset();
  vi.mocked(commands.getSettings).mockReset();
});

describe("TodayEditionPane", () => {
  it("renders sections in backend order regardless of item input order", async () => {
    const items = [
      makeItem({ story_id: "u1", section: "unique_finds", snapshot_title: "Unique story" }),
      makeItem({ story_id: "t1", section: "top_stories", snapshot_title: "Top story" }),
      makeItem({ story_id: "w1", section: "widely_covered", snapshot_title: "Widely covered story" }),
      makeItem({ story_id: "up1", section: "updates", snapshot_title: "Update story" }),
    ];
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView(items));

    renderPane();

    await screen.findByText("Top story");
    const headings = screen.getAllByText(/Top Stories|Widely Covered|Updates|Unique Finds/);
    expect(headings.map((h) => h.textContent)).toEqual([
      "Top Stories",
      "Widely Covered",
      "Updates",
      "Unique Finds",
    ]);
  });

  it("renders the immutable snapshot title/summary and never a differing live field", async () => {
    const item = makeItem({
      snapshot_title: "The real snapshot headline",
      snapshot_summary: "The real snapshot summary.",
    });
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([item]));

    renderPane();

    await screen.findByText("The real snapshot headline");
    expect(screen.getByText("The real snapshot summary.")).toBeInTheDocument();
    expect(screen.queryByText("A differing live-looking title")).not.toBeInTheDocument();
  });

  it("shows completion progress across the edition's items", async () => {
    const items = [
      makeItem({ story_id: "a", is_consumed: true }),
      makeItem({ story_id: "b", is_consumed: false }),
      makeItem({ story_id: "c", is_consumed: false }),
    ];
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView(items));

    renderPane();

    await screen.findByText("1 of 3 done");
  });

  it("shows a completed banner once every item is consumed", async () => {
    const items = [
      makeItem({ story_id: "a", is_consumed: true }),
      makeItem({ story_id: "b", is_consumed: true }),
    ];
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView(items));

    renderPane();

    await screen.findByText("You're all caught up for today.");
    expect(screen.getByText("All caught up")).toBeInTheDocument();
  });

  it("shows an empty state when the edition has no stories", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([]));

    renderPane();

    await screen.findByText("No stories yet today");
  });
});
