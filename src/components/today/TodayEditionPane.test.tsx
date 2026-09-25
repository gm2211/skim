import { StrictMode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { listen } from "@tauri-apps/api/event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { TodayEditionPane } from "./TodayEditionPane";
import type { AppSettings, TodayEditionItem, TodayEditionView, TodayPreparationStatus } from "../../services/types";
import { todayWindow } from "../../lib/todayEdition";
import { useUiStore } from "../../stores/uiStore";

vi.mock("../../services/commands", () => ({
  getOrGenerateTodayEdition: vi.fn(),
  getTodayPreparationStatus: vi.fn(),
  prepareTodaySlice: vi.fn(),
  cancelTodayPreparation: vi.fn(),
  publishPreparedTodayEdition: vi.fn(),
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

function makePreparation(overrides: Partial<TodayPreparationStatus> = {}): TodayPreparationStatus {
  return {
    scope_key: "today-scope",
    eligible_count: 12,
    assessed_count: 0,
    assessment_failed_count: 0,
    proposal_window_count: 4,
    proposal_completed_count: 0,
    proposal_failed_count: 0,
    proposed_pair_count: 0,
    verified_pair_count: 0,
    verification_failed_count: 0,
    state: "preparing",
    manifest: "manifest-1",
    can_publish: false,
    active_edition_id: "today-1-2-10",
    ...overrides,
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
  vi.mocked(listen).mockClear();
  useUiStore.setState({ selectedArticleId: null });
  vi.mocked(commands.refreshAllFeeds).mockResolvedValue(1);
  vi.mocked(commands.triageArticles).mockResolvedValue({ triaged_count: 0, batches: 0, errors: [] });
  useUiStore.setState({ isPhone: false, sidebarCollapsed: false });
  vi.mocked(commands.getSettings).mockResolvedValue(DEFAULT_SETTINGS);
  vi.mocked(commands.generateTodayLedes).mockImplementation((_id: string) => new Promise(() => {}));
  vi.mocked(commands.getTodayPreparationStatus).mockResolvedValue(makePreparation({ state: "disabled" }));
  vi.mocked(commands.prepareTodaySlice).mockResolvedValue(makePreparation({ state: "disabled" }));
  vi.mocked(commands.cancelTodayPreparation).mockResolvedValue(undefined);
});

afterEach(() => {
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  vi.mocked(commands.getOrGenerateTodayEdition).mockReset();
  vi.mocked(commands.setTodayEditionItemConsumed).mockReset();
  vi.mocked(commands.getSettings).mockReset();
  vi.mocked(commands.generateTodayLedes).mockReset();
  vi.mocked(commands.getTodayPreparationStatus).mockReset();
  vi.mocked(commands.prepareTodaySlice).mockReset();
  vi.mocked(commands.cancelTodayPreparation).mockReset();
  vi.mocked(commands.publishPreparedTodayEdition).mockReset();
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
    vi.mocked(commands.getSettings).mockResolvedValue({ ...DEFAULT_SETTINGS, ai: { ...DEFAULT_SETTINGS.ai, provider: "ollama" } });
    const view = makeView([makeItem({})]);
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    renderPane();
    await screen.findByText("Default snapshot title");
    await waitFor(() => expect(vi.mocked(listen).mock.calls.length).toBeGreaterThan(0));
    const calls = vi.mocked(listen).mock.calls;
    const callback = calls[calls.length - 1][1];
    const count = calls.length;
    const requestId = vi.mocked(commands.generateTodayLedes).mock.calls[0][1];
    const event = (eventView: TodayEditionView, request_id = requestId) => ({ event: "today_lede_progress", id: 1, payload: { edition_id: eventView.edition.id, request_id, completed: 1, total: 2, message: "Preparing summaries", view: eventView } });
    const other = makeView([makeItem({ snapshot_title: "Wrong edition" })]);
    other.edition.id = "tomorrow";
    await act(async () => callback(event(other)));
    expect(screen.queryByText("Wrong edition")).not.toBeInTheDocument();
    await act(async () => callback(event(makeView([makeItem({ lede: "The written summary" })]))));
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
    expect(commands.generateTodayLedes).not.toHaveBeenCalled();
    expect(screen.queryByRole("button", { name: "Retry summaries" })).not.toBeInTheDocument();
    expect(screen.queryByText("Preparing summaries…")).not.toBeInTheDocument();
  });

  it.each(["failure", "partial"])("allows explicit retry after %s without automatic loops or regenerating", async (outcome) => {
    enableAI();
    const view = makeView([makeItem({})]);
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    if (outcome === "failure") vi.mocked(commands.generateTodayLedes).mockRejectedValueOnce(new Error("Unavailable"));
    else vi.mocked(commands.generateTodayLedes).mockResolvedValueOnce(view);
    vi.mocked(commands.generateTodayLedes).mockResolvedValueOnce(makeView([makeItem({ lede: "Recovered summary" })]));
    renderPane(true);
    await userEvent.click(await screen.findByRole("button", { name: "Retry summaries" }));
    expect(await screen.findByText("Recovered summary")).toBeInTheDocument();
    expect(commands.generateTodayLedes).toHaveBeenCalledTimes(2);
    expect(commands.getOrGenerateTodayEdition).toHaveBeenCalledTimes(1);
    expect(screen.queryByText("Preparing summaries…")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Retry summaries" })).not.toBeInTheDocument();
  });

  it("applies completion after StrictMode replays a cached edition's effect", async () => {
    enableAI();
    const view = makeView([makeItem({})]);
    let finish!: (view: TodayEditionView) => void;
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    vi.mocked(commands.generateTodayLedes).mockReturnValue(new Promise((resolve) => { finish = resolve; }));
    const { qc } = renderPane(true, view);
    await waitFor(() => expect(qc.isFetching()).toBe(0));
    expect(commands.generateTodayLedes).toHaveBeenCalledTimes(1);
    await act(async () => finish(makeView([makeItem({ lede: "Completed after effect replay" })])));
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
    vi.mocked(commands.generateTodayLedes).mockImplementation((id) => id === first.edition.id ? new Promise((resolve) => { finish = resolve; }) : Promise.resolve(next));
    const { qc } = renderPane(true);
    await screen.findByText("Preparing summaries…");
    expect(commands.generateTodayLedes).toHaveBeenCalledTimes(1);
    await act(async () => { qc.setQueryData(["settings"], { ...DEFAULT_SETTINGS, ai: { ...DEFAULT_SETTINGS.ai, provider: "ollama" }, sync: { ...DEFAULT_SETTINGS.sync, today_story_limit: 5 } }); });
    await screen.findByText("Second edition");
    await screen.findByRole("button", { name: "Retry summaries" });
    await act(async () => finish({ ...first, items: [makeItem({ lede: "Late first summary" })] }));
    expect(screen.queryByText("Late first summary")).not.toBeInTheDocument();
    expect(screen.getByText("Second edition")).toBeInTheDocument();
    expect(screen.queryByText("Preparing summaries…")).not.toBeInTheDocument();
    expect(commands.generateTodayLedes).toHaveBeenCalledTimes(2);
  });

  it("ignores delayed progress from a previous attempt while retrying the same edition", async () => {
    enableAI();
    const view = makeView([makeItem({})]);
    let finishRetry!: (view: TodayEditionView) => void;
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    vi.mocked(commands.generateTodayLedes)
      .mockRejectedValueOnce(new Error("Temporary failure"))
      .mockImplementationOnce(() => new Promise((resolve) => { finishRetry = resolve; }));
    renderPane();
    await userEvent.click(await screen.findByRole("button", { name: "Retry summaries" }));
    await screen.findByText("Preparing summaries…");
    const calls = vi.mocked(commands.generateTodayLedes).mock.calls;
    expect(calls).toHaveLength(2);
    const previousRequestId = calls[0][1];
    const activeRequestId = calls[1][1];
    expect(activeRequestId).toBeTruthy();
    expect(activeRequestId).not.toBe(previousRequestId);
    const listeners = vi.mocked(listen).mock.calls;
    const callback = listeners[listeners.length - 1][1];
    const stale = makeView([makeItem({ lede: "Stale prior-attempt summary" })]);
    await act(async () => callback({
      event: "today_lede_progress", id: 1,
      payload: { edition_id: view.edition.id, request_id: previousRequestId, completed: 1, total: 1, message: "Old attempt", view: stale },
    }));
    expect(screen.queryByText("Stale prior-attempt summary")).not.toBeInTheDocument();
    expect(screen.queryByText("Old attempt")).not.toBeInTheDocument();
    const current = makeView([makeItem({ lede: "Current retry summary" })]);
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
    vi.mocked(commands.generateTodayLedes).mockReturnValue(new Promise((resolve) => { finishLedes = resolve; }));
    const consumed = makeView([makeItem({ is_consumed: true, consumed_at: 42 })]);
    vi.mocked(commands.setTodayEditionItemConsumed).mockResolvedValue(consumed);
    renderPane();
    await userEvent.click(await screen.findByRole("button", { name: "Mark as read" }));
    await screen.findByText("All caught up");
    const callbacks = vi.mocked(listen).mock.calls;
    const callback = callbacks[callbacks.length - 1][1];
    const requestId = vi.mocked(commands.generateTodayLedes).mock.calls[0][1];
    const lateProgress = makeView([makeItem({ lede: "Progress lede" })]);
    await act(async () => callback({ event: "today_lede_progress", id: 1, payload: {
      edition_id: view.edition.id, request_id: requestId, completed: 0, total: 1, message: "Writing", view: lateProgress,
    } }));
    expect(screen.getByText("All caught up")).toBeInTheDocument();
    expect(screen.getByText("Progress lede")).toBeInTheDocument();
    const lateCompletion = makeView([makeItem({ lede: "Completed lede" })]);
    await act(async () => finishLedes(lateCompletion));
    expect(screen.getByText("All caught up")).toBeInTheDocument();
    expect(screen.getByText("Progress lede")).toBeInTheDocument();
  });

  it("keeps a newly written lede when an earlier consumption save returns", async () => {
    enableAI();
    const view = makeView([makeItem({})]);
    let finishLedes!: (view: TodayEditionView) => void;
    let resolveSave!: (view: TodayEditionView) => void;
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(view);
    vi.mocked(commands.generateTodayLedes).mockReturnValue(new Promise((resolve) => { finishLedes = resolve; }));
    vi.mocked(commands.setTodayEditionItemConsumed).mockReturnValue(new Promise((resolve) => { resolveSave = resolve; }));
    renderPane();
    await userEvent.click(await screen.findByRole("button", { name: "Mark as read" }));
    const callbacks = vi.mocked(listen).mock.calls;
    const callback = callbacks[callbacks.length - 1][1];
    const requestId = vi.mocked(commands.generateTodayLedes).mock.calls[0][1];
    const latestLede = makeView([makeItem({ lede: "Lede finished while save was pending" })]);
    await act(async () => callback({ event: "today_lede_progress", id: 1, payload: {
      edition_id: view.edition.id, request_id: requestId, completed: 1, total: 1, message: "Finished", view: latestLede,
    } }));
    expect(screen.getByText("Lede finished while save was pending")).toBeInTheDocument();
    const savedWithoutLede = makeView([makeItem({ is_consumed: true, consumed_at: 42 })]);
    await act(async () => resolveSave(savedWithoutLede));
    expect(await screen.findByText("All caught up")).toBeInTheDocument();
    expect(screen.getByText("Lede finished while save was pending")).toBeInTheDocument();
    await act(async () => finishLedes(latestLede));
  });
});

describe("Today preparation lifecycle", () => {
  it("keeps the frozen edition visible while bounded slices advance independent coverage", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({ snapshot_title: "Frozen edition" })]));
    vi.mocked(commands.getTodayPreparationStatus).mockResolvedValue(makePreparation());
    vi.mocked(commands.prepareTodaySlice)
      .mockResolvedValueOnce(makePreparation({ assessed_count: 5, proposal_completed_count: 1, proposed_pair_count: 6, verified_pair_count: 2 }))
      .mockResolvedValueOnce(makePreparation({ state: "ready", assessed_count: 12, proposal_completed_count: 4, proposed_pair_count: 20, verified_pair_count: 20, can_publish: true }));
    renderPane();
    expect(await screen.findByText("Frozen edition")).toBeInTheDocument();
    expect(await screen.findByText("Updated edition ready")).toBeInTheDocument();
    expect(commands.prepareTodaySlice).toHaveBeenCalledTimes(2);
    expect(screen.getByText(/12 of 12 stories reviewed/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open updated edition" })).toBeInTheDocument();
    expect(screen.getByText("Frozen edition")).toBeInTheDocument();
    expect(commands.publishPreparedTodayEdition).not.toHaveBeenCalled();
  });

  it("resumes preparation after a successful edition refresh without replacing the current reading snapshot", async () => {
    const frozen = makeView([makeItem({ snapshot_title: "Still reading this edition" })]);
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(frozen);
    vi.mocked(commands.getTodayPreparationStatus)
      .mockResolvedValueOnce(makePreparation({ state: "ready", can_publish: false }))
      .mockResolvedValueOnce(makePreparation({ state: "preparing", assessed_count: 3 }));
    vi.mocked(commands.prepareTodaySlice).mockResolvedValue(makePreparation({ state: "ready", can_publish: false, assessed_count: 12 }));
    const { qc } = renderPane();
    expect(await screen.findByText("Still reading this edition")).toBeInTheDocument();
    await act(async () => { await qc.invalidateQueries({ queryKey: ["todayEdition"] }); });
    await waitFor(() => expect(commands.getTodayPreparationStatus).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(commands.prepareTodaySlice).toHaveBeenCalledTimes(1));
    expect(screen.getByText("Still reading this edition")).toBeInTheDocument();
    expect(commands.publishPreparedTodayEdition).not.toHaveBeenCalled();
  });

  it("rechecks preparation after AI settings change without changing the story-limit scope", async () => {
    const frozen = makeView([makeItem({ snapshot_title: "Still reading this edition" })]);
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(frozen);
    vi.mocked(commands.getTodayPreparationStatus)
      .mockResolvedValueOnce(makePreparation({ state: "ready", can_publish: false }))
      .mockResolvedValueOnce(makePreparation({ state: "preparing", assessed_count: 4 }));
    vi.mocked(commands.prepareTodaySlice).mockResolvedValue(makePreparation({ state: "ready", can_publish: false }));
    const { qc } = renderPane();
    expect(await screen.findByText("Still reading this edition")).toBeInTheDocument();
    await waitFor(() => expect(commands.getTodayPreparationStatus).toHaveBeenCalledTimes(1));
    await act(async () => {
      qc.setQueryData(["settings"], { ...DEFAULT_SETTINGS, ai: { ...DEFAULT_SETTINGS.ai, provider: "ollama", model: "new-model" } }, { updatedAt: Date.now() + 1_000 });
    });
    await waitFor(() => expect(commands.getTodayPreparationStatus).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(commands.prepareTodaySlice).toHaveBeenCalledTimes(1));
    expect(screen.getByText("Still reading this edition")).toBeInTheDocument();
  });

  it("rechecks preparation after saving consumed state without replacing the frozen story", async () => {
    const frozen = makeView([makeItem({ snapshot_title: "Current frozen story" })]);
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(frozen);
    vi.mocked(commands.getTodayPreparationStatus)
      .mockResolvedValueOnce(makePreparation({ state: "ready", can_publish: false }))
      .mockResolvedValueOnce(makePreparation({ state: "ready", can_publish: false, eligible_count: 11 }));
    vi.mocked(commands.setTodayEditionItemConsumed).mockResolvedValue(makeView([makeItem({ is_consumed: true, consumed_at: 99, snapshot_title: "Current frozen story" })]));
    renderPane();
    expect(await screen.findByText("Current frozen story")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Mark as read" }));
    await waitFor(() => expect(commands.getTodayPreparationStatus).toHaveBeenCalledTimes(2));
    expect(screen.getByText("Current frozen story")).toBeInTheDocument();
  });

  it("opens a prepared successor only after an explicit click", async () => {
    const original = makeView([makeItem({ snapshot_title: "Current frozen edition" })]);
    const successor = makeView([makeItem({ snapshot_title: "Prepared successor" })]);
    successor.edition.id = "successor-edition";
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(original);
    vi.mocked(commands.getTodayPreparationStatus).mockResolvedValue(makePreparation({ state: "ready", can_publish: true }));
    vi.mocked(commands.publishPreparedTodayEdition).mockResolvedValue(successor);
    renderPane();
    expect(await screen.findByText("Current frozen edition")).toBeInTheDocument();
    expect(commands.publishPreparedTodayEdition).not.toHaveBeenCalled();
    await userEvent.click(await screen.findByRole("button", { name: "Open updated edition" }));
    expect(await screen.findByText("Prepared successor")).toBeInTheDocument();
    expect(screen.queryByText("Current frozen edition")).not.toBeInTheDocument();
    expect(commands.publishPreparedTodayEdition).toHaveBeenCalledWith(expect.any(Number), expect.any(Number), expect.any(Number), 10, "manifest-1");
  });

  it("surfaces incomplete checks and retries failed work explicitly", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    vi.mocked(commands.getTodayPreparationStatus).mockResolvedValue(makePreparation({
      state: "failed", assessed_count: 10, assessment_failed_count: 2, proposal_window_count: 4,
      proposal_completed_count: 3, proposal_failed_count: 1, proposed_pair_count: 8,
      verified_pair_count: 6, verification_failed_count: 2,
    }));
    vi.mocked(commands.prepareTodaySlice).mockResolvedValue(makePreparation({
      state: "ready", assessed_count: 12, assessment_failed_count: 0, proposal_completed_count: 4,
      proposal_failed_count: 0, proposed_pair_count: 8, verified_pair_count: 8,
      verification_failed_count: 0, can_publish: true,
    }));
    renderPane();
    expect(await screen.findByText("Some stories could not be reviewed")).toBeInTheDocument();
    expect(screen.getByText("2 stories could not be reviewed.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Retry checks" }));
    expect(await screen.findByText("Updated edition ready")).toBeInTheDocument();
    expect(commands.prepareTodaySlice).toHaveBeenCalledWith(expect.any(Number), expect.any(Number), expect.any(Number), 10, expect.any(String), true);
  });

  it("does not imply stories were missed when only related-report checks failed", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    vi.mocked(commands.getTodayPreparationStatus).mockResolvedValue(makePreparation({
      state: "failed", assessed_count: 12, proposal_window_count: 4,
      proposal_completed_count: 3, proposal_failed_count: 1, proposed_pair_count: 8,
      verified_pair_count: 6,
    }));
    renderPane();
    expect(await screen.findByText("Related-report checks need another look")).toBeInTheDocument();
    expect(screen.getByText(/Some related reports need another check/)).toBeInTheDocument();
    expect(screen.queryByText(/stories could not be reviewed/)).not.toBeInTheDocument();
  });

  it("cancels the exact in-flight slice on unmount and ignores its late reply", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({ snapshot_title: "Frozen while waiting" })]));
    vi.mocked(commands.getTodayPreparationStatus).mockResolvedValue(makePreparation());
    let finish!: (status: TodayPreparationStatus) => void;
    vi.mocked(commands.prepareTodaySlice).mockReturnValue(new Promise((resolve) => { finish = resolve; }));
    const rendered = renderPane();
    await screen.findByText("Frozen while waiting");
    await waitFor(() => expect(commands.prepareTodaySlice).toHaveBeenCalledTimes(1));
    const requestId = vi.mocked(commands.prepareTodaySlice).mock.calls[0][4];
    rendered.unmount();
    expect(commands.cancelTodayPreparation).toHaveBeenCalledWith(requestId);
    await act(async () => finish(makePreparation({ state: "ready", can_publish: true })));
    expect(commands.publishPreparedTodayEdition).not.toHaveBeenCalled();
  });

  it("cancels a retry when the story-limit scope changes and ignores its late status", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    vi.mocked(commands.getTodayPreparationStatus).mockResolvedValue(makePreparation({ state: "failed" }));
    let finish!: (status: TodayPreparationStatus) => void;
    vi.mocked(commands.prepareTodaySlice).mockReturnValue(new Promise((resolve) => { finish = resolve; }));
    const { qc } = renderPane();
    await userEvent.click(await screen.findByRole("button", { name: "Retry checks" }));
    const requestId = vi.mocked(commands.prepareTodaySlice).mock.calls[0][4];
    await act(async () => {
      qc.setQueryData(["settings"], { ...DEFAULT_SETTINGS, sync: { ...DEFAULT_SETTINGS.sync, today_story_limit: 5 } });
    });
    await waitFor(() => expect(commands.cancelTodayPreparation).toHaveBeenCalledWith(requestId));
    await act(async () => finish(makePreparation({ state: "ready", can_publish: true })));
    expect(screen.queryByRole("button", { name: "Open updated edition" })).not.toBeInTheDocument();
  });

  it("cancels the active retry when the page becomes hidden", async () => {
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    vi.mocked(commands.getTodayPreparationStatus).mockResolvedValue(makePreparation({ state: "failed" }));
    let finish!: (status: TodayPreparationStatus) => void;
    vi.mocked(commands.prepareTodaySlice).mockReturnValue(new Promise((resolve) => { finish = resolve; }));
    const rendered = renderPane();
    await userEvent.click(await screen.findByRole("button", { name: "Retry checks" }));
    const requestId = vi.mocked(commands.prepareTodaySlice).mock.calls[0][4];
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });
    await act(async () => document.dispatchEvent(new Event("visibilitychange")));
    expect(commands.cancelTodayPreparation).toHaveBeenCalledWith(requestId);
    await act(async () => finish(makePreparation({ state: "ready", can_publish: true })));
    expect(screen.queryByRole("button", { name: "Open updated edition" })).not.toBeInTheDocument();
    rendered.unmount();
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  });

  it("shows preparation transport failures and stops automatic retries", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    vi.mocked(commands.getTodayPreparationStatus).mockResolvedValue(makePreparation());
    vi.mocked(commands.prepareTodaySlice).mockRejectedValue(new Error("Provider timeout"));
    renderPane();
    expect(await screen.findByRole("alert")).toHaveTextContent("Provider timeout");
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(commands.prepareTodaySlice).toHaveBeenCalledTimes(1);
  });

  it("retries a failed status read through the status query, not the slice retry action", async () => {
    vi.mocked(commands.getOrGenerateTodayEdition).mockResolvedValue(makeView([makeItem({})]));
    vi.mocked(commands.getTodayPreparationStatus)
      .mockRejectedValueOnce(new Error("Status unavailable"))
      .mockResolvedValueOnce(makePreparation({ state: "ready", can_publish: true }));
    renderPane();
    expect(await screen.findByRole("alert")).toHaveTextContent("Could not load story coverage status");
    await userEvent.click(screen.getByRole("button", { name: "Retry status" }));
    expect(await screen.findByText("Updated edition ready")).toBeInTheDocument();
    expect(commands.prepareTodaySlice).not.toHaveBeenCalled();
  });
});
