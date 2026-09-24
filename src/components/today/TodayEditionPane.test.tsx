import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { listen } from "@tauri-apps/api/event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { TodayEditionPane } from "./TodayEditionPane";
import type { AppSettings, TodayEditionItem, TodayEditionView } from "../../services/types";
import { useUiStore } from "../../stores/uiStore";

vi.mock("../../services/commands", () => ({
  getOrGenerateTodayEdition: vi.fn(),
  refreshAllFeeds: vi.fn(),
  triageArticles: vi.fn(),
  listTodayEditionItems: vi.fn(),
  setTodayEditionItemConsumed: vi.fn(),
  generateTodayLedes: vi.fn(),
  TODAY_LEDE_PROGRESS_EVENT: "today_lede_progress",
  getSettings: vi.fn(),
  updateSettings: vi.fn(),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async () => () => {}),
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
  const result = render(
    <QueryClientProvider client={qc}>
      <TodayEditionPane />
    </QueryClientProvider>,
  );
  return { ...result, qc };
}

beforeEach(() => {
  vi.mocked(listen).mockClear();
  useUiStore.setState({ selectedArticleId: null });
  vi.mocked(commands.refreshAllFeeds).mockResolvedValue(1);
  vi.mocked(commands.triageArticles).mockResolvedValue({ triaged_count: 0, batches: 0, errors: [] });
  useUiStore.setState({ isPhone: false, sidebarCollapsed: false });
  vi.mocked(commands.getSettings).mockResolvedValue(DEFAULT_SETTINGS);
  vi.mocked(commands.generateTodayLedes).mockImplementation((_id: string) => new Promise(() => {}));
});

afterEach(() => {
  vi.mocked(commands.getOrGenerateTodayEdition).mockReset();
  vi.mocked(commands.setTodayEditionItemConsumed).mockReset();
  vi.mocked(commands.getSettings).mockReset();
  vi.mocked(commands.generateTodayLedes).mockReset();
});

describe("TodayEditionPane", () => {
  it("keeps Skim branding visible while the sidebar is collapsed", async () => {
    useUiStore.setState({ isPhone: false, sidebarCollapsed: true });
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([]));
    renderPane();
    expect(screen.getByRole("heading", { name: "SKIM" })).toBeVisible();
    fireEvent.click(screen.getByRole("button", { name: "Expand sidebar" }));
    expect(useUiStore.getState().sidebarCollapsed).toBe(false);
    expect(screen.queryByRole("button", { name: "Expand sidebar" })).not.toBeInTheDocument();
  });

  it("runs the page in the order the backend ranked it, with no section headers", async () => {
    const items = [
      makeItem({ story_id: "a", snapshot_title: "The lead story" }),
      makeItem({ story_id: "b", snapshot_title: "The second story" }),
      makeItem({ story_id: "c", snapshot_title: "The third story" }),
    ];
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView(items));

    renderPane();

    await screen.findByText("The lead story");
    const headlines = screen.getAllByRole("heading", { level: 3 });
    expect(headlines.map((h) => h.textContent)).toEqual([
      "The lead story",
      "The second story",
      "The third story",
    ]);
    expect(screen.queryByText("Unique Finds")).not.toBeInTheDocument();
    expect(screen.queryByText("Top Stories")).not.toBeInTheDocument();
  });

  it("prints a written lede in place of the mechanical excerpt", async () => {
    const item = makeItem({
      snapshot_summary: "[Comments][1] [1]: https://news.ycombinator.com/item?id=1",
      lede: "Congress passed the bill on Friday after a four-hour debate.",
    });
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([item]));

    renderPane();

    expect(
      await screen.findByText("Congress passed the bill on Friday after a four-hour debate."),
    ).toBeInTheDocument();
    expect(screen.queryByText(/news\.ycombinator\.com/)).not.toBeInTheDocument();
  });

  it("names the publication under a story rather than the feed's own title", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));

    renderPane();

    fireEvent.click(await screen.findByRole("button", { name: "1 report" }));
    expect(screen.getByText("example.com")).toBeInTheDocument();
    expect(screen.queryByText("Feed One")).not.toBeInTheDocument();
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
    // The member article's own title is printed in the byline, but the
    // headline itself must come from the frozen snapshot.
    expect(screen.getByRole("heading", { level: 3 })).toHaveTextContent(
      "The real snapshot headline",
    );
    expect(screen.getByRole("heading", { level: 3 })).not.toHaveTextContent(
      "A differing live-looking title",
    );
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

  it("reserves a draggable macOS titlebar when the sidebar is collapsed", async () => {
    useUiStore.setState({ isPhone: false, sidebarCollapsed: true });
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([]));

    renderPane();

    const expand = await screen.findByRole("button", { name: "Expand sidebar" });
    const titlebar = expand.parentElement;
    expect(titlebar).toHaveAttribute("data-tauri-drag-region");
    expect(titlebar).toHaveStyle({ height: "40px", paddingLeft: "80px" });
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


describe("Today interaction and async boundaries", () => {
  it("keeps syndicated references optional and available", async () => {
    const item = makeItem({});
    item.member_articles.push({ ...item.member_articles[0], article_id: "duplicate", title: "Syndicated copy", membership_type: "duplicate", is_representative: false });
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([item]));
    renderPane();
    const reports = await screen.findByRole("button", { name: "2 reports" });
    expect(screen.queryByText("Syndicated copy")).not.toBeInTheDocument();
    await userEvent.click(reports);
    expect(reports).toHaveAttribute("aria-expanded", "true");
    await userEvent.click(screen.getByRole("button", { name: /Syndicated copy/ }));
    expect(useUiStore.getState().selectedArticleId).toBe("duplicate");
    await userEvent.click(reports);
    expect(screen.queryByText("Syndicated copy")).not.toBeInTheDocument();
  });

  it("opens a headline with the keyboard", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    renderPane();
    const headline = await screen.findByRole("button", { name: "Default snapshot title" });
    headline.focus();
    await userEvent.keyboard("{Enter}");
    expect(useUiStore.getState().selectedArticleId).toBe("article-default");
  });

  it("reports a failed progress save without claiming the story is read", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    vi.mocked(commands.setTodayEditionItemConsumed).mockRejectedValue(new Error("Disk full"));
    renderPane();
    await userEvent.click(await screen.findByRole("button", { name: "Mark as read" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Could not save reading progress");
    expect(screen.getByText("0 of 1 done")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Mark as read" })).toBeEnabled();
  });

  it.each(["success", "failure"])("isolates a deferred previous-edition save on %s", async (outcome) => {
    let resolveSave!: (view: TodayEditionView) => void;
    let rejectSave!: (error: Error) => void;
    const save = new Promise<TodayEditionView>((resolve, reject) => { resolveSave = resolve; rejectSave = reject; });
    const first = makeView([makeItem({ snapshot_title: "Edition A" })]);
    const next = makeView([makeItem({ snapshot_title: "Edition B", edition_id: "today-1-2-5" })]);
    next.edition = { ...next.edition, id: "today-1-2-5", story_limit: 5 };
    vi.mocked(commands.getOrGenerateTodayEdition).mockImplementation(async (_start, _end, _now, limit) => limit === 5 ? next : first);
    vi.mocked(commands.setTodayEditionItemConsumed).mockReturnValue(save);
    const { qc } = renderPane();
    await screen.findByText("Edition A");
    const firstKey = qc.getQueryCache().findAll({ queryKey: ["todayEdition"] })[0].queryKey;
    await userEvent.click(screen.getByRole("button", { name: "Mark as read" }));
    expect(screen.getByRole("button", { name: "Mark as read" })).toBeDisabled();
    await act(async () => {
      qc.setQueryData(["settings"], { ...DEFAULT_SETTINGS, sync: { ...DEFAULT_SETTINGS.sync, today_story_limit: 5 } });
    });
    await screen.findByText("Edition B");
    expect(screen.getByRole("button", { name: "Mark as read" })).toBeEnabled();
    const saved = makeView([makeItem({ snapshot_title: "Edition A", is_consumed: true })]);
    await act(async () => {
      if (outcome === "success") resolveSave(saved);
      else rejectSave(new Error("Edition A disk failure"));
    });
    expect(screen.getByText("Edition B")).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByText("0 of 1 done")).toBeInTheDocument();
    if (outcome === "success") expect(qc.getQueryData<TodayEditionView>(firstKey)?.consumed_count).toBe(1);
  });

  it("ignores other editions' ledes and retains one stable subscription", async () => {
    const view = makeView([makeItem({})]);
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    renderPane();
    await screen.findByText("Default snapshot title");
    await waitFor(() => expect(vi.mocked(listen).mock.calls.length).toBeGreaterThan(0));
    const calls = vi.mocked(listen).mock.calls;
    const callback = calls[calls.length - 1][1];
    const count = calls.length;
    const event = (eventView: TodayEditionView) => ({ event: "today_lede_progress", id: 1, payload: { edition_id: eventView.edition.id, completed: 1, total: 2, message: "Preparing summaries", view: eventView } });
    const other = makeView([makeItem({ snapshot_title: "Wrong edition" })]);
    other.edition.id = "tomorrow";
    await act(async () => callback(event(other)));
    expect(screen.queryByText("Wrong edition")).not.toBeInTheDocument();
    await act(async () => callback(event(makeView([makeItem({ lede: "The written summary" })]))));
    expect(screen.getByText("The written summary")).toBeInTheDocument();
    expect(vi.mocked(listen).mock.calls.length).toBe(count);
  });
});


it("fills an empty newspaper after refreshing feeds", async () => {
  vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValueOnce(makeView([])).mockResolvedValue(makeView([makeItem({})]));
  renderPane();
  await screen.findByText("No stories yet today");
  await userEvent.click(screen.getByRole("button", { name: "Refresh feeds" }));
  expect(await screen.findByText("Default snapshot title")).toBeInTheDocument();
  expect(screen.queryByText("No stories yet today")).not.toBeInTheDocument();
});

it("uses the desktop width until an article is opened", async () => {
  vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
  const rendered = renderPane();
  const pane = rendered.container.querySelector(".today-page");
  expect(pane).toHaveStyle({ width: "100%" });
  await userEvent.click(await screen.findByRole("button", { name: "Default snapshot title" }));
  expect(pane).toHaveStyle({ width: "420px" });
});
