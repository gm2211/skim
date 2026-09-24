import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { Article, ArticleSummary } from "../../services/types";
import { ArticleDetail } from "./ArticleDetail";
import { chatWithArticle, getOrFetchReaderContent } from "../../services/commands";

vi.mock("../../services/commands", () => ({
  getOrFetchReaderContent: vi.fn(),
  chatWithArticle: vi.fn(),
  webSearch: vi.fn(),
  cancelSummarize: vi.fn().mockResolvedValue(undefined),
  recordReadingTime: vi.fn().mockResolvedValue(undefined),
}));

let selectedArticleId: string | null = "a";
const setShowSettings = vi.fn();
vi.mock("../../stores/uiStore", () => ({
  useUiStore: (selector?: (state: any) => unknown) => {
    const state = {
    selectedArticleId,
    closeArticleDetail: vi.fn(),
    listCollapsed: false,
    sidebarCollapsed: false,
    sidebarView: { type: "all" },
    isPhone: false,
    phoneBack: vi.fn(),
    setShowSettings,
  };
    return selector ? selector(state) : state;
  },
}));

const articles: Record<string, Article> = {};
vi.mock("../../hooks/useArticles", () => ({
  useArticle: (id: string | null) => ({ data: id ? articles[id] : undefined, refetch: vi.fn() }),
  useMarkRead: () => ({ mutate: vi.fn() }),
  useToggleStar: () => ({ mutate: vi.fn() }),
  useToggleRead: () => ({ mutate: vi.fn() }),
}));
const summarizeMutation = { mutate: vi.fn(), reset: vi.fn(), data: null as ArticleSummary | null, isPending: false };
let aiSettings = { provider: "none", summary_length: "custom", summary_custom_word_count: 150 };
vi.mock("../../hooks/useAi", () => ({
  useSummarizeArticle: () => summarizeMutation,
}));
vi.mock("../../hooks/useSettings", () => ({ useSettings: () => ({ data: { ai: aiSettings } }) }));
vi.mock("../../hooks/useLearning", () => ({ useReadingTimeTracker: vi.fn() }));
vi.mock("../../hooks/usePullToRefresh", () => ({
  usePullToRefresh: () => ({ pullToRefreshHandlers: {}, pullToRefreshIndicator: null, pullToRefreshContentStyle: {}, beginPull: vi.fn(), movePull: vi.fn(), endPull: vi.fn() }),
}));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));
vi.mock("../article/ArticleLearningActions", () => ({ ArticleLearningActions: () => null }));
vi.mock("../article/AggregatorDetails", () => ({ AggregatorDetails: () => null }));
vi.mock("../common/AIDisclaimer", () => ({ AIDisclaimer: () => null }));

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
  summarizeMutation.data = null;
  selectedArticleId = "a";
  aiSettings = { provider: "none", summary_length: "custom", summary_custom_word_count: 150 };
  articles.a = article("a");
  articles.b = article("b");
  vi.mocked(getOrFetchReaderContent).mockReset();
  vi.stubGlobal("ResizeObserver", class { observe() {} disconnect() {} });
});

describe("ArticleDetail reader loading", () => {
  it("makes the visible summary available to the article question", async () => {
    aiSettings.provider = "anthropic";
    summarizeMutation.data = { article_id: "a", bullet_summary: "Main claim", full_summary: "Detailed reasoning", provider: "anthropic", model: "test", created_at: 1 };
    vi.mocked(getOrFetchReaderContent).mockResolvedValue({ html: "<p>Article</p>", raw_html: "" });
    vi.mocked(chatWithArticle).mockResolvedValue({ content: "Explanation", web_citations: [], provider: "anthropic", model: "test" });
    const user = userEvent.setup();
    render(<ArticleDetail />);
    await user.click(screen.getAllByRole("button", { name: "Chat with article" })[0]);
    await user.type(screen.getByPlaceholderText("Ask about this article..."), "Explain that summary{Enter}");
    await screen.findByText("Explanation");
    expect(chatWithArticle).toHaveBeenCalledWith("a", [{ role: "user", content: "Explain that summary" }], "Main claim\n\nDetailed reasoning");
  });

  it("forwards per-article word count and latest custom prompt to summary generation", async () => {
    aiSettings.provider = "anthropic";
    vi.mocked(getOrFetchReaderContent).mockResolvedValue({ html: "<p>Article</p>", raw_html: "" });
    const user = userEvent.setup();
    render(<ArticleDetail />);
    await user.click(screen.getByRole("button", { name: "Summary options" }));
    const wordCount = screen.getByPlaceholderText("Word count");
    await user.clear(wordCount);
    await user.type(wordCount, "650");
    await user.type(screen.getByPlaceholderText("e.g. Focus on financial implications..."), "Explain the evidence and tradeoffs");
    const summarizeButtons = screen.getAllByRole("button", { name: "Summarize" });
    await user.click(summarizeButtons[summarizeButtons.length - 1]);
    expect(summarizeMutation.mutate).toHaveBeenCalledWith(expect.objectContaining({
      articleId: "a", force: true, summaryCustomWordCount: 650,
      summaryCustomPrompt: "Explain the evidence and tradeoffs",
    }));
  });

  it("opens the same article chat from the toolbar and bottom toggle", async () => {
    vi.mocked(getOrFetchReaderContent).mockResolvedValue({ html: "<p>Article</p>", raw_html: "" });
    const user = userEvent.setup();
    render(<ArticleDetail />);
    const toolbarChat = screen.getAllByRole("button", { name: "Chat with article" })[0];
    await user.click(toolbarChat);
    expect(screen.getByRole("region", { name: "Article chat" })).toBeInTheDocument();
    expect(toolbarChat).toHaveAttribute("aria-expanded", "true");
    await user.click(screen.getByRole("button", { name: "Collapse chat" }));
    expect(toolbarChat).toHaveAttribute("aria-expanded", "false");
    await user.click(screen.getAllByRole("button", { name: "Chat with article" })[1]);
    expect(toolbarChat).toHaveAttribute("aria-expanded", "true");
  });

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

  it("keeps the web view usable when the reader can't extract the page", async () => {
    // The page downloads fine; only readability comes back empty. Both panes
    // used to go blank because the backend threw the raw HTML away with it.
    vi.mocked(getOrFetchReaderContent).mockResolvedValue({
      html: "",
      raw_html: "<html><body><p>Original page markup</p></body></html>",
    });
    const user = userEvent.setup();
    render(<ArticleDetail />);

    expect(await screen.findByText(/Reader couldn't extract this page/)).toBeInTheDocument();
    expect(screen.getByText("Feed preview")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Web" }));
    expect(await screen.findByTitle("Article web view")).toBeInTheDocument();
    expect(screen.queryByText("Couldn't load page in the embedded view.")).not.toBeInTheDocument();
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
