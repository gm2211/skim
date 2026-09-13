import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { Article } from "../../services/types";
import { ArticleDetail } from "./ArticleDetail";
import { getOrFetchReaderContent } from "../../services/commands";

vi.mock("../../services/commands", () => ({
  getOrFetchReaderContent: vi.fn(),
  cancelSummarize: vi.fn().mockResolvedValue(undefined),
  recordReadingTime: vi.fn().mockResolvedValue(undefined),
}));

let selectedArticleId: string | null = "a";
const setShowSettings = vi.fn();
vi.mock("../../stores/uiStore", () => ({
  useUiStore: () => ({
    selectedArticleId,
    closeArticleDetail: vi.fn(),
    listCollapsed: false,
    sidebarCollapsed: false,
    sidebarView: { type: "all" },
    isPhone: false,
    phoneBack: vi.fn(),
    setShowSettings,
  }),
}));

const articles: Record<string, Article> = {};
vi.mock("../../hooks/useArticles", () => ({
  useArticle: (id: string | null) => ({ data: id ? articles[id] : undefined, refetch: vi.fn() }),
  useMarkRead: () => ({ mutate: vi.fn() }),
  useToggleStar: () => ({ mutate: vi.fn() }),
  useToggleRead: () => ({ mutate: vi.fn() }),
}));
vi.mock("../../hooks/useAi", () => ({
  useSummarizeArticle: () => ({ mutate: vi.fn(), reset: vi.fn(), data: null, isPending: false }),
}));
vi.mock("../../hooks/useSettings", () => ({ useSettings: () => ({ data: { ai: { provider: "none" } } }) }));
vi.mock("../../hooks/useLearning", () => ({ useReadingTimeTracker: vi.fn() }));
vi.mock("../../hooks/usePullToRefresh", () => ({
  usePullToRefresh: () => ({ pullToRefreshHandlers: {}, pullToRefreshIndicator: null, pullToRefreshContentStyle: {}, beginPull: vi.fn(), movePull: vi.fn(), endPull: vi.fn() }),
}));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));
vi.mock("../chat/ChatPanel", () => ({ ChatDrawer: () => null }));
vi.mock("../article/ArticleLearningActions", () => ({ ArticleLearningActions: () => null }));
vi.mock("../article/AggregatorDetails", () => ({ AggregatorDetails: () => null }));
vi.mock("../common/AIDisclaimer", () => ({ AIDisclaimer: () => null }));
vi.mock("../ui/NumberInput", () => ({ NumberInput: () => null }));

const deferred = <T,>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((res) => { resolve = res; });
  return { promise, resolve };
};

function article(id: string, title = `Article ${id}`): Article {
  return { id, feed_id: "feed", title, url: `https://${id}.example/story`, author: null, content_html: "<p>RSS preview</p>", content_text: null, published_at: 1, fetched_at: 1, is_read: true, is_starred: false, feedly_entry_id: null, comments_url: null, feed_title: "Feed", feed_icon_url: null };
}

beforeEach(() => {
  vi.clearAllMocks();
  selectedArticleId = "a";
  articles.a = article("a");
  articles.b = article("b");
  vi.mocked(getOrFetchReaderContent).mockReset();
  vi.stubGlobal("ResizeObserver", class { observe() {} disconnect() {} });
});

describe("ArticleDetail reader loading", () => {
  it("keeps hook order stable while article data loads and clears", async () => {
    selectedArticleId = null;
    const view = render(<ArticleDetail />);
    expect(screen.getByText("Select an article to read")).toBeInTheDocument();
    selectedArticleId = "a";
    vi.mocked(getOrFetchReaderContent).mockResolvedValue({ html: `<p>${"Loaded article ".repeat(30)}</p>`, raw_html: "<html>loaded</html>" });
    view.rerender(<ArticleDetail />);
    expect(await screen.findByText(/Loaded article/)).toBeInTheDocument();
    selectedArticleId = null;
    view.rerender(<ArticleDetail />);
    expect(screen.getByText("Select an article to read")).toBeInTheDocument();
  });

  it("shows the feed preview immediately and replaces it with extracted content", async () => {
    const request = deferred<{ html: string; raw_html: string }>();
    vi.mocked(getOrFetchReaderContent).mockReturnValue(request.promise);
    render(<ArticleDetail />);

    expect(screen.getByText("Feed preview")).toBeInTheDocument();
    expect(screen.getByText("RSS preview")).toBeInTheDocument();
    await act(async () => request.resolve({ html: `<p>${"Full article text ".repeat(20)}</p>`, raw_html: "<html><body>full</body></html>" }));
    expect(await screen.findByText(/Full article text/)).toBeInTheDocument();
    expect(screen.queryByText("Feed preview")).not.toBeInTheDocument();
  });

  it("ignores a stale response after switching articles", async () => {
    const first = deferred<{ html: string; raw_html: string }>();
    const second = deferred<{ html: string; raw_html: string }>();
    vi.mocked(getOrFetchReaderContent).mockImplementation((id) => id === "a" ? first.promise : second.promise);
    const view = render(<ArticleDetail />);
    selectedArticleId = "b";
    view.rerender(<ArticleDetail />);
    await act(async () => second.resolve({ html: `<p>${"B article ".repeat(30)}</p>`, raw_html: "<html>B</html>" }));
    await screen.findByText(/B article/);
    await act(async () => first.resolve({ html: `<p>${"A article ".repeat(30)}</p>`, raw_html: "<html>A</html>" }));
    expect(screen.queryByText(/A article/)).not.toBeInTheDocument();
    expect(screen.getByText(/B article/)).toBeInTheDocument();
  });

  it("does not mount Web until requested and keeps it mounted when returning to Reader", async () => {
    vi.mocked(getOrFetchReaderContent).mockResolvedValue({ html: `<p>${"Full article ".repeat(30)}</p>`, raw_html: "<html><body>web</body></html>" });
    const user = userEvent.setup();
    render(<ArticleDetail />);
    await waitFor(() => expect(getOrFetchReaderContent).toHaveBeenCalled());
    expect(screen.queryByTitle("Article web view")).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Web" }));
    const iframe = await screen.findByTitle("Article web view");
    await user.click(screen.getByRole("button", { name: "Reader" }));
    await user.click(screen.getByRole("button", { name: "Web" }));
    expect(screen.getByTitle("Article web view")).toBe(iframe);
  });
});
