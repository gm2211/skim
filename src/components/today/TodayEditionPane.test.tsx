import { StrictMode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { TodayEditionPane } from "./TodayEditionPane";
import type { AppSettings, TodayEditionItem, TodayEditionView } from "../../services/types";
import { todayWindow } from "../../lib/todayEdition";
import { useUiStore } from "../../stores/uiStore";

vi.mock("../../services/commands", () => ({
  getOrGenerateTodayEdition: vi.fn(),
  getArticle: vi.fn(async () => null),
  refreshAllFeeds: vi.fn(),
  triageArticles: vi.fn(),
  listTodayEditionItems: vi.fn(),
  setTodayEditionItemConsumed: vi.fn(),
  generateTodayEditorial: vi.fn(),
  TODAY_LEDE_PROGRESS_EVENT: "today_lede_progress",
  getSettings: vi.fn(),
  updateSettings: vi.fn(),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async () => () => {}),
}));

vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

vi.mock("../common/ModelPicker", () => ({
  ModelPicker: (p: { surface: string; disabled?: boolean }) => (
    <div data-testid="model-picker" data-surface={p.surface} data-disabled={String(!!p.disabled)} />
  ),
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

function editorial(summary: string, theme = "Technology") {
  return { theme, summary, sources: [{ article_id: "article-default", quote: "Supporting passage from the report." }] };
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

function renderPane(strict = false, cached?: TodayEditionView) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  if (cached) {
    const win = todayWindow();
    qc.setQueryData(["todayEdition", win.startsAt, win.endsAt, 10], cached);
    qc.setQueryData(["settings"], { ...DEFAULT_SETTINGS, ai: { ...DEFAULT_SETTINGS.ai, provider: "ollama" } });
  }
  const result = render(
    <QueryClientProvider client={qc}>
      {strict ? <StrictMode><TodayEditionPane /></StrictMode> : <TodayEditionPane />}
    </QueryClientProvider>,
  );
  return { ...result, qc };
}

beforeEach(() => {
  vi.mocked(commands.getArticle).mockResolvedValue({ content_html: null } as Awaited<ReturnType<typeof commands.getArticle>>);
  vi.mocked(openUrl).mockReset();
  vi.mocked(listen).mockClear();
  useUiStore.setState({ selectedArticleId: null, showSettings: false });
  vi.mocked(commands.refreshAllFeeds).mockResolvedValue(1);
  vi.mocked(commands.triageArticles).mockResolvedValue({ triaged_count: 0, batches: 0, errors: [] });
  useUiStore.setState({ isPhone: false, sidebarCollapsed: false });
  vi.mocked(commands.getSettings).mockResolvedValue(DEFAULT_SETTINGS);
  vi.mocked(commands.generateTodayEditorial).mockImplementation((_id: string) => new Promise(() => {}));
});

afterEach(() => {
  vi.mocked(commands.getOrGenerateTodayEdition).mockReset();
  vi.mocked(commands.setTodayEditionItemConsumed).mockReset();
  vi.mocked(commands.getSettings).mockReset();
  vi.mocked(commands.generateTodayEditorial).mockReset();
});

describe("TodayEditionPane", () => {
  it("uses a report image, skips tracking pixels, and removes a failed image", async () => {
    vi.mocked(commands.getArticle).mockResolvedValue({
      id: "article-default", url: "https://example.com/news/story",
      content_html: '<img src="/pixel.gif" width="1"><img src="/photo.jpg" width="900">',
    } as Awaited<ReturnType<typeof commands.getArticle>>);
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    renderPane();
    const image = await screen.findByRole("img", { name: "Image from report: Default snapshot title" });
    expect(image).toHaveAttribute("src", "https://example.com/photo.jpg");
    fireEvent.error(image);
    expect(screen.queryByRole("img")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Default snapshot title" })).toBeVisible();
  });

  it("shows synthesized summaries by theme and distinguishes shared coverage from syndicated copies", async () => {
    const first = makeItem({ story_id: "shared", snapshot_title: "Shared event", editorial: editorial("Two reports describe the same consequential decision.", "Public policy") });
    first.member_articles.push({ ...first.member_articles[0], article_id: "second-report", feed_id: "second-feed", is_representative: false });
    const duplicate = makeItem({ story_id: "duplicate", snapshot_title: "One syndicated report", editorial: editorial("One report, carried twice.") });
    duplicate.member_articles.push({ ...duplicate.member_articles[0], article_id: "copy", membership_type: "duplicate", is_representative: false });
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([first, duplicate]));
    renderPane();
    expect(await screen.findByText("Two reports describe the same consequential decision.")).toBeVisible();
    await userEvent.click(screen.getByRole("button", { name: "Public policy" }));
    expect(screen.queryByRole("heading", { name: "One syndicated report" })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "All stories" }));
    await userEvent.click(screen.getByRole("button", { name: "Multiple reports" }));
    expect(screen.getByRole("heading", { name: "Shared event" })).toBeVisible();
    expect(screen.queryByRole("heading", { name: "One syndicated report" })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "2 reports" }));
    expect(screen.getByText("Supporting passage from the report.")).toBeVisible();
  });

  it("shows later editorial summaries on the next newspaper page", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView(Array.from({ length: 7 }, (_, index) => makeItem({
      story_id: `story-${index}`, editorial: index === 6 ? editorial("A concise development worth knowing.") : null,
    }))));
    renderPane();
    await userEvent.click(await screen.findByRole("button", { name: "Next page" }));
    expect(await screen.findByText("A concise development worth knowing.")).toBeVisible();
  });

  it("opens with shapes and reveals only each completed story as progress arrives", async () => {
    vi.mocked(commands.getSettings).mockResolvedValue({ ...DEFAULT_SETTINGS, ai: { ...DEFAULT_SETTINGS.ai, provider: "ollama" } });
    let loadEdition!: (view: TodayEditionView) => void;
    vi.mocked(commands.getOrGenerateTodayEdition).mockReturnValue(new Promise((resolve) => { loadEdition = resolve; }));
    renderPane();
    expect(screen.getAllByRole("status", { name: "Preparing story" })).toHaveLength(6);
    expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
    const first = makeItem({ story_id: "one", snapshot_title: "First real headline", snapshot_summary: "Raw first excerpt" });
    const second = makeItem({ story_id: "two", snapshot_title: "Second real headline", snapshot_summary: "Raw second excerpt" });
    const view = makeView([first, second]);
    await act(async () => loadEdition(view));
    await waitFor(() => expect(commands.generateTodayEditorial).toHaveBeenCalledTimes(1));
    expect(screen.getAllByRole("status", { name: "Preparing story" })).toHaveLength(2);
    expect(screen.queryByText("First real headline")).not.toBeInTheDocument();
    expect(screen.queryByText("Raw first excerpt")).not.toBeInTheDocument();
    const calls = vi.mocked(listen).mock.calls;
    const callback = calls[calls.length - 1][1];
    const requestId = vi.mocked(commands.generateTodayEditorial).mock.calls[0][1];
    const progressed = makeView([{ ...first, editorial: editorial("The completed, supported summary.") }, second]);
    await act(async () => callback({ event: "today_lede_progress", id: 1, payload: {
      edition_id: view.edition.id, request_id: requestId, completed: 1, total: 2, message: "Writing story 2", view: progressed,
    } }));
    expect(screen.getByText("First real headline")).toBeVisible();
    expect(screen.getByText("The completed, supported summary.")).toBeVisible();
    expect(screen.getAllByRole("status", { name: "Preparing story" })).toHaveLength(1);
    expect(screen.queryByText("Second real headline")).not.toBeInTheDocument();
    expect(screen.queryByText("Raw second excerpt")).not.toBeInTheDocument();
  });

  it("paginates larger editions without dropping stories and resets on a theme filter", async () => {
    const items = Array.from({ length: 20 }, (_, index) => makeItem({ story_id: `page-story-${index}`,
      snapshot_title: `Story ${index + 1}`, editorial: editorial(`Summary ${index + 1}`, index < 18 ? "Technology" : "Local") }));
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView(items));
    renderPane();
    await screen.findByText("Page 1 of 4");
    expect(screen.getAllByRole("heading", { level: 3 })).toHaveLength(6);
    expect(screen.getByRole("button", { name: "Previous page" })).toBeDisabled();
    await userEvent.click(screen.getByRole("button", { name: "Next page" }));
    expect(screen.getByText("Page 2 of 4")).toBeVisible();
    expect(screen.getAllByRole("heading", { level: 3 }).map((heading) => heading.textContent)).toEqual(["Story 7", "Story 8", "Story 9", "Story 10", "Story 11", "Story 12"]);
    await userEvent.click(screen.getByRole("button", { name: "Next page" }));
    await userEvent.click(screen.getByRole("button", { name: "Next page" }));
    expect(screen.getByText("Page 4 of 4")).toBeVisible();
    expect(screen.getAllByRole("heading", { level: 3 })).toHaveLength(2);
    expect(screen.getByRole("button", { name: "Next page" })).toBeDisabled();
    await userEvent.click(screen.getByRole("button", { name: "Local" }));
    expect(screen.getByText("Page 1 of 1")).toBeVisible();
    expect(screen.getByRole("heading", { name: "Story 19" })).toBeVisible();
    await userEvent.click(screen.getByRole("button", { name: "All stories" }));
    expect(screen.getByText("Page 1 of 4")).toBeVisible();
    await userEvent.click(screen.getByRole("button", { name: "Edition size" }));
    expect(useUiStore.getState().settingsTab).toBe("sync");
    expect(useUiStore.getState().showSettings).toBe(true);
  });

  it("does not leave skeletons forever when AI settings fail to load", async () => {
    vi.mocked(commands.getSettings).mockRejectedValue(new Error("Settings unavailable"));
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    renderPane();
    expect(await screen.findByText("Default snapshot title")).toBeVisible();
    expect(screen.queryByRole("status", { name: "Preparing story" })).not.toBeInTheDocument();
    vi.mocked(commands.getSettings).mockResolvedValue(DEFAULT_SETTINGS);
    await userEvent.click(screen.getByRole("button", { name: "Retry AI settings" }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "Retry AI settings" })).not.toBeInTheDocument());
  });

  it("mounts the today model picker for this surface", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    renderPane();
    await screen.findByText("Default snapshot title");
    expect(screen.getByTestId("model-picker")).toHaveAttribute("data-surface", "today");
    expect(screen.getByTestId("model-picker")).toHaveAttribute("data-disabled", "false");
  });

  it("disables the today model picker while ledes are being written", async () => {
    vi.mocked(commands.getSettings).mockResolvedValue({
      ...DEFAULT_SETTINGS,
      ai: { ...DEFAULT_SETTINGS.ai, provider: "openai" },
    });
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    renderPane();
    await waitFor(() => expect(screen.getByTestId("model-picker")).toHaveAttribute("data-disabled", "true"));
  });

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

  it("links a written lede to its source and shows source publication times explicitly", async () => {
    const preview = {
      ...makeItem({ lede: "A reported preview of the outcome." }),
      lede_source_article_id: "preview-source",
      member_articles: [
        {
          ...makeItem({}).member_articles[0],
          article_id: "preview-source",
          title: "The source report title",
          publication: "The Daily Example",
          published_at: 1_000,
        },
        {
          ...makeItem({}).member_articles[0],
          article_id: "unknown-time",
          title: "A report without a publication time",
          published_at: null,
          is_representative: false,
        },
      ],
    } as TodayEditionItem;
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([preview]));

    renderPane();

    const sourcePreview = await screen.findByRole("button", {
      name: /Report preview from The Daily Example: The source report title, published/,
    });
    expect(sourcePreview).toHaveTextContent("The source report title");
    expect(sourcePreview).toHaveTextContent(/Published/);
    fireEvent.click(sourcePreview);
    expect(useUiStore.getState().selectedArticleId).toBe("preview-source");

    fireEvent.click(screen.getByRole("button", { name: "2 reports" }));
    expect(screen.getByText(/Published: unknown/)).toBeInTheDocument();
  });

  it("opens a deleted preview source URL without selecting a missing article", async () => {
    const item = {
      ...makeItem({ lede: "A reported preview." }),
      lede_source_article_id: "deleted-source",
      member_articles: [{
        ...makeItem({}).member_articles[0],
        article_id: "deleted-source",
        title: "Deleted source report",
        url: "https://example.com/deleted-source",
        is_read: null,
      }],
    } as TodayEditionItem;
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([item]));

    const { container } = renderPane();

    fireEvent.click(await screen.findByRole("button", { name: /Report preview from example.com: Deleted source report/ }));
    expect(openUrl).toHaveBeenCalledWith("https://example.com/deleted-source");
    expect(useUiStore.getState().selectedArticleId).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "1 report" }));
    fireEvent.click(container.querySelector(".today-reference") as HTMLElement);
    expect(openUrl).toHaveBeenCalledTimes(2);
    expect(useUiStore.getState().selectedArticleId).toBeNull();
  });

  it("keeps deleted source attribution readable and non-clickable without a URL", async () => {
    const item = {
      ...makeItem({ lede: "A reported preview." }),
      lede_source_article_id: "deleted-source",
      member_articles: [{
        ...makeItem({}).member_articles[0],
        article_id: "deleted-source",
        title: "Deleted source report",
        url: null,
        is_read: null,
      }],
    } as TodayEditionItem;
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([item]));

    const { container } = renderPane();

    const preview = await screen.findByText("A reported preview.");
    const attribution = preview.parentElement?.querySelector(".today-story-control");
    expect(attribution).toHaveTextContent(/Report preview · example.com/);
    expect(attribution).toHaveTextContent("Deleted source report");
    expect(attribution?.tagName).toBe("DIV");
    fireEvent.click(screen.getByRole("button", { name: "1 report" }));
    const reference = container.querySelector(".today-reference");
    expect(reference).toHaveTextContent("Deleted source report");
    expect(reference?.tagName).toBe("DIV");
    expect(openUrl).not.toHaveBeenCalled();
  });

  it.each([false, true])("shows update copy only for a material frozen revision (%s)", async (material) => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({
      snapshot_delta_summary: "A new report arrived.", has_material_update: material,
    })]));
    renderPane();
    await screen.findByText("Default snapshot title");
    if (material) expect(screen.getByText(/What's new: A new report arrived/)).toBeInTheDocument();
    else expect(screen.queryByText(/What's new:/)).not.toBeInTheDocument();
  });

  it("names the publication under a story rather than the feed's own title", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));

    renderPane();

    fireEvent.click(await screen.findByRole("button", { name: "1 report" }));
    expect(screen.getAllByText("example.com")).toHaveLength(2);
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
    vi.mocked(commands.getSettings).mockResolvedValue({ ...DEFAULT_SETTINGS, ai: { ...DEFAULT_SETTINGS.ai, provider: "ollama" } });
    const view = makeView([makeItem({})]);
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    renderPane();
    await screen.findByText("Preparing summaries…");
    await waitFor(() => expect(vi.mocked(listen).mock.calls.length).toBeGreaterThan(0));
    const calls = vi.mocked(listen).mock.calls;
    const callback = calls[calls.length - 1][1];
    const count = calls.length;
    const requestId = vi.mocked(commands.generateTodayEditorial).mock.calls[0][1];
    const event = (eventView: TodayEditionView, request_id = requestId) => ({ event: "today_lede_progress", id: 1, payload: { edition_id: eventView.edition.id, request_id, completed: 1, total: 2, message: "Preparing summaries", view: eventView } });
    const other = makeView([makeItem({ snapshot_title: "Wrong edition" })]);
    other.edition.id = "tomorrow";
    await act(async () => callback(event(other)));
    expect(screen.queryByText("Wrong edition")).not.toBeInTheDocument();
    await act(async () => callback(event(makeView([makeItem({ lede: "The written summary", editorial: editorial("The written summary") })]))));
    expect(await screen.findByText("The written summary")).toBeInTheDocument();
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


describe("Today summary retries", () => {
  function enableAI() {
    vi.mocked(commands.getSettings).mockResolvedValue({ ...DEFAULT_SETTINGS, ai: { ...DEFAULT_SETTINGS.ai, provider: "ollama" } });
  }
  it("leaves no-AI excerpts readable without loading or a misleading retry", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    renderPane();
    await screen.findByText("Default summary");
    expect(commands.generateTodayEditorial).not.toHaveBeenCalled();
    expect(screen.queryByRole("button", { name: "Retry summaries" })).not.toBeInTheDocument();
    expect(screen.queryByText("Preparing summaries…")).not.toBeInTheDocument();
  });

  it.each(["failure", "partial"])("allows explicit retry after %s without automatic loops or regenerating", async (outcome) => {
    enableAI();
    const view = makeView([makeItem({})]);
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    if (outcome === "failure") vi.mocked(commands.generateTodayEditorial).mockRejectedValueOnce(new Error("Unavailable"));
    else vi.mocked(commands.generateTodayEditorial).mockResolvedValueOnce(view);
    vi.mocked(commands.generateTodayEditorial).mockResolvedValueOnce(makeView([makeItem({ lede: "Recovered summary", editorial: editorial("Recovered summary") })]));
    renderPane(true);
    await userEvent.click(await screen.findByRole("button", { name: "Retry summaries" }));
    expect(await screen.findByText("Recovered summary")).toBeInTheDocument();
    expect(commands.generateTodayEditorial).toHaveBeenCalledTimes(2);
    expect(commands.getOrGenerateTodayEdition).toHaveBeenCalledTimes(1);
    expect(screen.queryByText("Preparing summaries…")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Retry summaries" })).not.toBeInTheDocument();
  });

  it("applies completion after StrictMode replays a cached edition's effect", async () => {
    enableAI();
    const view = makeView([makeItem({})]);
    let finish!: (view: TodayEditionView) => void;
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    vi.mocked(commands.generateTodayEditorial).mockReturnValue(new Promise((resolve) => { finish = resolve; }));
    const { qc } = renderPane(true, view);
    await waitFor(() => expect(qc.isFetching()).toBe(0));
    expect(commands.generateTodayEditorial).toHaveBeenCalledTimes(1);
    await act(async () => finish(makeView([makeItem({ lede: "Completed after effect replay", editorial: editorial("Completed after effect replay") })])));
    expect(await screen.findByText("Completed after effect replay")).toBeInTheDocument();
    expect(screen.queryByText("Preparing summaries…")).not.toBeInTheDocument();
    const calls = vi.mocked(listen).mock.calls;
    const callback = calls[calls.length - 1][1];
    await act(async () => callback({ event: "today_lede_progress", id: 1, payload: { edition_id: view.edition.id, request_id: "previous-attempt", completed: 0, total: 1, message: "Stale progress", view } }));
    expect(screen.getByText("Completed after effect replay")).toBeInTheDocument();
    expect(screen.queryByText("Stale progress")).not.toBeInTheDocument();
  });

  it("survives effect replays and isolates delayed prior-edition completion", async () => {
    enableAI();
    let finish!: (view: TodayEditionView) => void;
    const first = makeView([makeItem({ snapshot_title: "First edition" })]);
    const next = makeView([makeItem({ snapshot_title: "Second edition" })]);
    next.edition = { ...next.edition, id: "second", story_limit: 5 };
    vi.mocked(commands.getOrGenerateTodayEdition).mockImplementation(async (_a, _b, _c, limit) => limit === 5 ? next : first);
    vi.mocked(commands.generateTodayEditorial).mockImplementation((id) => id === first.edition.id ? new Promise((resolve) => { finish = resolve; }) : Promise.resolve(next));
    const { qc } = renderPane(true);
    await screen.findByText("Preparing summaries…");
    expect(commands.generateTodayEditorial).toHaveBeenCalledTimes(1);
    await act(async () => { qc.setQueryData(["settings"], { ...DEFAULT_SETTINGS, ai: { ...DEFAULT_SETTINGS.ai, provider: "ollama" }, sync: { ...DEFAULT_SETTINGS.sync, today_story_limit: 5 } }); });
    await screen.findByText("Second edition");
    await screen.findByRole("button", { name: "Retry summaries" });
    await act(async () => finish({ ...first, items: [makeItem({ lede: "Late first summary", editorial: editorial("Late first summary") })] }));
    expect(screen.queryByText("Late first summary")).not.toBeInTheDocument();
    expect(screen.getByText("Second edition")).toBeInTheDocument();
    expect(screen.queryByText("Preparing summaries…")).not.toBeInTheDocument();
    expect(commands.generateTodayEditorial).toHaveBeenCalledTimes(2);
  });

  it("ignores delayed progress from a previous attempt while retrying the same edition", async () => {
    enableAI();
    const view = makeView([makeItem({})]);
    let finishRetry!: (view: TodayEditionView) => void;
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    vi.mocked(commands.generateTodayEditorial)
      .mockRejectedValueOnce(new Error("Temporary failure"))
      .mockImplementationOnce(() => new Promise((resolve) => { finishRetry = resolve; }));
    renderPane();
    await userEvent.click(await screen.findByRole("button", { name: "Retry summaries" }));
    await screen.findByText("Preparing summaries…");
    const calls = vi.mocked(commands.generateTodayEditorial).mock.calls;
    expect(calls).toHaveLength(2);
    const previousRequestId = calls[0][1];
    const activeRequestId = calls[1][1];
    expect(activeRequestId).toBeTruthy();
    expect(activeRequestId).not.toBe(previousRequestId);
    const listeners = vi.mocked(listen).mock.calls;
    const callback = listeners[listeners.length - 1][1];
    const stale = makeView([makeItem({ lede: "Stale prior-attempt summary", editorial: editorial("Stale prior-attempt summary") })]);
    await act(async () => callback({
      event: "today_lede_progress", id: 1,
      payload: { edition_id: view.edition.id, request_id: previousRequestId, completed: 1, total: 1, message: "Old attempt", view: stale },
    }));
    expect(screen.queryByText("Stale prior-attempt summary")).not.toBeInTheDocument();
    expect(screen.queryByText("Old attempt")).not.toBeInTheDocument();
    const current = makeView([makeItem({ lede: "Current retry summary", editorial: editorial("Current retry summary") })]);
    await act(async () => callback({
      event: "today_lede_progress", id: 1,
      payload: { edition_id: view.edition.id, request_id: activeRequestId, completed: 0, total: 1, message: "Current attempt", view: current },
    }));
    expect(screen.getByText("Current retry summary")).toBeInTheDocument();
    expect(screen.getByText("Current attempt")).toBeInTheDocument();
    await act(async () => finishRetry(current));
    expect(screen.queryByText("Preparing summaries…")).not.toBeInTheDocument();
  });

  it("keeps consumed state when same-attempt lede progress and completion arrive later", async () => {
    enableAI();
    const view = makeView([makeItem({})]);
    let finishLedes!: (view: TodayEditionView) => void;
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    vi.mocked(commands.generateTodayEditorial).mockReturnValue(new Promise((resolve) => { finishLedes = resolve; }));
    const consumed = makeView([makeItem({ is_consumed: true, consumed_at: 42 })]);
    vi.mocked(commands.setTodayEditionItemConsumed).mockResolvedValue(consumed);
    renderPane();
    await screen.findByText("Preparing summaries…");
    const callbacks = vi.mocked(listen).mock.calls;
    const callback = callbacks[callbacks.length - 1][1];
    const requestId = vi.mocked(commands.generateTodayEditorial).mock.calls[0][1];
    const lateProgress = makeView([makeItem({ lede: "Progress lede", editorial: editorial("Progress lede") })]);
    await act(async () => callback({ event: "today_lede_progress", id: 1, payload: {
      edition_id: view.edition.id, request_id: requestId, completed: 0, total: 1, message: "Writing", view: lateProgress,
    } }));
    await userEvent.click(screen.getByRole("button", { name: "Mark as read" }));
    await screen.findByText("All caught up");
    await act(async () => callback({ event: "today_lede_progress", id: 1, payload: {
      edition_id: view.edition.id, request_id: requestId, completed: 1, total: 1, message: "Finished", view: lateProgress,
    } }));
    expect(screen.getByText("All caught up")).toBeInTheDocument();
    expect(screen.getByText("Progress lede")).toBeInTheDocument();
    const lateCompletion = makeView([makeItem({ lede: "Completed lede", editorial: editorial("Completed lede") })]);
    await act(async () => finishLedes(lateCompletion));
    expect(screen.getByText("All caught up")).toBeInTheDocument();
    expect(screen.getByText("Progress lede")).toBeInTheDocument();
  });

  it("keeps a newly written lede when an earlier consumption save returns", async () => {
    enableAI();
    const ready = makeItem({ story_id: "ready", editorial: editorial("Already prepared") });
    const view = makeView([ready, makeItem({})]);
    let finishLedes!: (view: TodayEditionView) => void;
    let resolveSave!: (view: TodayEditionView) => void;
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    vi.mocked(commands.generateTodayEditorial).mockReturnValue(new Promise((resolve) => { finishLedes = resolve; }));
    vi.mocked(commands.setTodayEditionItemConsumed).mockReturnValue(new Promise((resolve) => { resolveSave = resolve; }));
    renderPane();
    await userEvent.click(await screen.findByRole("button", { name: "Mark as read" }));
    const callbacks = vi.mocked(listen).mock.calls;
    const callback = callbacks[callbacks.length - 1][1];
    const requestId = vi.mocked(commands.generateTodayEditorial).mock.calls[0][1];
    const latestLede = makeView([ready, makeItem({ lede: "Lede finished while save was pending", editorial: editorial("Lede finished while save was pending") })]);
    await act(async () => callback({ event: "today_lede_progress", id: 1, payload: {
      edition_id: view.edition.id, request_id: requestId, completed: 1, total: 1, message: "Finished", view: latestLede,
    } }));
    expect(screen.getByText("Lede finished while save was pending")).toBeInTheDocument();
    const savedWithoutLede = makeView([{ ...ready, is_consumed: true, consumed_at: 42 }, makeItem({})]);
    await act(async () => resolveSave(savedWithoutLede));
    expect(await screen.findByText("1 of 2 done")).toBeInTheDocument();
    expect(screen.getByText("Lede finished while save was pending")).toBeInTheDocument();
    await act(async () => finishLedes(latestLede));
  });
});
