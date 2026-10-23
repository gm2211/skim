import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { listen } from "@tauri-apps/api/event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { TodayEditionPane } from "./TodayEditionPane";
import type { AppSettings, DispatchEdition } from "../../services/types";
import { dispatchWindow, splitCitations } from "../../lib/dispatch";
import { useUiStore } from "../../stores/uiStore";
import { useAgentChatStore } from "../../stores/agentChatStore";

vi.mock("../../services/commands", () => ({
  getDispatch: vi.fn(),
  writeDispatch: vi.fn(),
  DISPATCH_PROGRESS_EVENT: "dispatch_progress",
  getOrGenerateTodayEdition: vi.fn(),
  generateTodayEditorial: vi.fn(),
  TODAY_LEDE_PROGRESS_EVENT: "today_lede_progress",
  getTodayStoryImage: vi.fn(async () => null),
  refreshAllFeeds: vi.fn(),
  getSettings: vi.fn(),
  updateSettings: vi.fn(),
  listFeeds: vi.fn(async () => []),
  listFolders: vi.fn(async () => []),
}));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn(async () => () => {}) }));
vi.mock("../common/ModelPicker", () => ({ ModelPicker: () => <div data-testid="model-picker" /> }));

import * as commands from "../../services/commands";

const SETTINGS = {
  ai: { provider: "anthropic", model: "claude-test" },
  appearance: { theme: "dark", font_size: 14, show_excerpt_in_list: false },
  sync: { refresh_interval_minutes: 30, max_articles_per_feed: 200, recent_cap: 3000, today_story_limit: 10, dispatch_days: 3 },
} as unknown as AppSettings;

function edition(overrides: Partial<DispatchEdition> = {}): DispatchEdition {
  const win = dispatchWindow(new Date(), 1, 3);
  return {
    id: "dispatch-1",
    days: 3,
    starts_at: win.startsAt,
    ends_at: win.endsAt,
    generated_at: win.startsAt + 10,
    article_count: 214,
    status: "complete",
    model: "claude-test",
    themes: [
      {
        kicker: "Security", headline: "Two certificate authorities breached in a week", dek: "Browsers are deciding whether to keep trusting them.",
        importance: 5, article_ids: ["a1", "a2"],
        body: ["Attackers issued rogue certificates [1]. A second CA confirmed a breach [2, 9]."],
        takeaways: ["Check pinned certificates [1]."], error: null,
      },
      {
        kicker: "Databases", headline: "DuckDB 2.0 ships as an LTS release", dek: "A big release.",
        importance: 2, article_ids: ["a3"], body: [], takeaways: [], error: "The AI provider was busy or rate limited. Try again in a moment.",
      },
    ],
    briefs: [{ text: "A small thing happened.", article_ids: ["a4"] }],
    articles: [
      { id: "a1", title: "CA breach", publication: "Ars Technica", url: "https://a/1", published_at: 1, feed_icon_url: null, image_url: null },
      { id: "a2", title: "Second CA", publication: "The Register", url: "https://a/2", published_at: 1, feed_icon_url: null, image_url: null },
      { id: "a3", title: "DuckDB 2.0", publication: "duckdb.org", url: "https://a/3", published_at: 1, feed_icon_url: null, image_url: null },
      { id: "a4", title: "Small", publication: "Lobsters", url: "https://a/4", published_at: 1, feed_icon_url: null, image_url: null },
    ],
    new_article_count: 0,
    ...overrides,
  };
}

function renderPane() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  qc.setQueryData(["settings"], SETTINGS);
  return render(<QueryClientProvider client={qc}><TodayEditionPane /></QueryClientProvider>);
}

beforeEach(() => {
  vi.mocked(commands.getSettings).mockResolvedValue(SETTINGS);
  useUiStore.setState({ isPhone: false, sidebarCollapsed: false, selectedArticleId: null, sidebarView: { type: "today" }, todayPage: 1 });
});
afterEach(() => vi.clearAllMocks());

describe("The Briefing", () => {
  it("sets the AI's pieces with citations that open the reporting, and never starts the story page's work", async () => {
    vi.mocked(commands.getDispatch).mockResolvedValue(edition());
    const open = vi.fn();
    useUiStore.setState({ openArticleFromToday: open });
    renderPane();
    expect(await screen.findByRole("heading", { name: "Two certificate authorities breached in a week" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "The Briefing" })).toBeInTheDocument();
    expect(screen.getByText(/Written by AI from 214 articles/)).toBeInTheDocument();
    // [9] names no report of this piece, so it isn't a link.
    const lead = screen.getAllByRole("article")[0];
    expect(within(lead).getAllByRole("button", { name: /^\d$/ }).map((b) => b.textContent)).toEqual(["1", "2", "1"]);
    await userEvent.click(within(lead).getByRole("button", { name: "2" }));
    expect(open).toHaveBeenCalledWith("a2");
    expect(screen.getByText("Check pinned certificates")).toBeInTheDocument();
    expect(screen.getByText(/1 piece wasn't written/)).toBeInTheDocument();
    expect(commands.writeDispatch).not.toHaveBeenCalled();
    expect(commands.getOrGenerateTodayEdition).not.toHaveBeenCalled();
  });

  it("writes the edition the first time a page is opened and shows pieces as they are filed", async () => {
    vi.mocked(commands.getDispatch).mockResolvedValue(null);
    let finish: (value: DispatchEdition) => void = () => {};
    vi.mocked(commands.writeDispatch).mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    let emit: (payload: unknown) => void = () => {};
    vi.mocked(listen).mockImplementation(async (_name, handler) => {
      emit = (payload) => (handler as (event: { payload: unknown }) => void)({ payload });
      return () => {};
    });
    renderPane();
    await waitFor(() => expect(commands.writeDispatch).toHaveBeenCalledTimes(1));
    const [, , days, mode, requestId] = vi.mocked(commands.writeDispatch).mock.calls[0];
    expect([days, mode]).toEqual([3, "open"]);
    expect(screen.getByLabelText("Writing The Briefing")).toBeInTheDocument();
    const partial = edition({ status: "writing" });
    partial.themes[0].body = [];
    act(() => emit({ edition_id: "dispatch-1", request_id: requestId, message: "Filed 0 of 2…", edition: partial }));
    expect(await screen.findByText("Filed 0 of 2…")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Two certificate authorities breached in a week" })).toBeInTheDocument();
    act(() => finish(edition()));
    expect(await screen.findByText("Check pinned certificates")).toBeInTheDocument();
    expect(screen.queryByText("Filed 0 of 2…")).not.toBeInTheDocument();
  });

  it("asks about one piece with its reports as the story", async () => {
    vi.mocked(commands.getDispatch).mockResolvedValue(edition());
    renderPane();
    const lead = (await screen.findAllByRole("article"))[0];
    await userEvent.click(within(lead).getByRole("button", { name: /Ask about this/ }));
    const story = useAgentChatStore.getState().seed?.context.story;
    expect(story?.title).toBe("Two certificate authorities breached in a week");
    expect(story?.article_ids).toEqual(["a1", "a2"]);
    expect(story?.summary).not.toContain("[1]");
  });

  it("offers a new edition when articles arrived after this one was written", async () => {
    vi.mocked(commands.getDispatch).mockResolvedValue(edition({ new_article_count: 37 }));
    vi.mocked(commands.writeDispatch).mockImplementation(() => new Promise(() => {}));
    renderPane();
    expect(await screen.findByText("37 new articles since this edition was written.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Write a new edition" }));
    expect(vi.mocked(commands.writeDispatch).mock.calls[0][3]).toBe("rewrite");
  });

  it("says why an edition couldn't be written and lets the reader try again", async () => {
    vi.mocked(commands.getDispatch).mockResolvedValue(null);
    vi.mocked(commands.writeDispatch).mockRejectedValueOnce("The editor didn't pick any themes from the listing.");
    renderPane();
    expect(await screen.findByText(/Couldn't write this edition/)).toBeInTheDocument();
    vi.mocked(commands.writeDispatch).mockImplementation(() => new Promise(() => {}));
    await userEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(commands.writeDispatch).toHaveBeenCalledTimes(2);
  });
});

describe("dispatch windows and citations", () => {
  it("reads whole local days and steps back one edition per page", () => {
    const now = new Date(2026, 9, 22, 13, 0);
    const front = dispatchWindow(now, 1, 3);
    expect(new Date(front.startsAt * 1000)).toEqual(new Date(2026, 9, 20));
    expect(new Date(front.endsAt * 1000)).toEqual(new Date(2026, 9, 23));
    const back = dispatchWindow(now, 2, 3);
    expect(new Date(back.startsAt * 1000)).toEqual(new Date(2026, 9, 17));
    expect(back.endsAt).toBe(front.startsAt);
  });

  it("splits a paragraph into words and citations", () => {
    expect(splitCitations("Breached [1]. Confirmed [2, 3].")).toEqual([
      { text: "Breached" }, { cites: [1] }, { text: ". Confirmed" }, { cites: [2, 3] }, { text: "." },
    ]);
  });
});
